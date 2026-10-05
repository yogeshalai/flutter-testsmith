// AUDIT-2: an adb that is a wrapper script on PATH.
//
// `SystemProcessRunner` runs a bare `adb` on Windows as `adb`, `adb.bat`,
// `adb.cmd`, `adb.exe` in turn, so an `adb.cmd` on PATH is an adb that
// runs. `resolveAdb` looked for `adb.exe` alone. Measured at 1588d1a on
// Windows with only an `adb.cmd` on PATH, answering with one device:
//
//   devices      lists it, exit 0
//   run          wakes it and goes on to launch
//   doctor       "[fail] adb  adb could not be found." - and then lists
//                its device, further down the same report
//   preflight    [BLOCK] device  adb could not be found.
//   suite run    the same
//   auth setup   adb could not be found.
//
// One machine, two answers to "is there an adb". The resolver's PATH scan
// now takes the runner's own names, so every command answers the same.
//
// Through the real executable and the real process runner. A direct
// `Process.run('adb')` is not evidence either way: it skips the runner's
// retry and does not find a wrapper, which is what misled the first
// attempt at this.
@TestOn('windows')
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'WRAPPERSERIAL1';

late Directory _root;
late Directory _app;

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// A PATH holding only a directory with `adb.<extension>`, the Dart SDK,
/// and Windows itself - which a `.bat` or `.cmd` needs for `cmd.exe`, as
/// on any real machine.
Map<String, String> _wrapperOnPath(String extension) {
  final directory = Directory('${_root.path}/wrapper')..createSync();
  File('${directory.path}/adb.$extension').writeAsStringSync(
    '@echo off\r\n'
    'if "%1"=="version" (\r\n'
    '  echo Android Debug Bridge version 1.0.41\r\n'
    '  exit /b 0\r\n'
    ')\r\n'
    'if "%1"=="devices" (\r\n'
    '  echo List of devices attached\r\n'
    '  echo $_serial            device product:f model:FakePhone device:f\r\n'
    '  exit /b 0\r\n'
    ')\r\n'
    'exit /b 0\r\n',
  );
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return {
    'PATH': [
      directory.path,
      File(Platform.resolvedExecutable).parent.path,
      '$systemRoot\\System32',
      systemRoot,
    ].join(';'),
    'MYTEST_ADB': '',
    'ANDROID_HOME': '',
    'ANDROID_SDK_ROOT': '',
  };
}

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _testsmith(
  List<String> arguments,
  Map<String, String> environment,
) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
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

void _expectAdbAvailable(Run run) {
  expect(run.stdout, isNot(contains('adb could not be found')),
      reason: _both(run));
  expect(run.stdout, isNot(contains('adb could not be started')),
      reason: _both(run));
  expect(run.stderr, isNot(contains('Unhandled exception')),
      reason: _both(run));
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('adb_wrapper');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n'
      '  - launchApp\n'
      '  - expectScreen:\n      id: /home\n',
    );
    _write('device_profiles/p.yaml', 'id: p\nmodel: FakePhone\n');
    _write(
      'suites/s.yaml',
      'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
      'device: {profile: p}\n'
      'tests:\n  - {id: home, flow: tests/home.yaml}\n',
    );
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  for (final extension in const ['cmd', 'bat']) {
    group('only an adb.$extension on PATH', () {
      test('devices uses it', () async {
        final run = await _testsmith(['devices'], _wrapperOnPath(extension));

        _expectAdbAvailable(run);
        expect(run.stdout, contains(_serial), reason: _both(run));
        expect(run.code, 0, reason: _both(run));
      });

      test('run uses it to check the device', () async {
        // Stopped at the device gate on purpose: a serial the wrapper does
        // not list. `run` must ask the wrapper to refuse it, and names the
        // wrapper's device as the one attached - which is the proof - and
        // nothing after the gate (waking, launching) depends on a fake.
        final run = await _testsmith(
          [
            'run',
            '--app',
            _app.path,
            '-d',
            'NOSUCHSERIAL',
            '${_app.path}/tests/home.yaml',
          ],
          _wrapperOnPath(extension),
        );

        _expectAdbAvailable(run);
        expect(run.stdout, contains('No usable device with serial'),
            reason: _both(run));
        expect(run.stdout, contains(_serial), reason: _both(run));
        expect(run.code, 2, reason: _both(run));
      });

      test('preflight finds it too, and sees the device', () async {
        final run = await _testsmith(
          ['preflight', '${_app.path}/suites/s.yaml'],
          _wrapperOnPath(extension),
        );

        _expectAdbAvailable(run);
        expect(run.stdout, contains(RegExp(r'\[ok\]\s+device\s+FakePhone')),
            reason: _both(run));
      });

      test('doctor finds it where it says it looked', () async {
        final run = await _testsmith(['doctor'], _wrapperOnPath(extension));

        _expectAdbAvailable(run);
        expect(run.stdout, contains(RegExp(r'\[ok\]\s+adb\s')),
            reason: _both(run));
        expect(run.stdout, contains('adb.$extension'), reason: _both(run));
      });
    });
  }
}
