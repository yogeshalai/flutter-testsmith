// A-2: a scenario file that will not parse is reported by name.
//
// `ScenarioFormatException` keeps the file in `source` and the reason in
// `message`; only its `toString()` joins them. Both readers of this
// condition took the reason alone, so the finding named no file at all.
// Measured on one project holding three scenarios, against 4600ea7:
//
//   testsmith preflight
//     [BLOCK] mock API  unknown key "routez". Known: name, ...
//             -> Fix the scenario file.
//
//   testsmith suite run
//     terminal   ScenarioFormatException in ...\checkout_failure.json: ...
//     suite.json "detail": "unknown key \"routez\". Known: name, ..."
//
// So the operator was told which of the three to fix and the gate
// reading the same run was not, and `preflight`, which has no terminal
// line of its own, lost it for everyone - under a remedy that says "Fix
// the scenario file".
//
// The row beside it has always named its file: a mapping that will not
// parse is `home.yaml could not be read: ...`. This is that vocabulary,
// applied to the one condition that had been left out of it.
//
// More than one scenario on disk throughout, deliberately. With a single
// `default.json` every assertion below would also pass for an
// implementation that had guessed.
//
// Offline, and no handset: the fake adb answers what preflight asks, and
// every refusal here happens before anything is launched.
@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

const String _serial = 'FAKESERIAL1';

/// The malformed one, among several that read perfectly well.
const String _broken = 'checkout_failure.json';

const String _flow = 'appId: com.example.x\n'
    'flow: home\n'
    'steps:\n'
    '  - launchApp\n';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

String _scenario(String name) =>
    '{"name": "$name", "routes": {"GET /a": {"status": 200}}}';

/// Three scenarios, of which [broken] is written malformed.
///
/// Named after real states rather than `a` and `b`, because the point is
/// that a reader has to be told which one - and the reason the loader
/// reports is identical whichever file carries it.
void _scenarios({String? broken}) {
  for (final name in const ['default', 'cart_full', 'checkout_failure']) {
    _write(
      'mock_api/scenarios/$name.json',
      '$name.json' == broken
          ? '{"name": "$name", "routez": {}}'
          : _scenario(name),
    );
  }
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

/// The `mock API` row of the result a gate reads.
///
/// From the file rather than the terminal on purpose: the terminal line
/// under `suite run` has always carried the path, and the whole of this
/// milestone is about the copy that outlives the run.
Map<String, Object?> _mockApiCheck() {
  final file = File('${_app.path}/out/suite/suite.json');
  expect(file.existsSync(), isTrue, reason: 'no suite.json was written');

  final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final preflight = json['preflight']! as Map<String, Object?>;
  final checks = (preflight['checks']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .where((check) => check['name'] == 'mock API');

  expect(checks, isNotEmpty, reason: '$json');
  return checks.first;
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('scenario_provenance');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    _write('tests/home.yaml', _flow);
    _write(
      'suites/s.yaml',
      'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
      'device: {profile: p}\nmockApi: {port: 8131}\n'
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

  group('a scenario that will not parse', () {
    test('is named by preflight, out of the several on disk', () async {
      _scenarios(broken: _broken);

      final run = await _preflight();

      expect(run.output, contains(RegExp(r'\[BLOCK\]\s+mock API')),
          reason: run.output);
      expect(run.output, contains(_broken), reason: run.output);
      // The reason is still there. Naming the file instead of saying
      // what is wrong with it would have traded one gap for another.
      expect(run.output, contains('routez'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('and is named in suite.json, which is what a gate reads', () async {
      _scenarios(broken: _broken);

      final run = await _suiteRun();
      final check = _mockApiCheck();

      expect(check['outcome'], 'blocked', reason: run.output);
      expect(check['detail'], contains(_broken), reason: '$check');
      expect(check['detail'], contains('routez'), reason: '$check');
      expect(run.code, 2, reason: run.output);
    });

    test('and the terminal still carries the whole path', () async {
      // Not narrowed to a basename. A report row is one column-aligned
      // line and a terminal is not, so the two are shortened
      // differently - and somebody reading the terminal is standing in
      // a directory the full path helps them find.
      _scenarios(broken: _broken);

      final run = await _suiteRun();

      expect(run.output, contains('mock_api'), reason: run.output);
      expect(run.output, contains('scenarios'), reason: run.output);
      expect(run.output, contains(_broken), reason: run.output);
    });

    test('and nothing was launched to discover it', () async {
      _scenarios(broken: _broken);

      final run = await _suiteRun();

      expect(run.output, isNot(contains('launching app')), reason: run.output);
      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
    });
  });

  group('a scenario the resolver looked for and did not find', () {
    test('is named too, though the file is the missing one', () async {
      // `library.resolve(defaultName)` reaches the same catch. The file
      // it names does not exist, which is precisely the news: the
      // directory has scenarios in it and not the one a suite starts on.
      _scenarios();
      File('${_app.path}/mock_api/scenarios/default.json').deleteSync();

      final run = await _preflight();

      expect(run.output, contains('default.json'), reason: run.output);
      expect(run.output, contains('no such scenario'), reason: run.output);
      expect(run.output, contains(RegExp(r'\[BLOCK\]\s+mock API')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });

  group('what A-2 must not have changed', () {
    test('a project whose scenarios all read is still ok', () async {
      // The control. Without it every assertion above would hold for a
      // check that had simply started blocking.
      _scenarios();

      final run = await _preflight();

      expect(run.output, contains(RegExp(r'\[ok\]\s+mock API')),
          reason: run.output);
      expect(run.output, contains('nothing blocking'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });

    test('a fixture no scenario provides is still named by test and state',
        () async {
      // The other half of `checkMockApi`. This detail already carried
      // its coordinates - the test and the state it asked for - and a
      // file name has no place in it: the scenario it names is the one
      // that is not there.
      _scenarios();
      _write(
        'tests/home.yaml',
        _flow.replaceFirst('steps:', 'fixture: signed_in\nsteps:'),
      );

      final run = await _preflight();

      expect(run.output, contains('home -> signed_in'), reason: run.output);
      expect(run.output, isNot(contains('signed_in.json')), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });
}
