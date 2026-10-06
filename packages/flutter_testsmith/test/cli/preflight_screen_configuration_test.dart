// What `testsmith preflight` promises, measured against what a run does.
//
// E-04 §4: "A layer that answers one question - could this machine test
// anything? - before a suite spends minutes finding out it could not."
//
// Since `6749e7f` two files describing one screen are fatal: `run` and
// `suite run` both refuse to proceed. Preflight did not acquire those
// checks, so it answered the question wrongly. Measured on one project,
// at one moment, before this file existed:
//
//   testsmith preflight   [ok] x9 ... nothing blocking     exit 0
//   testsmith suite run   Duplicate screen configuration   exit 2
//
// Exit 0 is the part that matters: a CI gate reads it and lets the suite
// through, and the suite cannot run at all.
//
// This is deliberately *not* "preflight validates all project
// configuration". The line is narrower and is drawn by the run: a
// condition preflight must report is one already known to make every run
// of this suite fail.
//
// Offline throughout. `MYTEST_ADB` points at a fake adb that answers the
// handful of questions preflight asks a device, which is what lets a
// project reach "nothing blocking" with no hardware attached. It is
// built per platform - see `_fakeAdb` for why a `.bat` alone left every
// test here failing on the one CI runs on.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

const String _nothingBlocking = 'nothing blocking';
const String _duplicate = 'Duplicate screen configuration';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

String _spec(String figmaName) => '{"screen":"/home","nodeId":"1:1",'
    '"figmaName":"$figmaName","width":400.0,"height":800.0,'
    '"elements":[],"totalNodesWalked":1}';

String _mapping(String target) =>
    'screen: /home\nmappings:\n  - {target: $target, source: response.a}\n';

/// An adb that answers what preflight asks, and nothing more.
///
/// Every reading matches `device_profiles/p.yaml` below, so a project
/// that is otherwise sound reports "nothing blocking" - which is the
/// state this milestone is about.
///
/// Built per platform, as every other fake adb in this tree is. A `.bat`
/// alone is not merely unidiomatic off Windows: `File.writeAsStringSync`
/// leaves it mode 0644, `resolveAdb` locates it by existence alone and
/// never asks whether it can run, and `SystemProcessRunner` execs it
/// directly - so on POSIX the run gets EACCES, `attachedDevices` reports
/// "adb is at ..., but it would not run", and `resolveSuiteContext`
/// stops before `PreflightRunner` prints a single row. Every assertion
/// below would then fail for a reason that has nothing to do with
/// screen configuration.
String _fakeAdb() {
  final directory = Directory('${_root.path}/fake')..createSync(recursive: true);
  if (Platform.isWindows) {
    final file = File('${directory.path}/adb.bat')
      ..writeAsStringSync(
        '@echo off\r\n'
        'set ARGS=%*\r\n'
        'echo %ARGS% | findstr /C:"devices" >nul && (\r\n'
        '  echo List of devices attached\r\n'
        '  echo FAKESERIAL1            device product:fake model:FakePhone '
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

Future<Run> _preflight() async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'preflight',
      '${_app.path}/suites/s.yaml',
    ],
    environment: {'MYTEST_ADB': _fakeAdb()},
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('preflight_screens');
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

  test('a sound project is still reported ready', () async {
    // The control, and the reason the other two mean anything: without
    // it, a blocked preflight would prove nothing about the new check.
    final run = await _preflight();

    expect(run.output, contains(_nothingBlocking), reason: run.output);
    expect(run.code, 0, reason: run.output);
    expect(run.output, isNot(contains(_duplicate)), reason: run.output);
  });

  test('and every check it already made is still made', () async {
    // The nine E-04 names. A new check must be an addition, not a
    // replacement.
    final run = await _preflight();

    for (final name in const [
      'application build',
      'device',
      'device profile',
      'application installed',
      'permissions',
      'network interface',
      'mock API',
      'baselines',
      'authentication',
    ]) {
      expect(run.output, contains(name), reason: '$name missing:\n${run.output}');
    }
  });

  test('two mappings for one screen block it', () async {
    _write('mappings/a.yaml', _mapping('t.a'));
    _write('mappings/z.yaml', _mapping('t.z'));

    final run = await _preflight();

    expect(run.output, isNot(contains(_nothingBlocking)), reason: run.output);
    expect(run.code, 2, reason: run.output);
    expect(run.output, contains('/home'), reason: run.output);
    expect(run.output, contains('a.yaml'), reason: run.output);
    expect(run.output, contains('z.yaml'), reason: run.output);
    expect(run.output, isNot(contains('Unhandled exception')),
        reason: run.output);
  });

  test('two on-disk specs for one screen block it', () async {
    _write('figma/a.json', _spec('A'));
    _write('figma/z.json', _spec('Z'));

    final run = await _preflight();

    expect(run.output, isNot(contains(_nothingBlocking)), reason: run.output);
    expect(run.code, 2, reason: run.output);
    expect(run.output, contains('/home'), reason: run.output);
    expect(run.output, contains('a.json'), reason: run.output);
    expect(run.output, contains('z.json'), reason: run.output);
    expect(run.output, isNot(contains('Unhandled exception')),
        reason: run.output);
  });

  test('and it names the condition the way a run does', () async {
    // The point of the milestone: preflight's answer and the run's
    // answer are about one condition, so they use one vocabulary.
    //
    // Case-insensitively, because the report puts each detail in a
    // column as a sentence fragment - "port 8080 is in use", "none
    // attached" - while the run's message is a sentence of its own.
    _write('mappings/a.yaml', _mapping('t.a'));
    _write('mappings/z.yaml', _mapping('t.z'));

    final run = await _preflight();

    expect(run.output.toLowerCase(), contains(_duplicate.toLowerCase()),
        reason: run.output);
  });
}
