// A generated flow nobody has read must not be run by a suite either.
//
// CLAUDE.md states the invariant as "generated flows are stamped
// `status: proposed` by the generator - not by the model - and refuse to
// run", and `testsmith run` has refused them from the start. The suite
// path never learned it: `isProposed` was read by `run_command` and by
// `ProjectIndexer` (which keeps proposals out of test selection) and
// nowhere else. Measured on one project, the same flow file:
//
//   testsmith run        "home" is marked `status: proposed` …      exit 1
//   testsmith preflight  nothing blocking                           exit 0
//   testsmith suite run  nothing blocking … › launching app
//
// So a suite launched a flow a model wrote, and returned a pass or fail
// about the application from it. That is the one thing ADR-0009 exists
// to prevent, and it is worse than a missing check: the verdict looks
// like every other verdict.
//
// Offline throughout. The fake adb answers what preflight asks, so a
// sound project reaches "nothing blocking" with no hardware - which is
// what makes the blocked runs below mean something.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

const String _serial = 'FAKESERIAL1';

/// The flow both commands are pointed at.
const String _accepted = 'appId: com.example.x\n'
    'flow: home\n'
    'steps:\n'
    '  - launchApp\n';

/// The same flow, as the generator writes it.
const String _proposed = 'appId: com.example.x\n'
    'flow: home\n'
    'status: proposed\n'
    'steps:\n'
    '  - launchApp\n';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// An adb that answers what preflight asks, and nothing more.
///
/// Every reading matches `device_profiles/p.yaml` below, so a project
/// whose flows have all been accepted reports "nothing blocking".
String _fakeAdb() {
  final directory = Directory('${_root.path}/bin')..createSync(recursive: true);
  if (Platform.isWindows) {
    final file = File('${directory.path}/adb.bat')
      ..writeAsStringSync(
        '@echo off\r\n'
        'set ARGS=%*\r\n'
        'echo %ARGS% | findstr /C:"devices" >nul && (\r\n'
        '  echo List of devices attached\r\n'
        '  echo $_serial            device product:fake model:FakePhone '
        'device:fake\r\n'
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
  final file = File('${directory.path}/adb')
    ..writeAsStringSync(
      // Raw, so the shell's own variables survive being a Dart string.
      r'''#!/bin/sh
args="$*"
case "$args" in
  *devices*)
    echo "List of devices attached"
    echo "FAKESERIAL1            device product:fake model:FakePhone device:fake"
    ;;
  *ro.product.model*) echo "FakePhone" ;;
  *ro.build.version.release*) echo "13" ;;
  *"wm size"*) echo "Physical size: 720x1600" ;;
  *"wm density"*) echo "Physical density: 300" ;;
  *"pm list packages"*) echo "package:com.example.x" ;;
  *"Active default network"*) echo "Active default network: 100" ;;
esac
exit 0
''',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

typedef Run = ({String output, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {'MYTEST_ADB': _fakeAdb()},
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('proposed_flow');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    _write('tests/home.yaml', _proposed);
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

  test('preflight blocks a suite that names one', () async {
    final run = await _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _serial],
    );

    expect(run.output, contains(RegExp(r'\[BLOCK\]\s+flow status')),
        reason: run.output);
    expect(run.output, contains('home'), reason: run.output);
    expect(run.code, 2, reason: run.output);
  });

  test('and says what accepting it means', () async {
    final run = await _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _serial],
    );

    expect(run.output, contains('status: proposed'), reason: run.output);
  });

  test('suite run stops before it launches anything', () async {
    final run = await _testsmith(
      ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _serial],
    );

    expect(run.code, 2, reason: run.output);
    expect(run.output, isNot(contains('launching app')), reason: run.output);
    expect(run.output, isNot(contains('waking device')), reason: run.output);
  });

  test('and still leaves CI a machine-readable answer', () async {
    // A blocked preflight writes its result precisely so a gate can read
    // why nothing ran. Refusing the suite earlier, before the report
    // exists, would have taken that away.
    await _testsmith(
      ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _serial],
    );

    final file = File('${_app.path}/out/suite/suite.json');
    expect(file.existsSync(), isTrue, reason: 'no suite.json was written');

    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(jsonEncode(json), contains('flow status'));
    expect(json['exitCode'], 2);
  });

  test('a suite whose flows have all been accepted is untouched', () async {
    // The control, and the reason the rest mean anything.
    _write('tests/home.yaml', _accepted);

    final run = await _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _serial],
    );

    expect(run.output, contains('nothing blocking'), reason: run.output);
    expect(run.output, contains(RegExp(r'\[ok\]\s+flow status')),
        reason: run.output);
    expect(run.code, 0, reason: run.output);
  });

  group('the one place a proposal may be tried is unchanged', () {
    test('testsmith run still refuses it', () async {
      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path,
          '-d', 'NOSUCHDEVICE'],
      );

      expect(run.output, contains('status: proposed'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('and --allow-proposed still gets past it', () async {
      // It reaches the device it was told to use, which is the next
      // thing it does - so the status line was not what stopped it.
      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path,
          '-d', 'NOSUCHDEVICE', '--allow-proposed'],
      );

      expect(run.output, contains('NOSUCHDEVICE'), reason: run.output);
      expect(run.output, isNot(contains('status: proposed')),
          reason: run.output);
    });

    test('but a suite has no such flag', () async {
      // Deliberately absent. `--allow-proposed` is a person trying one
      // flow by hand; a suite is what CI gates on, and a flag there
      // would be a supported way to run unreviewed generated tests.
      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _serial,
          '--allow-proposed'],
      );

      expect(run.code, 64, reason: run.output);
      expect(run.output, contains('allow-proposed'), reason: run.output);
    });
  });
}
