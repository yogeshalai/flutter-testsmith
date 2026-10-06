import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith/engine.dart';

/// Reads the scenario files a project keeps in `mock_api/scenarios/`.
///
/// Separate from [ApiScenario] because this is the part that touches the
/// disk. Resolution - which scenario inherits which - is done here
/// because only this layer knows where a file lives.
class ScenarioLibrary {
  ScenarioLibrary._(this.directory, this._byName);

  final Directory directory;
  final Map<String, ApiScenario> _byName;

  /// Every scenario a flow may name, sorted.
  List<String> get names => _byName.keys.toList()..sort();

  static const String defaultName = 'default';

  static ScenarioLibrary load(Directory directory) {
    final byName = <String, ApiScenario>{};
    if (directory.existsSync()) {
      for (final entry in directory.listSync().whereType<File>()) {
        if (!entry.path.endsWith('.json')) continue;

        final String text;
        try {
          text = entry.readAsStringSync();
        } on FileSystemException catch (error) {
          // `readAsStringSync` decodes as well as reads and reports a
          // failure to decode as a `FileSystemException`, which is not
          // the exception this library raises for everything else it
          // cannot use. A scenario saved in an encoding this cannot
          // read ended `preflight` and `generate` at 255, while an
          // invalid-JSON file in the same directory was reported and
          // survived.
          //
          // Restated so it is the same kind of news as any other
          // unusable scenario. That matters beyond the crash: the
          // blocked-suite row asks `error is ScenarioFormatException`
          // to decide whether it has a scenario problem or something
          // it can only print, and an encoding is plainly the former.
          //
          // The message rather than the exception: a
          // `FileSystemException` prints the path it was given, and
          // `source` already carries it.
          throw ScenarioFormatException(entry.path, error.message);
        }

        final scenario = ApiScenario.parse(text, source: entry.path);
        final stem = entry.uri.pathSegments.last.replaceAll('.json', '');
        if (scenario.name != stem) {
          // The file name is what a flow writes; the `name` field is
          // what a report shows. Letting them drift makes a flow name a
          // scenario the report calls something else.
          throw ScenarioFormatException(
            entry.path,
            'declares name "${scenario.name}" but the file is "$stem.json". '
            'A flow names the file, so the two must agree.',
          );
        }
        byName[stem] = scenario;
      }
    }
    return ScenarioLibrary._(directory, byName);
  }

  bool contains(String name) => _byName.containsKey(name);

  /// The named scenario with its inheritance applied.
  ///
  /// Throws rather than falling back. A flow that asked for
  /// `api_500_server_error` and silently got the happy path is the exact
  /// failure this whole mechanism exists to prevent.
  ApiScenario resolve(String name) {
    final chain = <String>[];
    ApiScenario resolveOne(String current) {
      if (chain.contains(current)) {
        throw ScenarioFormatException(
          '${directory.path}/$current.json',
          'inheritance loops: ${[...chain, current].join(' -> ')}',
        );
      }
      chain.add(current);

      final scenario = _byName[current];
      if (scenario == null) {
        throw ScenarioFormatException(
          '${directory.path}/$current.json',
          'no such scenario. Available: '
          '${names.isEmpty ? '(none)' : names.join(', ')}.',
        );
      }

      final parent = scenario.inherits;
      return parent == null
          ? scenario
          : scenario.mergedOnto(resolveOne(parent));
    }

    return resolveOne(name);
  }
}

/// One request the mock API answered, for the report.
class ServedExchange {
  ServedExchange({
    required this.method,
    required this.path,
    required this.status,
    required this.delayMs,
    required this.matched,
  });

  final String method;
  final String path;
  final int status;
  final int delayMs;

  /// Whether the scenario had anything to say about this route.
  final bool matched;

  @override
  String toString() => '$method $path -> $status'
      '${matched ? '' : ' (no route in the scenario)'}';
}

/// The fixture port a `--mock-api` value names, or null when none was
/// given.
///
/// `run` and `smoke` read the flag with `int.tryParse`, so a mistyped
/// port became no fixture server at all and the run went on against
/// whatever API the build pointed at - the one thing the flag is given
/// to prevent. Throws [FormatException] for a value that is not a whole
/// number, or is negative; the caller says it and stops.
///
/// `0` stays accepted: the host picks a free port, and `run` announces
/// and reverses the one actually bound. The CLI's tests depend on it.
/// A suite file's `mockApi.port` has always refused it, and still does.
int? parseMockApiPort(String? raw) {
  if (raw == null) return null;
  final port = int.tryParse(raw);
  if (port == null || port < 0) {
    throw FormatException('--mock-api expects a port number, got "$raw".');
  }
  return port;
}

