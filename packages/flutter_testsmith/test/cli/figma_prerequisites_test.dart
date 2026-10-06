// F-1: a declared design's prerequisites, asked before the device.
//
// `resolveFigmaSources` reads the token and the node mapping after
// preflight has passed, after the permissions are arranged and after the
// APK is built. Measured on Windows against `be9fca3`, with a suite whose
// one flow reaches /home and a mapping declaring `figmaSource:`:
//
//   FIGMA_TOKEN unset          preflight exit 0, "nothing blocking",
//                              all 12 rows [ok]; then `suite run`
//                              launched the app and spent 480.6s waiting
//                              for it before ERROR
//   node mapping absent        the same
//
// An unset environment variable and a missing file are both readable in
// microseconds, from the project alone. Eight minutes to report one is
// the gap E-04 exists to close.
//
// What makes this narrower than "check every figmaSource in the project"
// is reachability. `resolveFigmaSources` walks every mapping there is,
// which is right for it: it resolves what it can and reports each
// failure. Here the answer *refuses the suite*, so it may only consider
// designs the suite can actually ask for - the nearest preceding
// `expectScreen` naming the screen a `validateScreen` will compare,
// exactly as `_missingBaselines` already decides which screens get
// photographed. Cases C and D below are that distinction.
//
// Local questions only. Whether the token works needs a request, and a
// preflight that made one would be answering a different question - the
// run still reports `Figma rejected the token (HTTP 403)` as it always
// has.
//
// Offline throughout, and no launch: preflight never starts the
// application, and the point of the blocking cases is that nothing gets
// that far.
@Timeout(Duration(minutes: 6))
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

/// A mapping for [screen], declaring a design when [nodeMapping] is given.
void _mapping(String file, String screen, {String? nodeMapping}) {
  _write(
    'mappings/$file.yaml',
    'screen: $screen\n'
    '${nodeMapping == null ? '' : 'figmaSource:\n'
        '  url: "https://www.figma.com/design/ABC123/App?node-id=1-2"\n'
        '  token: env:FIGMA_TOKEN\n'
        '  mapping: $nodeMapping\n'}'
    'mappings:\n  - {target: t.a, source: response.a}\n',
  );
}

/// An adb that answers what preflight asks, and nothing more.
///
/// Cross-platform: a `.bat` alone would make every assertion here
/// Windows-only, and CI is ubuntu.
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

/// [token] empty is how "not set" is expressed to a child process: Dart
/// cannot unset a variable for one, and `EnvSecretResolver.isPresent`
/// treats empty and absent alike. Passing it explicitly also keeps the
/// result the same on a machine whose developer has a real token
/// exported.
Future<Run> _testsmith(List<String> arguments, {String token = ''}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {'MYTEST_ADB': _fakeAdb(), 'FIGMA_TOKEN': token},
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

Future<Run> _preflight({String token = ''}) => _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _serial],
      token: token,
    );

Future<Run> _suiteRun({String token = ''}) => _testsmith(
      ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _serial],
      token: token,
    );

final RegExp _blocked = RegExp(r'\[BLOCK\]\s+figma sources');
final RegExp _satisfied = RegExp(r'\[ok\]\s+figma sources');

/// Nothing was launched and nothing was done to the handset.
void expectNothingLaunched(Run run) {
  expect(run.output, isNot(contains('launching app')), reason: run.output);
  expect(run.output, isNot(contains('waking device')), reason: run.output);
  expect(run.output, isNot(contains('Unhandled exception')),
      reason: run.output);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('figma_prereq');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    // Reaches /home and compares it. `validateScreen` with nothing named
    // runs every dimension, figma included.
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n'
      '  - launchApp\n'
      '  - expectScreen:\n      id: /home\n'
      '  - validateScreen\n',
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

  test('A. a reachable design with no token blocks before the device',
      () async {
    _mapping('home', '/home', nodeMapping: 'figma/home.nodes.yaml');
    _write('figma/home.nodes.yaml', 'screen: /home\nnodes: {}\n');

    final run = await _preflight();

    expect(run.output, contains(_blocked), reason: run.output);
    expect(run.output, contains('FIGMA_TOKEN'), reason: run.output);
    expect(run.code, 2, reason: run.output);
    expectNothingLaunched(run);
  });

  test('B. a reachable design with no node mapping blocks', () async {
    _mapping('home', '/home', nodeMapping: 'figma/absent.nodes.yaml');

    final run = await _preflight(token: 'a-token');

    expect(run.output, contains(_blocked), reason: run.output);
    expect(run.output, contains('figma/absent.nodes.yaml'),
        reason: run.output);
    expect(run.code, 2, reason: run.output);
    expectNothingLaunched(run);
  });

  test('C. a design the suite never reaches, with no token, does not block',
      () async {
    // /other is described, and nothing in this suite goes there.
    _mapping('home', '/home');
    _mapping('other', '/other', nodeMapping: 'figma/other.nodes.yaml');

    final run = await _preflight();

    expect(run.output, isNot(contains(_blocked)), reason: run.output);
    expect(run.output, contains('nothing blocking'), reason: run.output);
    expect(run.code, 0, reason: run.output);
  });

  test('D. a design the suite never reaches, with no node mapping, does not '
      'block', () async {
    _mapping('home', '/home');
    _mapping('other', '/other', nodeMapping: 'figma/absent.nodes.yaml');

    final run = await _preflight(token: 'a-token');

    expect(run.output, isNot(contains(_blocked)), reason: run.output);
    expect(run.output, contains('nothing blocking'), reason: run.output);
    expect(run.code, 0, reason: run.output);
  });

  group('what F-1 must not have changed', () {
    test('a reachable design with both prerequisites is satisfied', () async {
      // The control. Without it every assertion above would also hold for
      // a check that blocked on every project it was given.
      _mapping('home', '/home', nodeMapping: 'figma/home.nodes.yaml');
      _write('figma/home.nodes.yaml', 'screen: /home\nnodes: {}\n');

      final run = await _preflight(token: 'a-token');

      expect(run.output, contains(_satisfied), reason: run.output);
      expect(run.output, contains('nothing blocking'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });

    test('a suite declaring no design at all is satisfied', () async {
      _mapping('home', '/home');

      final run = await _preflight();

      expect(run.output, contains(_satisfied), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });

    test('suite run stops at preflight rather than launching', () async {
      // The eight minutes. Before F-1 this project passed preflight,
      // built the APK and timed out waiting for the application; the
      // prerequisite it was missing was an unset environment variable.
      _mapping('home', '/home', nodeMapping: 'figma/home.nodes.yaml');
      _write('figma/home.nodes.yaml', 'screen: /home\nnodes: {}\n');

      final run = await _suiteRun();

      expect(run.output, contains(_blocked), reason: run.output);
      expect(run.code, 2, reason: run.output);
      expectNothingLaunched(run);
    });
  });
}
