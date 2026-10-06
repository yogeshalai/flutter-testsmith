// D: not being able to ask adb is not the same as adb saying "none".
//
// `attachedDevices()` resolved adb, threw the resolution away on the same
// line, and caught everything that went wrong afterwards into an empty
// list. Three different failures and one ordinary answer arrived at
// `checkDeviceAttached` looking identical. Measured on Windows against
// 1f58632, on a machine with no adb reachable:
//
//   testsmith doctor     [fail] adb  adb could not be found.
//                               -> Install the Android platform-tools...
//   testsmith preflight  [BLOCK] device  no usable device is attached
//                               -> Attach a device with USB debugging enabled
//
// Same machine, same moment. The operator has no device problem; they
// have no adb, and only one of the two commands says so. The other sends
// them to plug in a handset that may already be plugged in.
//
// The distinction restored here is the one `device_selection.dart` has
// had since 04d3696 - "null is 'I could not ask', which is a different
// answer from 'nothing is attached'" - which `preflight` and `suite run`
// never adopted because they were not among the commands that crashed.
//
// What must not move: adb answering with no devices is a *successful*
// query, and keeps every word of its existing wording. So does a serial
// that is not in the list. Only the three failure paths change.
//
// Offline throughout, and no device: every case here is decided before
// anything is launched.
@Timeout(Duration(minutes: 8))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

const String _serial = 'FAKESERIAL1';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// An adb that behaves in one named way.
///
/// `ok`        lists one device and answers everything asked about it
/// `mute`      lists one device and fails every question about it
/// `empty`     answers, and reports no devices at all
/// `fail`      launches and exits non-zero
/// `unrunnable` exists and is not a program
String _fakeAdb(String kind) {
  final directory = Directory('${_root.path}/bin/$kind')
    ..createSync(recursive: true);

  if (kind == 'unrunnable') {
    // Exists, so `resolveAdb` locates it; not a program, so launching it
    // throws. On POSIX the missing execute bit does the same job.
    final file = File('${directory.path}/${Platform.isWindows ? 'adb.exe' : 'adb'}')
      ..writeAsStringSync('this is not a program\n');
    return file.path;
  }

  if (Platform.isWindows) {
    final file = File('${directory.path}/adb.bat');
    final listing = kind == 'empty'
        ? '  echo List of devices attached\r\n  exit /b 0\r\n'
        : '  echo List of devices attached\r\n'
            '  echo $_serial            device product:fake model:FakePhone '
            'device:fake\r\n  exit /b 0\r\n';
    if (kind == 'fail') {
      file.writeAsStringSync('@echo off\r\nexit /b 1\r\n');
      return file.path;
    }
    file.writeAsStringSync(
      '@echo off\r\n'
      'set ARGS=%*\r\n'
      'echo %ARGS% | findstr /C:"devices" >nul && (\r\n$listing)\r\n'
      '${kind == 'mute' ? 'exit /b 1\r\n' : 'echo %ARGS% | findstr '
          '/C:"ro.product.model" >nul && ( echo FakePhone & exit /b 0 )\r\n'
          'echo %ARGS% | findstr /C:"ro.build.version.release" >nul && '
          '( echo 13 & exit /b 0 )\r\n'
          'echo %ARGS% | findstr /C:"wm size" >nul && '
          '( echo Physical size: 720x1600 & exit /b 0 )\r\n'
          'echo %ARGS% | findstr /C:"wm density" >nul && '
          '( echo Physical density: 300 & exit /b 0 )\r\n'
          'echo %ARGS% | findstr /C:"pm list packages" >nul && '
          '( echo package:com.example.x & exit /b 0 )\r\n'
          'echo %ARGS% | findstr /C:"Active default network" >nul && '
          '( echo Active default network: 100 & exit /b 0 )\r\n'
          'exit /b 0\r\n'}',
    );
    return file.path;
  }

  final file = File('${directory.path}/adb');
  if (kind == 'fail') {
    file.writeAsStringSync('#!/bin/sh\nexit 1\n');
  } else {
    final listing = kind == 'empty'
        ? '    echo "List of devices attached"\n'
        : '    echo "List of devices attached"\n'
            '    echo "$_serial            device product:fake '
            'model:FakePhone device:fake"\n';
    final rest = kind == 'mute'
        ? '  *) exit 1 ;;\n'
        : '  *ro.product.model*) echo "FakePhone" ;;\n'
            '  *ro.build.version.release*) echo "13" ;;\n'
            '  *"wm size"*) echo "Physical size: 720x1600" ;;\n'
            '  *"wm density"*) echo "Physical density: 300" ;;\n'
            '  *"pm list packages"*) echo "package:com.example.x" ;;\n'
            '  *"Active default network"*) echo "Active default network: 100" ;;\n';
    file.writeAsStringSync(
      '#!/bin/sh\nargs="\$*"\ncase "\$args" in\n'
      '  *devices*)\n$listing    ;;\n$rest'
      'esac\nexit 0\n',
    );
  }
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// A path that is not there, so `resolveAdb` reports adb as unresolvable.
String get _noAdb => '${_root.path}/bin/absent/adb';

typedef Run = ({String output, int code});

