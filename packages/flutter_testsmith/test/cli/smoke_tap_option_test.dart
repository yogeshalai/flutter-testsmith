// SMOKE-TAP: a `--tap` that is not a point.
//
// 4e63448 made a malformed `--mock-api` a mistake in how `smoke` was
// called, refused before a file, device or port is touched. `--tap` is
// the same kind of value in the same command, and `smoke` read it after
// the device gate. Measured at 1f72ab3, offline:
//
//   --tap abc, no adb       "adb could not be found."   - the wrong
//                           problem named, and the real one never
//   --tap abc, a device     adb devices -l, then '--tap expects "x,y"'
//
// Now read with the invocation, at the same code it always had: 1.
//
// Offline. A fake adb records every call.
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';

late Directory _root;
late Directory _app;
late File _adbCalls;

/// A directory holding an adb that lists [_serial] and records each call.
/// Portable per A-3.
String _fakeAdb() {
  final directory = Directory('${_root.path}/tools')..createSync();
  if (Platform.isWindows) {
    File('${directory.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo %*>> "${_adbCalls.path}"\r\n'
      'if "%1"=="devices" (\r\n'
      '  echo List of devices attached\r\n'
      '  echo $_serial            device product:f model:Fake device:f\r\n'
      ')\r\n'
      'exit /b 0\r\n',
    );
  } else {
    final adb = File('${directory.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$*" >> "${_adbCalls.path}"\n'
        'if [ "\$1" = "devices" ]; then\n'
        '  echo "List of devices attached"\n'
        '  echo "$_serial            device product:f model:Fake device:f"\n'
        'fi\n'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', adb.path]);
  }
  return directory.path;
}

typedef Run = ({String stdout, String stderr, int code});

/// `smoke --tap [tap]`. [adb] false leaves adb off PATH entirely.
Future<Run> _smoke(String tap, {bool adb = true}) async {
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'smoke',
      '--app',
      _app.path,
      '--app-id',
      'com.example.x',
      '--device',
      _serial,
      '--tap',
      tap,
    ],
    environment: {
      // No Dart directory: on a host whose Dart sits inside a Flutter SDK
      // it would put the real flutter on PATH.
      'PATH': [if (adb) _fakeAdb(), system]
          .join(Platform.isWindows ? ';' : ':'),
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
  ).timeout(const Duration(seconds: 120));
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}\n'
    'adb: ${_adbCalls.existsSync() ? _adbCalls.readAsStringSync() : '-'}';

void _expectRefusedFirst(Run run, String says) {
  expect(run.code, 1, reason: _both(run));
  expect(run.stdout, contains(says), reason: _both(run));
  expect(run.stderr, isEmpty, reason: _both(run));
  expect(_adbCalls.existsSync(), isFalse, reason: _both(run));
  for (final later in const [
    'adb could not be found',
    'No usable device',
    'flutter was not found',
    'waking device',
    'Smoke run failed',
  ]) {
    expect(run.stdout, isNot(contains(later)), reason: _both(run));
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('smoke_tap');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    File('${_app.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _adbCalls = File('${_root.path}/adb_calls.log');
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('smoke refuses a --tap that is not a point, before the device', () {
    test('not two values', () async {
      _expectRefusedFirst(await _smoke('abc'), '--tap expects "x,y", got "abc"');
    });

    test('not two integers', () async {
      _expectRefusedFirst(
        await _smoke('10,y'),
        '--tap expects two integers, got "10,y"',
      );
    });

    test('ahead of a machine with no adb', () async {
      _expectRefusedFirst(
        await _smoke('abc', adb: false),
        '--tap expects "x,y", got "abc"',
      );
    });
  });

  test('a point is still a point, and reaches the device gate', () async {
    final run = await _smoke('10,20', adb: false);

    expect(run.code, 1, reason: _both(run));
    expect(run.stdout, contains('adb could not be found.'),
        reason: _both(run));
    expect(run.stdout, isNot(contains('--tap expects')), reason: _both(run));
  });
}
