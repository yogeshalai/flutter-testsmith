// An explicit MYTEST_ADB is never silently replaced.
//
// `resolveAdb` says so outright: "An explicit value wins outright and is
// **not** silently replaced when it does not exist: falling back would
// run a different adb than the one somebody named, which is the whole
// class of quiet wrongness this resolution exists to remove."
//
// It keeps that promise. `AdbLocation.executableOrBareName` then hands
// back the bare name `adb` for any absence, and every caller but
// `doctor`'s adb row and `attachedDevices` (fixed by D) used it without
// asking whether anything had been located. Measured on Windows against
// c44b246, with MYTEST_ADB naming a path that does not exist and a
// different adb first on PATH:
//
//   testsmith doctor    [fail] adb  MYTEST_ADB names an adb that is not
//                                   there: ...
//   testsmith devices   Devices
//                         IMPOSTOR1  ImpostorPhone (physical)
//
//   control, MYTEST_ADB unset, same PATH   byte-identical output
//
// So the one command that reads the resolution refuses, and the command
// beside it runs a different adb and says nothing. Two adb versions on
// one machine run two servers, and which answers is whichever started
// first - the defect S7 exists to remove, reintroduced one layer down.
//
// What must not move: the bare-name fallback when *nothing* was
// configured. That is deliberate - "a machine that works today keeps
// working" - and on Windows it is also what finds an `adb.bat` or
// `adb.cmd` that `resolveAdb`'s `.exe`-only PATH scan does not look for.
// Only an explicit value that is not there is refused.
//
// Offline throughout. The fake adb answers `devices -l` and nothing
// else, which is all the paths under test ask it.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;

/// An adb that reports one unmistakable handset.
///
/// Reachable by the bare name `adb`, so it stands in for "some other adb
/// the operating system found" - the thing an explicit setting must not
/// be replaced by. Only shell builtins, so it runs with a stripped PATH.
String _fakeAdbDirectory() {
  final directory = Directory('${_root.path}/onpath')
    ..createSync(recursive: true);
  if (Platform.isWindows) {
    File('${directory.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo List of devices attached\r\n'
      'echo IMPOSTOR1            device product:fake model:ImpostorPhone '
      'device:fake\r\n'
      'exit /b 0\r\n',
    );
  } else {
    final file = File('${directory.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "List of devices attached"\n'
        'echo "IMPOSTOR1            device product:fake model:ImpostorPhone '
        'device:fake"\n'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', file.path]);
  }
  return directory.path;
}

/// The path of the fake itself, for the cases that name it outright.
String get _fakeAdbExecutable =>
    '${_root.path}/onpath/${Platform.isWindows ? 'adb.bat' : 'adb'}';

/// A path nothing is at.
String get _missingAdb =>
    '${_root.path}/nowhere/${Platform.isWindows ? 'adb.exe' : 'adb'}';

typedef Run = ({String output, int code});

/// [adb] is `MYTEST_ADB`; empty means unset.
///
/// PATH holds the fake adb and, on Windows, System32 - `cmd.exe` is
/// found through ComSpec but a `.bat` still expects a usable shell.
/// Dart itself is launched by absolute path, so nothing else is needed.
Future<Run> _testsmith(List<String> arguments, {required String adb}) async {
  final onPath = _fakeAdbDirectory();
  final path = Platform.isWindows
      ? '$onPath;${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
          r'\System32'
      : '$onPath:/usr/bin:/bin';

  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {
      'MYTEST_ADB': adb,
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
      'PATH': path,
    },
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

/// The handset only the adb on PATH reports.
const String _impostor = 'IMPOSTOR1';

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('adb_explicit');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('MYTEST_ADB names something that is not there', () {
    test('devices refuses rather than running the adb on PATH', () async {
      final run = await _testsmith(['devices'], adb: _missingAdb);

      expect(run.output, isNot(contains(_impostor)), reason: run.output);
      expect(run.output, contains('MYTEST_ADB'), reason: run.output);
      expect(run.code, isNot(0), reason: run.output);
    });

    test('doctor does not contradict its own adb row', () async {
      // Its `adb` row has always refused. The `Android device` row beside
      // it went on to run something else and report a handset, so one
      // report said both "there is no adb" and "here is a device".
      final run = await _testsmith(['doctor'], adb: _missingAdb);

      expect(run.output, contains('MYTEST_ADB'), reason: run.output);
      expect(run.output, isNot(contains(_impostor)), reason: run.output);
    });

    test('a command that picks a device refuses too', () async {
      // `inspect` chooses through `device_selection`, the other listing
      // entry point.
      final project = Directory('${_root.path}/app')
        ..createSync(recursive: true);
      File('${project.path}/pubspec.yaml')
          .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');

      final run = await _testsmith(
        ['inspect', '--app', project.path, '--app-id', 'com.example.x'],
        adb: _missingAdb,
      );

      expect(run.output, isNot(contains(_impostor)), reason: run.output);
      expect(run.output, contains('MYTEST_ADB'), reason: run.output);
      expect(run.code, isNot(0), reason: run.output);
    });
  });

  group('what must not move', () {
    test('an explicit adb that is there is used', () async {
      // The control. Without it every refusal above would also hold for
      // a resolver that had simply stopped working.
      final run = await _testsmith(['devices'], adb: _fakeAdbExecutable);

      expect(run.output, contains(_impostor), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });

    test('with nothing configured the adb on PATH is still used', () async {
      // The legacy safety net, deliberately kept: a machine that works
      // today keeps working, and on Windows this is also what finds an
      // `adb.bat` the `.exe`-only PATH scan never looks for.
      final run = await _testsmith(['devices'], adb: '');

      expect(run.output, contains(_impostor), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });
  });
}