Future<Run> _testsmith(List<String> arguments, {required String adb}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {'MYTEST_ADB': adb, 'MYTEST_AUTH_PIN': '0000'},
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

Future<Run> _preflight({required String adb, String? serial}) => _testsmith(
      [
        'preflight',
        '${_app.path}/suites/s.yaml',
        if (serial != null) ...['-d', serial],
      ],
      adb: adb,
    );

final RegExp _deviceRow = RegExp(r'\[(ok|BLOCK|defer)\]\s+device\s{2,}(.*)');
final RegExp _profileRow = RegExp(r'\[(ok|BLOCK|defer)\]\s+device profile\s+');

/// What the `device` row says, outcome and detail.
({String outcome, String detail}) _device(Run run) {
  final match = _deviceRow.firstMatch(run.output);
  expect(match, isNotNull, reason: 'no device row in:\n${run.output}');
  return (outcome: match!.group(1)!, detail: match.group(2)!.trim());
}

/// The two sentences that must never be said about a tool that never ran.
void expectNotBlamedOnTheDevice(Run run) {
  final detail = _device(run).detail;
  expect(detail, isNot(contains('no usable device is attached')),
      reason: run.output);
  expect(detail, isNot(contains('the named device is not attached')),
      reason: run.output);
  expect(run.output, isNot(contains('Unhandled exception')),
      reason: run.output);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('adb_provenance');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    _write('tests/home.yaml',
        'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n');
    _write(
      'suites/s.yaml',
      'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
      'device: {profile: p}\n'
      'tests:\n  - {id: home, flow: tests/home.yaml}\n',
    );
    _write(
      'device_profiles/p.yaml',
      'id: p\nmodel: FakePhone\nos: Android 13\n'
      'physical:\n  width: 720\n  height: 1600\n'
      'devicePixelRatio: 1.875\norientation: portrait\nbuildMode: debug\n',
    );
    _write('mappings/home.yaml',
        'screen: /home\nmappings:\n  - {target: t.a, source: response.a}\n');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('adb could not answer', () {
    test('1. unresolvable adb blocks and names adb, not the device', () async {
      final run = await _preflight(adb: _noAdb, serial: _serial);

      expect(run.code, 2, reason: run.output);
      expect(_device(run).outcome, 'BLOCK', reason: run.output);
      expect(_device(run).detail.toLowerCase(), contains('adb'),
          reason: run.output);
      expectNotBlamedOnTheDevice(run);
      // The resolver's own hint, which names the variable that is wrong.
      expect(run.output, contains('MYTEST_ADB'), reason: run.output);
    });

    test('2. an adb that will not launch blocks and says so', () async {
      final run =
          await _preflight(adb: _fakeAdb('unrunnable'), serial: _serial);

      expect(run.code, 2, reason: run.output);
      expect(_device(run).outcome, 'BLOCK', reason: run.output);
      expect(_device(run).detail.toLowerCase(), contains('adb'),
          reason: run.output);
      expectNotBlamedOnTheDevice(run);
    });

    test('3. an adb that exits non-zero blocks and says so', () async {
      final run = await _preflight(adb: _fakeAdb('fail'), serial: _serial);

      expect(run.code, 2, reason: run.output);
      expect(_device(run).outcome, 'BLOCK', reason: run.output);
      expect(_device(run).detail.toLowerCase(), contains('adb'),
          reason: run.output);
      expectNotBlamedOnTheDevice(run);
    });
  });

  group('adb answered, and what it said still stands', () {
    test('4. no devices is still an absent device, not an adb failure',
        () async {
      // The control the whole change turns on.
      final run = await _preflight(adb: _fakeAdb('empty'), serial: _serial);

      expect(run.code, 2, reason: run.output);
      final row = _device(run);
      expect(row.outcome, 'BLOCK', reason: run.output);
      expect(row.detail, 'no usable device is attached', reason: run.output);
    });

    test('5. a serial that is not there still names the serial', () async {
      final run = await _preflight(adb: _fakeAdb('ok'), serial: 'OTHER');

      expect(run.code, 2, reason: run.output);
      final row = _device(run);
      expect(row.outcome, 'BLOCK', reason: run.output);
      expect(row.detail, 'the named device is not attached',
          reason: run.output);
      expect(run.output, contains('Check the serial'), reason: run.output);
    });

    test('6. a device that answers nothing is E, not an adb failure',
        () async {
      // Milestone E, unchanged and kept distinct: adb worked and listed
      // the handset, so the device row is fine; the handset would not
      // answer, so the profile defers. Neither is an adb problem.
      final run = await _preflight(adb: _fakeAdb('mute'), serial: _serial);

      expect(_device(run).outcome, 'ok', reason: run.output);
      expect(run.output, contains(_profileRow), reason: run.output);
      expect(run.output, contains('[defer] device profile'),
          reason: run.output);
      expect(run.code, 0, reason: run.output);
    });
  });

  group('the same cause, wherever it is first noticed', () {
    test('7. suite run, choosing a device, reports adb rather than the device',
        () async {
      // `resolveSuiteContext` picks the device before any report exists,
      // and printed "No usable device attached. Run: testsmith devices"
      // for a machine whose adb was the problem.
      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml'],
        adb: _noAdb,
      );

      expect(run.code, 2, reason: run.output);
      expect(run.output, contains('MYTEST_ADB'), reason: run.output);
      expect(run.output, isNot(contains('No usable device attached')),
          reason: run.output);
      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
    });

    test('8. auth setup reports adb rather than the device', () async {
      _write(
        'auth/login.yaml',
        'auth: t\n'
        'app: {path: .., target: lib/main_mytest.dart}\n'
        'appId: com.example.x\n'
        'device:\n  profile: p\n'
        'secrets: {pin: env:MYTEST_AUTH_PIN}\n'
        'signedOutOn: [/login]\n'
        'login:\n  - tap: {id: login.submit}\n'
        'verify: {route: /home, element: home.body}\n',
      );

      final run = await _testsmith(
        ['auth', 'setup', '${_app.path}/auth/login.yaml'],
        adb: _noAdb,
      );

      // auth setup's own error code, unchanged.
      expect(run.code, 2, reason: run.output);
      expect(run.output, contains('MYTEST_ADB'), reason: run.output);
      expect(run.output, isNot(contains('No usable device attached')),
          reason: run.output);
    });
  });
}
