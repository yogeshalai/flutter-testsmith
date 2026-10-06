// Three project facts a suite cannot run with, through the commands.
//
// Each is deterministic, readable from the project alone before any
// device is touched, and already refused outright by `testsmith run`.
// Preflight said "nothing blocking" for all three, and for two of them
// it printed an affirmative about a question it had not answered.
// Measured on one project before this file existed:
//
//   mappings/home.yaml will not parse
//     run 1 · suite run 2 · preflight 0, `[ok] screen configuration`
//   tests/home.yaml will not parse
//     run 1 · suite run per-test ERROR · preflight 0, flow never named
//   the flow declares `fixture:` and the suite declares no mockApi.port
//     run 1 · suite run per-test ERROR · preflight 0, `[ok] mock API`
//
// What a blocked suite must still do is the other half of this: stop
// before the device, and leave `suite.json` behind saying why, because
// a gate reads that rather than the terminal.
//
// Offline throughout. The fake adb answers what preflight asks, so a
// sound project reaches "nothing blocking" with no hardware - which is
// what makes each blocked run below mean something. The two `optional:`
// cases are asserted through `preflight` rather than `suite run`,
// because a notice is not a blocker and the suite goes on to launch.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

const String _serial = 'FAKESERIAL1';

const String _flow = 'appId: com.example.x\n'
    'flow: home\n'
    'steps:\n'
    '  - launchApp\n';

const String _mapping =
    'screen: /home\nmappings:\n  - {target: t.a, source: response.a}\n';

const String _brokenYaml = 'screen: [this will not parse\n';

/// Two tests, the second of which the suite does not require.
const String _twoTests = 'suite: s\n'
    'app: {path: .., target: lib/main_mytest.dart}\n'
    'device: {profile: p}\n'
    'tests:\n'
    '  - {id: home, flow: tests/home.yaml}\n'
    '  - {id: extra, flow: tests/extra.yaml, optional: true}\n';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// An adb that answers what preflight asks, and nothing more.
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

Future<Run> _preflight() =>
    _testsmith(['preflight', '${_app.path}/suites/s.yaml', '-d', _serial]);

Future<Run> _suiteRun() => _testsmith(
      ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _serial],
    );

