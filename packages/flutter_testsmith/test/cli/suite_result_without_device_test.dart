// A-4: a suite that never chose a device still leaves a result behind.
//
// `resolveSuiteContext` refused outright when no `--device` was given
// and no serial could be inferred, so `suite run` returned 2 from the
// line above the one that writes the report. Measured on one project
// against 107d5ac, with nothing attached:
//
//   suite run <suite>                    No usable device attached.
//                                        exit 2, and no output directory
//                                        at all
//   suite run <suite> -d no-such-device  the whole preflight report,
//                                        exit 2, suite.json + suite.html
//
// The same physical situation, and the more specific invocation - the
// one naming a device that does not even exist - got the better answer.
// A gate reading the output directory could not tell "nothing ran
// because there is no device" from "nothing ran", which is the exact
// distinction M-1 added `blockedSuiteResult` to draw one stage later.
//
// Nothing new decides any of this. `checkDeviceAttached` has always had
// a `requested == null` branch answering all three cases - nothing
// attached, several attached, an adb that would not run - and it was
// simply unreachable, because `SuiteContext.serial` could not be absent.
//
// Offline throughout, and no handset: each fake adb answers `devices -l`
// with the situation under test and nothing is ever launched. Built per
// platform, as every fake adb in this tree is - a `.bat` alone is not
// executable on the platform CI runs on.
@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

/// What each fake adb answers `devices -l` with.
const String _none = '';
const String _one =
    'FAKESERIAL1            device product:fake model:FakePhone device:fake';
const String _two = 'SERIAL_ONE            device product:a model:PhoneA '
    'device:a\nSERIAL_TWO            device product:b model:PhoneB device:b';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// An adb reporting exactly [devices], and answering what preflight asks.
