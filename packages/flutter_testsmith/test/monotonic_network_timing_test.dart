// Request durations on the application's monotonic clock.
//
// A duration used to be the difference of two DateTime.now() readings,
// and it started at close() - after DNS, TCP and TLS - so a connection
// that took thirty seconds to fail was recorded as roughly 0 ms. Here
// every duration is measured against an injected tick source the test
// advances by hand: inside a fake connection, inside a real server's
// handler, or between two manual calls. No sleeps, no thresholds.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import 'support/fake_sdk_channel.dart';

/// A monotonic clock the test moves.
class _Ticks {
  int micros = 5000000;

  int call() => micros;

  void advance(Duration by) => micros += by.inMicroseconds;
}

/// Spends [connect] on the fake clock establishing a connection, then
/// either fails or hands over to a real client for the rest.
class _TimedConnectClient implements HttpClient {
  _TimedConnectClient(this.ticks, this.connect, {this.failWith});

  final _Ticks ticks;
  final Duration connect;
  final Object? failWith;
  final HttpClient _real = HttpClient();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    ticks.advance(connect);
    if (failWith != null) throw failWith!;
    return _real.openUrl(method, url);
  }

  @override
  void close({bool force = false}) => _real.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Previous extends HttpOverrides {
  _Previous(this.client);

  final HttpClient client;

  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

void main() {
  late _Ticks ticks;
  late List<EventPayload> emitted;
  late NetworkCapture capture;

  setUp(() {
    ticks = _Ticks();
    emitted = <EventPayload>[];
    capture = NetworkCapture(
      config: const TestSdkConfig(enabled: true),
      emit: emitted.add,
      monotonicMicros: ticks.call,
    );
  });

  tearDown(() => HttpOverrides.global = null);

  List<ApiResponsePayload> responses() =>
      emitted.whereType<ApiResponsePayload>().toList();

  group('through the HttpOverrides adapter', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        // The server's share of the request, on the same fake clock.
        ticks.advance(const Duration(milliseconds: 250));
        request.response.statusCode =
            request.uri.path == '/boom' ? 500 : 200;
        request.response.write('{"ok":true}');
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Future<void> fetch(String path, {Duration connect = Duration.zero}) async {
      HttpOverrides.global = CapturingHttpOverrides(
        capture,
        previous: _Previous(_TimedConnectClient(ticks, connect)),
      );
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://${server.address.address}:${server.port}$path'),
      );
      final response = await request.close();
      await utf8.decoder.bind(response).join();
      client.close();
    }

    test('a success includes connection setup and the response', () async {
      await fetch('/ok', connect: const Duration(milliseconds: 40));

      expect(responses().single.statusCode, 200);
      expect(responses().single.durationMs, 290);
    });

    test('an HTTP error is timed the same way', () async {
      await fetch('/boom', connect: const Duration(milliseconds: 40));

      expect(responses().single.statusCode, 500);
      expect(responses().single.durationMs, 290);
    });

    test('a connection that fails late records how long it tried', () async {
      // The case the old start point could not see: openUrl is where DNS,
      // TCP and TLS happen, and a connection timeout is raised there.
      HttpOverrides.global = CapturingHttpOverrides(
        capture,
        previous: _Previous(_TimedConnectClient(
          ticks,
          const Duration(seconds: 30),
          failWith: const SocketException('Connection timed out'),
        )),
      );

      final client = HttpClient();
      await expectLater(
        client.getUrl(Uri.parse('http://198.51.100.1/slow')),
        throwsA(isA<SocketException>()),
      );

      expect(responses().single.statusCode, isNull);
      expect(responses().single.error, contains('Connection timed out'));
      expect(responses().single.durationMs, 30000);
    });

    test('a failure after connecting is timed from before the connection',
        () async {
      final hangUp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      hangUp.listen((socket) => socket.destroy());
      addTearDown(hangUp.close);

      HttpOverrides.global = CapturingHttpOverrides(
        capture,
        previous: _Previous(
          _TimedConnectClient(ticks, const Duration(milliseconds: 70)),
        ),
      );
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://${hangUp.address.address}:${hangUp.port}/x'),
      );
      await expectLater(request.close(), throwsA(isA<HttpException>()));
      client.close();

      expect(responses().single.error, isNotNull);
      expect(responses().single.durationMs, 70);
    });
  });

  group('the capture core', () {
    test('elapsed ticks are rounded down to whole milliseconds', () {
      final id = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      ticks.micros += 1999;
      capture.complete(id, statusCode: 200);

      expect(responses().single.durationMs, 1);
    });

    test('concurrent requests completing out of order keep their own times',
        () {
      final a = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      ticks.advance(const Duration(milliseconds: 10));
      final b = capture.begin(method: 'GET', url: Uri.parse('http://x/b'));
      ticks.advance(const Duration(milliseconds: 20));
      capture.complete(b, statusCode: 200);
      ticks.advance(const Duration(milliseconds: 70));
      capture.fail(a, error: 'reset');

      final byId = {for (final r in responses()) r.requestId: r};
      expect(byId[b]!.durationMs, 20);
      expect(byId[a]!.durationMs, 100);
    });

    test('an unanswered request has no response and no duration', () {
      capture.begin(method: 'GET', url: Uri.parse('http://x/hangs'));
      ticks.advance(const Duration(minutes: 5));

      expect(responses(), isEmpty);
      expect(capture.inFlightCount, 1);
    });

    test('a response for an unknown request is still not emitted', () {
      capture.complete('never-begun', statusCode: 200);

      expect(emitted, isEmpty);
    });

    test('a start tick from the caller is used as given', () {
      // The adapter reads the tick before connecting and hands it over at
      // close(); a manual caller can do the same.
      final startedAt = capture.monotonicMicros();
      ticks.advance(const Duration(milliseconds: 45));
      final id = capture.begin(
        method: 'GET',
        url: Uri.parse('http://x/a'),
        startedAtMicros: startedAt,
      );
      ticks.advance(const Duration(milliseconds: 5));
      capture.complete(id, statusCode: 200);

      expect(responses().single.durationMs, 50);
    });

    test('a start tick in the future is not believed', () {
      // It cannot have come from this clock. Measuring from it would give
      // a negative duration; begin measures from its own reading instead.
      final id = capture.begin(
        method: 'GET',
        url: Uri.parse('http://x/a'),
        startedAtMicros: ticks.micros + 1000000,
      );
      ticks.advance(const Duration(milliseconds: 8));
      capture.complete(id, statusCode: 200);

      expect(responses().single.durationMs, 8);
    });

    test('two captures never complete or time each other\'s requests', () {
      // A hot restart starts a new session, and with it a new capture and
      // a new clock. A request left open in the old one stays open.
      final otherTicks = _Ticks()..micros = 1;
      final otherEmitted = <EventPayload>[];
      final other = NetworkCapture(
        config: const TestSdkConfig(enabled: true),
        emit: otherEmitted.add,
        monotonicMicros: otherTicks.call,
      );

      final open = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      final mine = other.begin(method: 'GET', url: Uri.parse('http://x/b'));
      otherTicks.advance(const Duration(milliseconds: 12));
      other.complete(open, statusCode: 200);
      other.complete(mine, statusCode: 200);

      expect(otherEmitted.whereType<ApiResponsePayload>().single.durationMs,
          12);
      expect(responses(), isEmpty);
      expect(capture.inFlightCount, 1);
    });
  });

  group('the wall clock is for display only', () {
    test('a wall clock that jumps mid-request does not move the duration',
        () {
      var wall = DateTime.utc(2026, 10, 3, 9);
      final channel = FakeSdkChannel();
      final session = TestSession(
        config: const TestSdkConfig(enabled: true),
        channel: channel,
        describeApp: () => const AppContext(
          appVersion: '1.0.0',
          buildMode: BuildMode.debug,
          environment: 'test',
          platform: 'android',
          devicePixelRatio: 2,
        ),
        appId: 'com.example',
        sdkVersion: 'test',
        clock: () => wall,
        monotonicMicros: ticks.call,
      );

      final id = session.network.begin(
        method: 'GET',
        url: Uri.parse('http://x/a'),
      );
      // NTP steps the device clock back an hour mid-request.
      wall = wall.subtract(const Duration(hours: 1));
      ticks.advance(const Duration(milliseconds: 250));
      session.network.complete(id, statusCode: 200);

      final request =
          channel.emitted.firstWhere((e) => e.payload is ApiRequestPayload);
      final response =
          channel.emitted.firstWhere((e) => e.payload is ApiResponsePayload);
      expect(response.timestamp.isBefore(request.timestamp), isTrue);
      expect((response.payload as ApiResponsePayload).durationMs, 250);
    });
  });

  group('the capability', () {
    test('advertised exactly when network capture is', () {
      const on = TestSdkConfig(enabled: true);
      const off = TestSdkConfig(enabled: true, enableNetworkCapture: false);
      const disabled = TestSdkConfig();

      expect(on.capabilities,
          containsAll(<String>['network', 'monotonicNetworkTiming']));
      expect(off.capabilities, isNot(contains('network')));
      expect(off.capabilities, isNot(contains('monotonicNetworkTiming')));
      expect(disabled.capabilities, isEmpty);
    });
  });
}
