// MOCK-API-PORT: a `--mock-api` value that is not a port.
//
// A suite declares its fixture port as `mockApi: {port: N}`, and the
// suite parser refuses a value that is not a number: "mockApi.port"
// must be a port number. `run` and `smoke` take the same port as
// `--mock-api N` and read it with `int.tryParse`, so measured at
// 3a3dc01, offline:
//
//   run   --mock-api 80a0      no fixture server, and on to the device -
//                              the run is driven against whatever API
//                              the build points at, the one thing the
//                              flag was given to prevent
//   run   --mock-api 80a0      with a flow that declares a fixture:
//                              "needs the API state ... --mock-api 8080",
//                              telling somebody to pass the flag they
//                              passed
//   run   --mock-api -1        accepted, and handed to the server bind
//   smoke --mock-api 80a0      no fixture server, and on to the device
//
// A mistyped value is now refused where the invocation is read - before
// a file, device or port is touched - at each command's own code for a
// mistake in how it was called: 64 for `run`, 1 for `smoke`, as its `--tap` and `--app-id`.
//
// `0` is not refused. The host picks a free port and `run` announces and
// reverses the one it bound; `fixture_server_startup_test` and
// `dotenv_decode_test` depend on that, and it is pinned below.
//
// Offline: no adb, and a PATH holding only the Dart SDK, so anything
// that got past the check would say so.
@Timeout(Duration(minutes: 8))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

const String _flow = 'appId: com.example.x\nflow: home\nsteps:\n'
    '  - launchApp\n';

Map<String, String> get _offline => {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    };

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: _offline,
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

Future<Run> _run(String port) => _testsmith([
      'run',
      '--app',
      _app.path,
      '--mock-api',
      port,
      '${_app.path}/tests/home.yaml',
    ]);

Future<Run> _smoke(String port) => _testsmith([
      'smoke',
      '--app',
      _app.path,
      '--app-id',
      'com.example.x',
      '--mock-api',
      port,
    ]);

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}';

/// Refused as a mistake in the invocation: [code], the sentence naming
/// the value, and nothing past it - no device looked for, no scenario
/// read, no server bound, nothing launched.
void _expectRefused(Run run, String value, {required int code}) {
  expect(run.code, code, reason: _both(run));
  expect(
    run.stdout,
    contains('--mock-api expects a port number, got "$value".'),
    reason: _both(run),
  );
  expect(run.stderr, isEmpty, reason: _both(run));
  for (final later in const [
    'adb',
    'device',
    'scenario',
    'mock API on',
    'fixture server',
    'needs the',
    'flutter',
    'launching app',
  ]) {
    expect(run.stdout.toLowerCase(), isNot(contains(later.toLowerCase())),
        reason: _both(run));
  }
  for (final stream in [run.stdout, run.stderr]) {
    expect(stream, isNot(contains('Unhandled exception')), reason: _both(run));
    expect(stream, isNot(contains('#0 ')), reason: _both(run));
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('mock_api_port');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('tests/home.yaml', _flow);
    _write('mock_api/scenarios/default.json', '{"name":"default","routes":{}}');
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('run refuses a --mock-api that is not a port, at 64', () {
    for (final value in const ['80a0', '-1', '']) {
      test('"$value"', () async {
        _expectRefused(await _run(value), value, code: 64);
      });
    }

    test('before a flow that declares a fixture can ask for the flag',
        () async {
      _write('tests/home.yaml',
          _flow.replaceFirst('flow: home\n', 'flow: home\nfixture: default\n'));

      _expectRefused(await _run('80a0'), '80a0', code: 64);
    });

    test('before the flow file is even looked for', () async {
      final run = await _testsmith([
        'run',
        '--app',
        _app.path,
        '--mock-api',
        '80a0',
        '${_app.path}/tests/no_such.yaml',
      ]);

      _expectRefused(run, '80a0', code: 64);
      expect(run.stdout, isNot(contains('No such flow file')),
          reason: _both(run));
    });
  });

  group('smoke refuses it too, at its own code for a bad option', () {
    for (final value in const ['80a0', '-1', '']) {
      test('"$value"', () async {
        _expectRefused(await _smoke(value), value, code: 1);
      });
    }
  });

  group('a real port is still a port', () {
    // Past the check, to the next gate: with no adb on this PATH, the
    // device. Nothing about the option.
    test('run', () async {
      final run = await _run('8571');

      expect(run.code, 2, reason: _both(run));
      expect(run.stdout, contains('adb could not be found.'),
          reason: _both(run));
      expect(run.stdout, isNot(contains('--mock-api expects')),
          reason: _both(run));
    });

    test('smoke', () async {
      final run = await _smoke('8571');

      expect(run.code, 1, reason: _both(run));
      expect(run.stdout, contains('adb could not be found.'),
          reason: _both(run));
      expect(run.stdout, isNot(contains('--mock-api expects')),
          reason: _both(run));
    });

    test('0, for "any free port", is still accepted by run', () async {
      final run = await _run('0');

      expect(run.code, 2, reason: _both(run));
      expect(run.stdout, contains('adb could not be found.'),
          reason: _both(run));
      expect(run.stdout, isNot(contains('--mock-api expects')),
          reason: _both(run));
    });

    test('and with no --mock-api at all, nothing is asked', () async {
      final run = await _testsmith([
        'run',
        '--app',
        _app.path,
        '${_app.path}/tests/home.yaml',
      ]);

      expect(run.code, 2, reason: _both(run));
      expect(run.stdout, contains('adb could not be found.'),
          reason: _both(run));
      expect(run.stdout, isNot(contains('--mock-api')), reason: _both(run));
    });
  });
}