///
/// [devices] is the body of `devices -l`, one handset per line; empty is
/// a successful query that found nothing, which is the whole point of
/// the first case below and is not the same as adb failing.
String _fakeAdb(String devices) {
  final directory = Directory('${_root.path}/bin')..createSync(recursive: true);
  if (Platform.isWindows) {
    final listing = devices.isEmpty
        ? ''
        : devices.split('\n').map((line) => '  echo $line\r\n').join();
    final file = File('${directory.path}/adb.bat')
      ..writeAsStringSync(
        '@echo off\r\n'
        'set ARGS=%*\r\n'
        'echo %ARGS% | findstr /C:"devices" >nul && (\r\n'
        '  echo List of devices attached\r\n'
        '$listing'
        '  exit /b 0\r\n'
        ')\r\n'
        'echo %ARGS% | findstr /C:"ro.product.model" >nul && '
        '( echo FakePhone & exit /b 0 )\r\n'
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
        'exit /b 0\r\n',
      );
    return file.path;
  }

  final listing =
      devices.isEmpty ? '' : devices.split('\n').map((l) => '    echo "$l"\n').join();
  final file = File('${directory.path}/adb')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'args="\$*"\n'
      'case "\$args" in\n'
      '  *devices*)\n'
      '    echo "List of devices attached"\n'
      '$listing'
      '    ;;\n'
      '  *ro.product.model*) echo "FakePhone" ;;\n'
      '  *ro.build.version.release*) echo "13" ;;\n'
      '  *"wm size"*) echo "Physical size: 720x1600" ;;\n'
      '  *"wm density"*) echo "Physical density: 300" ;;\n'
      '  *"pm list packages"*) echo "package:com.example.x" ;;\n'
      '  *"Active default network"*) echo "Active default network: 100" ;;\n'
      'esac\n'
      'exit 0\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// A path nothing is at, for the adb-unavailable case.
String get _absentAdb => '${_root.path}/nowhere/adb';

typedef Run = ({String output, int code});

Future<Run> _testsmith(List<String> arguments, {required String adb}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {
      'MYTEST_ADB': adb,
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

Future<Run> _suiteRun(String adb, [List<String> extra = const []]) =>
    _testsmith(
      ['suite', 'run', '${_app.path}/suites/s.yaml', ...extra],
      adb: adb,
    );

/// The `device` row of the result a gate reads.
///
/// From `suite.json` rather than the terminal throughout: the terminal
/// always said something, and the copy that outlives the run is what was
/// missing.
({Map<String, Object?> device, Map<String, Object?> json}) _result() {
  final file = File('${_app.path}/out/suite/suite.json');
  expect(file.existsSync(), isTrue, reason: 'no suite.json was written');

  final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final preflight = json['preflight']! as Map<String, Object?>;
  final rows = (preflight['checks']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .where((check) => check['name'] == 'device');

  expect(rows, isNotEmpty, reason: '$json');
  return (device: rows.first, json: json);
}

/// What every blocked run below must do, whichever condition blocked it.
void expectBlockedWithoutLaunching(Run run) {
  expect(run.code, 2, reason: run.output);
  expect(run.output, isNot(contains('launching app')), reason: run.output);
  expect(run.output, isNot(contains('waking device')), reason: run.output);
  expect(run.output, isNot(contains('Unhandled exception')),
      reason: run.output);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('suite_no_device');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
    );
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
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('no device could be chosen, and none was named', () {
    test('nothing attached still writes the result a gate reads', () async {
      final run = await _suiteRun(_fakeAdb(_none));
      expectBlockedWithoutLaunching(run);

      final found = _result();
      expect(
        (found.json['preflight']! as Map<String, Object?>)['blocked'],
        isTrue,
        reason: run.output,
      );
      expect(found.device['outcome'], 'blocked', reason: '${found.device}');
      expect(found.device['detail'], 'no usable device is attached',
          reason: '${found.device}');

      // The rest of the report M-1 established, unchanged: this is an
      // environment answer, and nothing failed.
      final tests = (found.json['tests']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(tests.first['classification'], 'environment', reason: run.output);
      expect((found.json['counts']! as Map<String, Object?>)['fail'], 0,
          reason: run.output);
      expect(found.json['exitCode'], 2, reason: run.output);
    });

    test('several attached records the count, and still lists them',
        () async {
      // The count is what the check carries; the serials are what the
      // old refusal carried and the check does not. Somebody has to
      // choose one, so both halves have to survive.
      final run = await _suiteRun(_fakeAdb(_two));
      expectBlockedWithoutLaunching(run);

      final found = _result();
      expect(found.device['outcome'], 'blocked', reason: '${found.device}');
      expect(found.device['detail'], contains('2'), reason: '${found.device}');
      expect(run.output, contains('SERIAL_ONE'), reason: run.output);
      expect(run.output, contains('SERIAL_TWO'), reason: run.output);
    });

    test('an adb that is not there says so, and claims nothing about a '
        'handset', () async {
      // D's contract, which this must not undo: "adb would not run" and
      // "adb ran and nothing is plugged in" are different sentences with
      // different remedies, and only one of them is about a device.
      final run = await _suiteRun(_absentAdb);
      expectBlockedWithoutLaunching(run);

      final found = _result();
      expect(found.device['outcome'], 'blocked', reason: '${found.device}');
      expect(found.device['detail'], contains('MYTEST_ADB'),
          reason: '${found.device}');
      expect(found.device['detail'],
          isNot(contains('no usable device is attached')),
          reason: '${found.device}');
    });

    test('and the result agrees with the one a named device produces',
        () async {
      // The parity this milestone is about. `-d no-such-device` already
      // produced a result; naming nothing produced none. For the same
      // physical state the two must now say the same thing.
      final adb = _fakeAdb(_none);

      await _suiteRun(adb);
      final without = _result().device;

      await _suiteRun(adb, const ['-d', 'no-such-device']);
      final named = _result().device;

      expect(without['name'], named['name']);
      expect(without['outcome'], named['outcome']);
      expect(without['class'], named['class']);
    });
  });

  group('what A-4 must not have changed', () {
    test('a named device that is not attached still writes its result',
        () async {
      // The path `suite_command_exit_codes_test` already guards, asserted
      // here too because this milestone rewrote the branch above it.
      final run = await _suiteRun(_fakeAdb(_none), const [
        '-d',
        'no-such-device',
      ]);
      expectBlockedWithoutLaunching(run);

      expect(_result().device['detail'], 'no usable device is attached',
          reason: run.output);
    });

    test('one attached and none named is still inferred, and still runs',
        () async {
      // The control that matters most: the inference is the reason a
      // developer never types `--device`, and turning it into a refusal
      // would be a far worse defect than the one being fixed. Asserted
      // through `preflight`, which answers without building anything.
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        adb: _fakeAdb(_one),
      );

      expect(run.output, contains(RegExp(r'\[ok\]\s+device')),
          reason: run.output);
      expect(run.output, contains('nothing blocking'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });

    test('a refusal before the device stage still invents no result',
        () async {
      // The boundary. These stop before a profile has been read, so
      // there is nothing to build a result from - and reporting one
      // would be claiming a suite was evaluated when it was not.
      _write(
        'suites/s.yaml',
        'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
        'device: {profile: p}\n'
        'tests:\n  - {id: home, flow: tests/nowhere.yaml}\n',
      );

      final run = await _suiteRun(_fakeAdb(_none));

      expect(run.code, 2, reason: run.output);
      expect(run.output, contains('nowhere.yaml'), reason: run.output);
      expect(File('${_app.path}/out/suite/suite.json').existsSync(), isFalse,
          reason: run.output);
    });
  });
}