/// A fixture-backed API for the example application.
///
/// Runs on the host. A physical device cannot reach the host the way an
/// emulator reaches `10.0.2.2`, so the runner sets up `adb reverse` and
/// the app simply talks to `127.0.0.1` - see [DeviceController.reversePort].
///
/// It deliberately returns a credential-shaped header, so that a run
/// proves redaction on real traffic rather than only in unit tests.
class MockApiServer {
  MockApiServer._(this._server, this.port, this._scenario);

  final HttpServer _server;
  final int port;

  ApiScenario _scenario;

  /// The API state this run is testing against.
  ApiScenario get scenario => _scenario;

  /// Switches to a different API state, in place.
  ///
  /// A suite runs several flows against one server and the flows name
  /// different states. Restarting between them would tear down the
  /// `adb reverse` the device is talking through, so the scenario is
  /// swapped instead.
  ///
  /// The exchange log is cleared with it. Exchanges are what an API
  /// assertion reads, and carrying the previous test's requests forward
  /// would let a flow assert against traffic it never made.
  void serve(ApiScenario scenario) {
    _scenario = scenario;
    exchanges.clear();
  }

  final List<ServedExchange> exchanges = <ServedExchange>[];

  List<String> get requestLog =>
      [for (final e in exchanges) '${e.method} ${e.path}'];

  static Future<MockApiServer> start({
    required ApiScenario scenario,
    int port = 8080,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final mock = MockApiServer._(server, server.port, scenario);

    server.listen((request) async {
      final path = request.uri.path;
      // Read through the server, not the captured parameter: the
      // scenario can be swapped between tests.
      final route = mock.scenario.match(request.method, path);

      final response = request.response
        // A secret the application never wrote down: it must not appear
        // in any emitted event.
        ..headers.add('set-cookie', 'session=MOCK_SESSION_SECRET; HttpOnly')
        ..headers.add('x-request-id', 'req-${mock.exchanges.length + 1}');

      if (route == null) {
        mock.exchanges.add(
          ServedExchange(
            method: request.method,
            path: path,
            status: 404,
            delayMs: 0,
            matched: false,
          ),
        );
        response
          ..statusCode = 404
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'error': 'no route',
            'detail': '${request.method} $path is not in scenario '
                '"${mock.scenario.name}"',
          }));
        await response.close();
        return;
      }

      if (route.delay > Duration.zero) {
        // A real timeout, not a status code. The client gives up before
        // this completes, which is a different event from a 500 and must
        // be testable as one.
        await Future<void>.delayed(route.delay);
      }

      mock.exchanges.add(
        ServedExchange(
          method: request.method,
          path: path,
          status: route.status,
          delayMs: route.delay.inMilliseconds,
          matched: true,
        ),
      );

      response.statusCode = route.status;
      for (final header in route.headers.entries) {
        response.headers.add(header.key, header.value);
      }

      final bytes = route.bodyBytes;
      if (bytes != null) {
        // A picture, served by the fixture server itself. An outlet card
        // drawing an image from somebody else's CDN cannot be
        // photographed deterministically - the bytes are outside this
        // repository's control and the fade-in is timed by their
        // network. The scenario carries them instead.
        //
        // No content type is guessed: a scenario that sends bytes says
        // what they are, because a PNG announced as JSON reaches the
        // screen as a broken-image placeholder that photographs
        // perfectly well and explains nothing.
        response.add(bytes);
        await response.close();
        return;
      }

      final body = route.bodyText;
      if (body != null) {
        // JSON unless the scenario overrode it: a malformed-body test
        // needs the content type to still claim JSON, because that is
        // what makes the client try to parse it.
        if (!route.headers.keys
            .map((k) => k.toLowerCase())
            .contains('content-type')) {
          response.headers.contentType = ContentType.json;
        }
        response.write(body);
      }

      await response.close();
    });

    return mock;
  }

  Future<void> close() => _server.close(force: true);
}