/// What a blocked suite must do, whichever fact blocked it.
void expectStoppedBeforeTheDevice(Run run, String check) {
  expect(run.code, 2, reason: run.output);
  expect(run.output, isNot(contains('launching app')), reason: run.output);
  expect(run.output, isNot(contains('waking device')), reason: run.output);
  expect(run.output, isNot(contains('Unhandled exception')),
      reason: run.output);

  final file = File('${_app.path}/out/suite/suite.json');
  expect(file.existsSync(), isTrue, reason: 'no suite.json was written');
  expect(file.readAsStringSync(), contains(check));
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('project_facts');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    _write('tests/home.yaml', _flow);
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

  test('a sound project still reports nothing blocking', () async {
    // The control. Without it none of the rest proves anything.
    _write('mappings/home.yaml', _mapping);

    final run = await _preflight();

    expect(run.output, contains('nothing blocking'), reason: run.output);
    expect(run.code, 0, reason: run.output);
  });

  group('a mapping that will not parse', () {
    test('stops the suite before it touches the device', () async {
      // The refusal is still exactly where 5e9c169 put it: `suite run`
      // loads the mappings itself, before preflight and before the
      // device is touched. That much is unchanged.
      //
      // What it leaves behind is not. This path reached no report, so a
      // gate saw the same empty directory here as for a suite that was
      // fine - and the reasoning that it could not have one without
      // reordering the lifecycle turned out to be wrong: M-1 writes it
      // from where the refusal already happens, through the same
      // `blockedSuiteResult` preflight uses. The report's contents are
      // held to in `suite_blocked_result_test.dart`; what matters here
      // is that refusing early and reporting are not alternatives.
      _write('mappings/home.yaml', _brokenYaml);

      final run = await _suiteRun();

      expect(run.code, 2, reason: run.output);
      expect(run.output, contains('home.yaml'), reason: run.output);
      expect(run.output, isNot(contains('launching app')), reason: run.output);
      expect(run.output, isNot(contains('waking device')), reason: run.output);
      expect(
        File('${_app.path}/out/suite/suite.json').existsSync(),
        isTrue,
        reason: 'the suite refused without saying so where CI reads',
      );
    });

    test('and preflight names the file instead of saying it is fine',
        () async {
      _write('mappings/home.yaml', _brokenYaml);

      final run = await _preflight();

      expect(run.output, contains(RegExp(r'\[BLOCK\]\s+screen configuration')),
          reason: run.output);
      expect(run.output, contains('home.yaml'), reason: run.output);
      expect(run.output, isNot(contains('one configuration per screen')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('while two files for one screen still block, as they did',
        () async {
      // C7 and P-1, unchanged: a different question with a different
      // answer, and the message still names both files.
      _write('mappings/a_home.yaml', _mapping);
      _write('mappings/z_home.yaml', _mapping);

      final run = await _preflight();

      expect(run.output, contains(RegExp(r'\[BLOCK\]\s+screen configuration')),
          reason: run.output);
      expect(run.output, contains('a_home.yaml'), reason: run.output);
      expect(run.output, contains('z_home.yaml'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });

  group('a flow that will not parse', () {
    test('blocks the suite when the suite requires that test', () async {
      _write('tests/home.yaml', 'appId: [this will not parse\n');

      expectStoppedBeforeTheDevice(await _suiteRun(), 'flows');
    });

    test('and is still named when another flow reads perfectly well',
        () async {
      // The case that hid it: with something to parse, every other row
      // appeared and the report read as though the suite were sound.
      _write('tests/extra.yaml', _flow);
      _write('tests/home.yaml', 'appId: [this will not parse\n');
      _write('suites/s.yaml', _twoTests.replaceFirst(', optional: true', ''));

      final run = await _preflight();

      expect(run.output, contains(RegExp(r'\[BLOCK\]\s+flows')),
          reason: run.output);
      expect(run.output, contains('home'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('is a notice when the suite does not require that test', () async {
      // Not a blocker: the verdict counts only required tests, so this
      // suite can still pass. Reported all the same.
      _write('tests/extra.yaml', 'appId: [this will not parse\n');
      _write('suites/s.yaml', _twoTests);

      final run = await _preflight();

      expect(run.output, contains('extra'), reason: run.output);
      expect(run.output, isNot(contains(RegExp(r'\[BLOCK\]\s+flows'))),
          reason: run.output);
      expect(run.output, contains('nothing blocking'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });

    test('and its acceptance is deferred rather than asserted', () async {
      // `flow status` reads a parsed flow. It may not report that every
      // flow has been accepted when one of them was never read.
      _write('tests/home.yaml', 'appId: [this will not parse\n');

      final run = await _preflight();

      expect(run.output, isNot(contains('every flow this suite names has '
          'been accepted')), reason: run.output);
    });
  });

  group('a flow that names an API state the suite cannot arrange', () {
    test('blocks the suite when the suite requires that test', () async {
      _write('tests/home.yaml', _flow.replaceFirst(
        'steps:',
        'fixture: signed_in\nsteps:',
      ));

      expectStoppedBeforeTheDevice(await _suiteRun(), 'mock API');
    });

    test('and preflight names the state instead of saying there is none',
        () async {
      _write('tests/home.yaml', _flow.replaceFirst(
        'steps:',
        'fixture: signed_in\nsteps:',
      ));

      final run = await _preflight();

      expect(run.output, contains(RegExp(r'\[BLOCK\]\s+mock API')),
          reason: run.output);
      expect(run.output, contains('signed_in'), reason: run.output);
      expect(run.output, isNot(contains('this suite declares no mock API')),
          reason: run.output);
    });

    test('is a notice when the suite does not require that test', () async {
      _write('tests/extra.yaml', _flow.replaceFirst(
        'steps:',
        'fixture: signed_in\nsteps:',
      ));
      _write('suites/s.yaml', _twoTests);

      final run = await _preflight();

      expect(run.output, contains('signed_in'), reason: run.output);
      expect(run.output, contains('nothing blocking'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });

    test('and a suite that declares a port is unchanged', () async {
      _write('tests/home.yaml', _flow.replaceFirst(
        'steps:',
        'fixture: signed_in\nsteps:',
      ));
      _write('mock_api/scenarios/default.json',
          '{"name": "default", "routes": {"GET /a": {"status": 200}}}');
      _write('mock_api/scenarios/signed_in.json',
          '{"name": "signed_in", "routes": {"GET /a": {"status": 200}}}');
      _write(
        'suites/s.yaml',
        'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
        'device: {profile: p}\nmockApi: {port: 8099}\n'
        'tests:\n  - {id: home, flow: tests/home.yaml}\n',
      );

      final run = await _preflight();

      expect(run.output, contains('nothing blocking'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });
  });

  group('the milestones this sits on top of still hold', () {
    test('a proposed flow still blocks the suite', () async {
      _write('tests/home.yaml',
          _flow.replaceFirst('steps:', 'status: proposed\nsteps:'));

      expectStoppedBeforeTheDevice(await _suiteRun(), 'flow status');
    });

    test('and suite run still has no way to allow one', () async {
      final run = await _testsmith([
        'suite', 'run', '${_app.path}/suites/s.yaml', '-d', _serial,
        '--allow-proposed',
      ]);

      expect(run.code, 64, reason: run.output);
    });

    test('two designs for one screen still block', () async {
      const spec = '{"screen":"/home","nodeId":"1:1","figmaName":"H",'
          '"width":400.0,"height":800.0,"elements":[],"totalNodesWalked":1}';
      _write('figma/a_home.json', spec);
      _write('figma/z_home.json', spec);

      final run = await _preflight();

      expect(run.output, contains(RegExp(r'\[BLOCK\]\s+screen configuration')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('and a design that will not read is still only advisory', () async {
      // R1: a spec describing no screen conflicts with nothing, so it is
      // reported and skipped. Widening the mapping branch must not have
      // dragged it along.
      _write('figma/stray.json', '{"a": 1}');

      final run = await _preflight();

      expect(run.output, contains('nothing blocking'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });
  });
}
