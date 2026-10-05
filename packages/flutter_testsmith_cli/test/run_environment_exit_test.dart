// RUN-ENV-EXIT: `run` cannot reach its environment.
//
// The CI contract this repository states - in E-04, in
// `SuiteVerdict.exitCode`, and in `run`'s own launch-failure path - is
// 0 passed, 1 the application is wrong, 2 the run is wrong. `run` kept
// that for a launch that failed and for an ERROR verdict, but answered 1
// whenever it could not get as far as a launch: no adb, no device,
// several devices, a named device that is not attached, a fixture port
// that is taken. Measured at 88c66d1 on Windows, each exited 1 - the
// application's code - while `suite run`, `preflight` and `auth setup`
// exited 2 for the same machine.
//
// C3 (04d3696) chose 1 for the first case on the grounds that only
// `auth` and `suite` defined 2. `run` already did, in 434a57f.
//
// Offline throughout. adb is either absent or a fake named through
// `MYTEST_ADB`, so a handset plugged into the host cannot change an
// answer, and nothing gets far enough to need Flutter.
@Timeout(Duration(minutes: 5))
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

/// An adb that answers `devices -l` with [serials] and nothing else.
///
/// Portable per A-3: a `.bat` on Windows, an executable shell script
/// elsewhere.
String _fakeAdb(List<String> serials) {
  final directory = Directory('${_root.path}/fake_adb_${serials.length}')
    ..createSync();
  String line(String serial) =>
      '$serial            device product:fake model:Fake device:fake';
  if (Platform.isWindows) {
    return (File('${directory.path}/adb.bat')
          ..writeAsStringSync(
            '@echo off\r\n'
            'echo List of devices attached\r\n'
            '${[for (final s in serials) 'echo ${line(s)}\r\n'].join()}',
          ))
        .path;
  }
  final file = File('${directory.path}/adb')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'echo "List of devices attached"\n'
      '${[for (final s in serials) 'echo "${line(s)}"\n'].join()}',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// A PATH holding the Dart SDK and nothing else, and no adb anywhere.
Map<String, String> get _noAdb => {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    };

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _run(List<String> extra, Map<String, String> environment) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'run',
      '--app',
      _app.path,
      ...extra,
      '${_app.path}/tests/home.yaml',
    ],
    environment: environment,
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}';

/// An environment answer: exit 2, [sentence] said, no crash, and nothing
/// that reads as a verdict about the application.
void _expectEnvironment(Run run, String sentence) {
  expect(run.code, 2, reason: _both(run));
  expect(run.stdout, contains(sentence), reason: _both(run));
  for (final stream in [run.stdout, run.stderr]) {
    expect(stream, isNot(contains('Unhandled exception')), reason: _both(run));
    expect(stream, isNot(contains('#0 ')), reason: _both(run));
  }
  // `_summarise` heads a verdict with "Result"; nothing was measured, so
  // there must be no verdict and no report.
  expect(
    run.stdout.split('\n').map((l) => l.trim()),
    isNot(contains('Result')),
    reason: _both(run),
  );
  expect(
    _app
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('result.json')),
    isEmpty,
    reason: 'no result was measured, so none may be written',
  );
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('run_env_exit');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n'
      '  - launchApp\n'
      '  - expectScreen:\n      id: /home\n',
    );
    _write(
      'mock_api/scenarios/default.json',
      '{"name":"default","routes":{}}',
    );
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('run cannot reach its environment, and exits 2', () {
    test('no adb', () async {
      final run = await _run(const [], _noAdb);

      _expectEnvironment(run, 'adb could not be');
    });

    test('adb, and no device attached', () async {
      final run = await _run(
        const [],
        {..._noAdb, 'MYTEST_ADB': _fakeAdb(const [])},
      );

      _expectEnvironment(run, 'No usable device attached');
    });

    test('several devices, and none chosen', () async {
      final run = await _run(
        const [],
        {..._noAdb, 'MYTEST_ADB': _fakeAdb(const ['SERIAL_A', 'SERIAL_B'])},
      );

      _expectEnvironment(run, 'Several devices attached');
    });

    test('a named device that is not attached', () async {
      final run = await _run(
        const ['--device', 'NOSUCHSERIAL'],
        {..._noAdb, 'MYTEST_ADB': _fakeAdb(const ['SERIAL_A'])},
      );

      _expectEnvironment(run, 'No usable device with serial "NOSUCHSERIAL"');
    });

    test('a fixture port that is taken', () async {
      final held = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(held.close);

      final run = await _run(
        ['--device', 'SERIAL_A', '--mock-api', '${held.port}'],
        {..._noAdb, 'MYTEST_ADB': _fakeAdb(const ['SERIAL_A'])},
      );

      _expectEnvironment(run, 'The fixture server could not be started');
    });
  });

  group('what the change must not reach', () {
    test('a configuration error is 2 as well, and still says what it is',
        () async {
      // A fixture the flow needs and no server to arrange it: a fact
      // about the invocation, found before a device is looked for. This
      // was 1 when it was written; RUN-CONFIG-EXIT made configuration 2,
      // so the code no longer tells the two apart and the sentence has
      // to - it names the fixture, and adb is never asked.
      _write(
        'tests/home.yaml',
        'appId: com.example.x\nflow: home\nfixture: default\nsteps:\n'
        '  - launchApp\n'
        '  - expectScreen:\n      id: /home\n',
      );

      final run = await _run(const [], _noAdb);

      expect(run.stdout, contains('needs the "default" API state'),
          reason: _both(run));
      expect(run.stdout, isNot(contains('adb')), reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });
  });
}
