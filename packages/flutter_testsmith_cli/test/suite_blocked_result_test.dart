// M-1: a blocked suite leaves `suite.json` behind, whatever blocked it.
//
// `suite run` writes a machine-readable result when preflight blocks -
// "CI wants a machine-readable answer whether or not a test ran, and 'we
// could not test it' is an answer". Three deterministic blockers never
// reached that line, because `suite run` reads the project for itself at
// step 5 and returns before preflight at step 7:
//
//   mappings/home.yaml will not parse        exit 2, no out/ at all
//   two mappings name one screen             exit 2, no out/ at all
//   two figma specs name one screen          exit 2, no out/ at all
//   mock_api/scenarios/*.json will not parse exit 2, no out/ at all
//
// while a malformed flow, a proposed flow, an occupied port and a missing
// device all produce one. A gate reading `suite.json` therefore saw the
// same empty directory for "the suite is fine and nothing ran" as for
// "one of your mappings has a typo in it".
//
// Accidental asymmetry rather than a decision: nothing about these four
// makes them less worth reporting, and the lifecycle does not have to
// move to report them. The refusal stays exactly where 5e9c169 put it -
// before the device, before preflight, before the fixture server binds -
// and writes the result on its way out, through the same
// `blockedSuiteResult` the preflight path already uses.
//
// Exit codes are untouched: 2 before, 2 after, from the same
// `SuiteResult.exitCode`.
//
// Offline throughout. The fake adb answers what preflight asks, so a
// sound project reaches "nothing blocking" with no hardware attached -
// which is what makes each blocked run below mean something.
@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
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

String _spec(String screen, String name) => jsonEncode({
      'screen': screen,
      'nodeId': '1:1',
      'figmaName': name,
      'width': 400.0,
      'height': 800.0,
      'elements': const <Object>[],
      'totalNodesWalked': 1,
    });

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// An adb that answers what preflight asks, and nothing more.
///
/// The same fake `preflight_project_facts_test.dart` uses, and
/// cross-platform for the same reason: a `.bat` alone would make every
/// assertion here Windows-only, and CI is ubuntu.
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

Future<Run> _suiteRun() => _testsmith(
      ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _serial],
    );

Future<Run> _preflight() =>
    _testsmith(['preflight', '${_app.path}/suites/s.yaml', '-d', _serial]);

/// The report a gate reads, parsed.
Map<String, Object?> _suiteJson() {
  final file = File('${_app.path}/out/suite/suite.json');
  expect(file.existsSync(), isTrue, reason: 'no suite.json was written');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

/// Every blocking check the report carries.
List<Map<String, Object?>> _blockers(Map<String, Object?> json) {
  final preflight = json['preflight'] as Map<String, Object?>?;
  expect(preflight, isNotNull, reason: 'the result carried no preflight block');
  return [
    for (final check in preflight!['checks'] as List<Object?>)
      if ((check as Map<String, Object?>)['outcome'] == 'blocked') check,
  ];
}

/// What every deterministically blocked suite must do.
///
/// The exit code is asserted at 2 rather than merely "non-zero": this
/// milestone is about what is written alongside it, and a changed code
/// would be a taxonomy change nobody asked for.
void expectBlockedResult(
  Run run, {
  required String check,
  required String names,
}) {
  expect(run.code, 2, reason: run.output);

  // Nothing was launched, and nothing was done to the handset: the
  // refusal still happens where 5e9c169 put it.
  expect(run.output, isNot(contains('launching app')), reason: run.output);
  expect(run.output, isNot(contains('waking device')), reason: run.output);
  expect(run.output, isNot(contains('Unhandled exception')),
      reason: run.output);

  final json = _suiteJson();
  expect(json['exitCode'], 2, reason: run.output);
  expect(json['verdict'], 'error', reason: run.output);
  expect((json['preflight']! as Map<String, Object?>)['blocked'], isTrue);

  final blocking = _blockers(json);
  expect(blocking.map((c) => c['name']), contains(check), reason: '$json');

  final named = blocking.firstWhere((c) => c['name'] == check);
  expect(named['detail'], contains(names), reason: '$json');
  // A blocker carries what to do about it, here as everywhere else.
  expect(named['remedy'], isNotEmpty, reason: '$json');

  // And the per-test rows say the suite was blocked, not that the
  // application failed anything.
  for (final test in json['tests']! as List<Object?>) {
    final row = test as Map<String, Object?>;
    expect(row['reason'], contains('preflight blocked'), reason: '$json');
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('suite_blocked');
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

  test('a mapping that will not parse is written to suite.json', () async {
    _write('mappings/home.yaml', _brokenYaml);

    final run = await _suiteRun();

    expectBlockedResult(
      run,
      check: 'screen configuration',
      names: 'home.yaml',
    );
  });

  test('two mappings for one screen are written to suite.json', () async {
    _write('mappings/a_home.yaml', _mapping);
    _write('mappings/z_home.yaml', _mapping);

    final run = await _suiteRun();

    expectBlockedResult(
      run,
      check: 'screen configuration',
      names: '/home',
    );
  });

  test('two designs for one screen are written to suite.json', () async {
    // The second duplicate site. `loadFigmaSpecs` refuses separately
    // from `loadMappings`, and returned from its own line.
    _write('mappings/home.yaml', _mapping);
    _write('figma/a_home.json', _spec('/home', 'A'));
    _write('figma/z_home.json', _spec('/home', 'Z'));

    final run = await _suiteRun();

    expectBlockedResult(
      run,
      check: 'screen configuration',
      names: '/home',
    );
  });

  test('a scenario that will not parse is written to suite.json', () async {
    _write('mappings/home.yaml', _mapping);
    _write(
      'suites/s.yaml',
      'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
      'device: {profile: p}\n'
      'mockApi: {port: 8129}\n'
      'tests:\n  - {id: home, flow: tests/home.yaml}\n',
    );
    _write('mock_api/scenarios/default.json', '{ this is not json');

    final run = await _suiteRun();

    // The same phrasing `PreflightRunner._mockApi` uses for this exact
    // condition, on purpose: two commands describing one malformed file
    // two different ways is the drift this repository keeps closing.
    // Since A-2 that phrasing names the file, as the mapping row beside
    // it always has - `error.message` alone said `invalid JSON: ...`
    // about a directory and left a reader to find out which of its
    // files, under a remedy reading "Fix the scenario file".
    expectBlockedResult(
      run,
      check: 'mock API',
      names: 'default.json: invalid JSON',
    );
    // The terminal line still carries the path, as it always did.
    expect(run.output, contains('default.json'), reason: run.output);
  });

  group('what M-1 must not have changed', () {
    test('a preflight blocker still writes suite.json', () async {
      // The path that already worked. The profile names a handset the
      // fake adb does not report, so preflight blocks at step 7 - well
      // past the three guards above - and the report it writes must be
      // the same shape.
      _write('mappings/home.yaml', _mapping);
      _write('device_profiles/p.yaml', 'id: p\nmodel: Pixel 7\n');

      final run = await _suiteRun();

      expectBlockedResult(run, check: 'device profile', names: 'Pixel 7');
    });

    test('a sound project reports nothing blocking', () async {
      // The control. Without it none of the rest proves anything: every
      // assertion above would also hold for a guard that fired on every
      // project it was given.
      _write('mappings/home.yaml', _mapping);

      final run = await _preflight();

      expect(run.output, contains('nothing blocking'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });
  });
}
