// R3 + R4: a malformed project file is a configuration error, not a crash.
//
// Three call sites reached a parser with no guard, so an ordinary typo in
// a file the operator wrote came back as a Dart stack trace. Measured on
// Windows against 954f2d2:
//
//   testsmith generate     (mappings/home.yaml has an unknown key)
//                          -> Unhandled exception: MappingsFormatException
//                             ... and exit 255
//   testsmith generate     (mock_api/scenarios/broken.json is not JSON)
//                          -> Unhandled exception: ScenarioFormatException
//                             ... and exit 255
//   testsmith auth setup   (device_profiles/p.yaml has an unknown key)
//                          -> Unhandled exception: ProfileFormatException
//                             ... and exit 255
//
// 255 is the part that matters. It is what Dart exits with when a program
// falls over, so it is indistinguishable from a defect in the tool. Every
// one of these is a file somebody has to go and correct, and each command
// already has an exit code that says exactly that: 1 for `generate`, 2 for
// `auth setup`. Neither taxonomy changes here.
//
// Offline throughout, and no device: all three failures happen before the
// command reaches a handset or an endpoint. The controls at the end are
// what prove that - a sound project still gets all the way to its
// AI-credential gate, and to its device stage.
@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

typedef Run = ({String output, int code});

Future<Run> _testsmith(
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: environment,
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

/// Everything a malformed project file must never produce.
///
/// The exit code is asserted against the command's own error code rather
/// than merely "not 255", because "not 255" would also accept a command
/// that invented a third meaning for the failure.
void expectConfigurationError(
  Run run, {
  required int code,
  required String names,
}) {
  expect(run.output, isNot(contains('Unhandled exception')), reason: run.output);
  expect(run.output, isNot(contains('#0 ')), reason: run.output);
  expect(run.output, isNot(contains('asynchronous suspension')),
      reason: run.output);
  expect(run.code, isNot(255), reason: run.output);
  expect(run.code, code, reason: run.output);
  expect(run.output, contains(names), reason: run.output);
}

/// A project `generate` can read end to end.
///
/// `ai.yaml` names a variable nothing sets, which is what keeps the
/// control offline: the command reaches its credential gate and stops
/// there, having proved it got past every file this milestone is about.
void _soundGenerateProject() {
  _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
  _write('lib/main.dart', 'void main() {}\n');
  _write(
    'tests/home.yaml',
    'appId: com.example.x\nflow: home\nsteps:\n'
    '  - launchApp\n'
    '  - expectScreen:\n      id: /home\n',
  );
  _write(
    'mappings/home.yaml',
    'screen: /home\napi: GET /home\n'
    'mappings:\n  - {target: home.title, source: response.title}\n',
  );
  _write(
    'mock_api/scenarios/default.json',
    '{"name":"default","routes":{"GET /home":{"status":200,'
    '"body":{"title":"Home"}}}}',
  );
  _write('ai.yaml', 'apiKeyEnv: MYTEST_FIXTURE_ABSENT_KEY\n');
}

/// An auth file and the project it points at, sound but for whatever a
/// test then breaks.
///
/// The secret is declared because the presence check runs before the
/// device profile is read; `MYTEST_AUTH_PIN` is set in the environment of
/// every run below so that check is never the thing that stops it.
void _soundAuthProject() {
  _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
  _write('lib/main_uat.dart', 'void main() {}\n');
  _write(
    'auth/login.yaml',
    'auth: t\n'
    'app: {path: .., target: lib/main_uat.dart}\n'
    'appId: com.example.x\n'
    'device:\n  profile: p\n'
    'secrets: {pin: env:MYTEST_AUTH_PIN}\n'
    'signedOutOn: [/login]\n'
    'login:\n  - tap: {id: login.submit}\n'
    'verify: {route: /home, element: home.body}\n',
  );
}

/// The environment every `auth setup` run below uses.
///
/// The declared secret, and a PATH holding the Dart SDK and nothing else -
/// the isolation `external_tool_unavailability_test.dart` uses, for the
/// same reason. Dart is launched by absolute path, so this removes adb
/// without removing the ability to run the CLI, and the device stage is
/// reached with the same answer whether or not the host running these
/// tests happens to have a handset plugged in. The two Android variables
/// are emptied rather than removed because Dart cannot unset one for a
/// child, and `resolveAdb` treats an empty value as unset.
///
/// Since D that answer is "adb could not be found" rather than "none
/// attached": with nothing to resolve, nothing was asked.
Map<String, String> get _authEnvironment => {
      'MYTEST_AUTH_PIN': '0000',
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    };

/// The flow text these tests re-encode.
///
/// Identical to the one `_soundGenerateProject` writes; held separately
/// so the bytes on disk are the only thing that varies below.
const String _flowText = 'appId: com.example.x\nflow: home\nsteps:\n'
    '  - launchApp\n'
    '  - expectScreen:\n      id: /home\n';

void _writeBytes(String relative, List<int> bytes) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

/// [text] as UTF-16 LE with a byte-order mark.
///
/// Not an exotic corruption. This is what Notepad writes as "Unicode"
/// and what Windows PowerShell's `Out-File` and `>` write by default, so
/// an ordinary editing session on this platform produces one without
/// anybody choosing an encoding.
///
/// The mark is what makes it fail: `FF FE` is not valid UTF-8, so
/// `readAsString` refuses the file outright. The same content *without*
/// a mark decodes to nonsense that the parser then rejects cleanly,
/// which is why the control below is not simply "UTF-16".
List<int> _utf16leWithBom(String text) => [
      0xFF,
      0xFE,
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];

/// [text] as UTF-8 with a byte-order mark, which Dart strips on read.
List<int> _utf8WithBom(String text) =>
    [0xEF, 0xBB, 0xBF, ...utf8.encode(text)];

/// A project `run`, `preflight` and `suite run` can all read.
///
/// `_soundGenerateProject` already writes the flow and the mapping; the
/// suite and the profile are what the other two commands need to reach
/// that same flow through their own readers.
void _soundRunProject() {
  _soundGenerateProject();
  _write('tests/home.yaml', _flowText);
  _write('lib/main_mytest.dart', 'void main() {}\n');
  _write(
    'suites/s.yaml',
    'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
    'device: {profile: p}\n'
    'tests:\n  - {id: home, flow: tests/home.yaml}\n',
  );
  _write(
    'device_profiles/p.yaml',
    'id: p\nmodel: Fake\nos: Android 13\n'
    'physical:\n  width: 720\n  height: 1600\n'
    'devicePixelRatio: 1.875\norientation: portrait\nbuildMode: debug\n',
  );
}

/// The isolation `_authEnvironment` uses, without the auth secret.
///
/// Everything asserted below happens before a device is looked for, so a
/// handset plugged into the machine running these must not change the
/// answer.
Map<String, String> get _offlineEnvironment => {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    };

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('config_errors');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('generate, on a malformed mapping', () {
    setUp(() {
      _soundGenerateProject();
      _write(
        'mappings/home.yaml',
        'screne: /home\nmappings:\n  - {target: a, source: response.a}\n',
      );
    });

    test('reports the file and exits 1', () async {
      final run = await _testsmith(['generate', '--app', _app.path]);
      expectConfigurationError(run, code: 1, names: 'MappingsFormatException');
      expect(run.output, contains('home.yaml'), reason: run.output);
    });
  });

  group('generate, on a malformed scenario', () {
    setUp(() {
      _soundGenerateProject();
      _write('mock_api/scenarios/broken.json', '{ this is not json');
    });

    test('reports the file and exits 1', () async {
      final run = await _testsmith(['generate', '--app', _app.path]);
      expectConfigurationError(run, code: 1, names: 'ScenarioFormatException');
      expect(run.output, contains('broken.json'), reason: run.output);
    });
  });

  group('auth setup, on a malformed device profile', () {
    setUp(() {
      _soundAuthProject();
      _write('device_profiles/p.yaml', 'id: p\nmodle: FakePhone\n');
    });

    test('reports the file and exits 2', () async {
      final run = await _testsmith(
        ['auth', 'setup', '${_app.path}/auth/login.yaml'],
        environment: _authEnvironment,
      );
      expectConfigurationError(run, code: 2, names: 'ProfileFormatException');
      expect(run.output, contains('p.yaml'), reason: run.output);
    });
  });

  group('what the guards must not have changed', () {
    test('a sound project still reaches the AI-credential gate', () async {
      _soundGenerateProject();
      final run = await _testsmith(['generate', '--app', _app.path]);

      expect(run.output, contains('MYTEST_FIXTURE_ABSENT_KEY'),
          reason: run.output);
      expect(run.output, isNot(contains('FormatException')), reason: run.output);
      expect(run.code, 1, reason: run.output);
    });

    test('a sound auth project still reaches the device stage', () async {
      _soundAuthProject();
      _write('device_profiles/p.yaml', 'id: p\nmodel: FakePhone\n');

      final run = await _testsmith(
        ['auth', 'setup', '${_app.path}/auth/login.yaml'],
        environment: _authEnvironment,
      );

      // The point of the control is that the profile was read and the
      // run moved on to the device. What it then says about the device
      // changed with D: with no adb reachable, the answer is why it
      // could not be asked, not a claim about what is plugged in.
      expect(run.output, contains('adb could not be found'),
          reason: run.output);
      // And specifically not the other sentence. "No usable device
      // attached" is adb answering that nothing is there, which is a
      // successful query; keeping the two apart is what D is for.
      expect(run.output, isNot(contains('No usable device attached')),
          reason: run.output);
      expect(run.output, isNot(contains('ProfileFormatException')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('generate still tolerates a missing scenario directory', () async {
      _soundGenerateProject();
      Directory('${_app.path}/mock_api').deleteSync(recursive: true);

      final run = await _testsmith(['generate', '--app', _app.path]);

      expect(run.output, contains('MYTEST_FIXTURE_ABSENT_KEY'),
          reason: run.output);
      expect(run.output, isNot(contains('ScenarioFormatException')),
          reason: run.output);
      expect(run.code, 1, reason: run.output);
    });
  });

  // A flow that is valid text in the wrong encoding.
  //
  // `readAsString` decodes as UTF-8 and reports a failure to do so as
  // `FileSystemException` - which is not a `FormatException`, so not the
  // `FlowFormatException` this command guards, and not caught anywhere
  // above it either.
  //
  // Three places read a flow and only this one fell over.
  // `preflight_runner._readFlows` catches everything else reading the
  // file - "a permission, an encoding", says its comment - and
  // `declaredAppId` skips it. Measured at 58f32c3: exit 255, an
  // unhandled exception, five frames, and this tool's own install path
  // in the trace while the project's file was named nowhere a reader
  // would look.
  //
  // The sharpest form of it is preflight's own remedy line, which reads
  // "Fix the flow. Run it on its own to see the parse error in full:
  // testsmith run <flow>." - naming the one command that could not.
  group('run, on a flow it cannot decode', () {
    setUp(() {
      _soundRunProject();
      _writeBytes('tests/home.yaml', _utf16leWithBom(_flowText));
    });

    test('reports the file and exits 2', () async {
      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'home.yaml');
      // The trace carried this tool's install path and not a word about
      // the project file; the report must do the opposite.
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('while preflight reports it, as it already did', () async {
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, contains('home.yaml'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('and so does suite run', () async {
      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, contains('home.yaml'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });

  group('what the flow-read guard must not have changed', () {
    test('a readable flow still reaches the device stage', () async {
      // The control that matters most: the guard must catch a file that
      // cannot be read, not every flow.
      _soundRunProject();

      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, contains('adb'), reason: run.output);
      // The device stage, which since RUN-ENV-EXIT is exit 2.
      expect(run.code, 2, reason: run.output);
    });

    test('a byte-order mark on a UTF-8 flow is still read', () async {
      // Dart strips this one, and must keep doing so: an editor that
      // writes a UTF-8 mark has corrupted nothing, and refusing it would
      // turn a working project into a broken one.
      _soundRunProject();
      _writeBytes('tests/home.yaml', _utf8WithBom(_flowText));

      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, contains('adb'), reason: run.output);
      // The device stage, which since RUN-ENV-EXIT is exit 2.
      expect(run.code, 2, reason: run.output);
    });

    test('a flow that decodes but will not parse still says why', () async {
      // The guard beside the new one. A `FlowFormatException` must keep
      // its own sentence rather than being absorbed into "cannot read":
      // a typo and an encoding are different things to go and fix.
      _soundRunProject();
      _write(
        'tests/home.yaml',
        'appId: 5\nflow: home\nsteps:\n  - launchApp\n',
      );

      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'home.yaml');
      expect(run.output, contains('"appId" is required'), reason: run.output);
    });
  });

  // A project configuration file that is valid text in the wrong
  // encoding.
  //
  // `readAsString` decodes as well as reads and reports a failure to
  // decode as a `FileSystemException`. That is not a `FormatException`,
  // so it is neither the `MappingsFormatException` nor the
  // `ProfileFormatException` every caller of these loaders already
  // renders, and nothing above them catches it. Measured at 2905ede on
  // a UTF-16 file with a byte-order mark - what Notepad writes as
  // "Unicode" and what PowerShell redirection writes by default: exit
  // 255, an unhandled exception, six to eight frames, and this tool's
  // install path in the trace while the project's file was named
  // nowhere.
  //
  // Three loaders in one file, and three contracts that stay exactly as
  // they are: a mapping is fatal, a profile is fatal, a design is
  // advisory and skipped.
  group('a mapping the loader cannot decode', () {
    setUp(() {
      _soundRunProject();
      _writeBytes('mappings/home.yaml', _utf16leWithBom('screen: /home\n'));
    });

    test('run reports the file and exits 2', () async {
      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'home.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('preflight reports the file and exits 2', () async {
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'home.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('suite run reports the file and exits 2', () async {
      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'home.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('generate reports the file and exits 1', () async {
      final run = await _testsmith(
        ['generate', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 1, names: 'home.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });
  });

  group('a device profile the loader cannot decode', () {
    test('preflight reports the file and exits 2', () async {
      _soundRunProject();
      _writeBytes('device_profiles/p.yaml', _utf16leWithBom('id: p\n'));

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'p.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('suite run reports the file and exits 2', () async {
      _soundRunProject();
      _writeBytes('device_profiles/p.yaml', _utf16leWithBom('id: p\n'));

      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'p.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('auth setup reports the file and exits 2', () async {
      // The third caller of this loader, and the one no other decode
      // case in this file reaches.
      _soundAuthProject();
      _writeBytes('device_profiles/p.yaml', _utf16leWithBom('id: p\n'));

      final run = await _testsmith(
        ['auth', 'setup', '${_app.path}/auth/login.yaml'],
        environment: _authEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'p.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });
  });

  group('a design the loader cannot decode', () {
    // The third contract, and the one that must not become fatal. A
    // design that cannot be read describes no screen, so it takes
    // nothing away from another: reported through `onProblem` and
    // skipped, exactly as a design that will not parse already is.
    setUp(() {
      _soundRunProject();
      _writeBytes('figma/home.json', _utf16leWithBom('{"screen":"/home"}'));
    });

    test('run reports it and carries on to the device stage', () async {
      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, isNot(contains('#0 ')), reason: run.output);
      expect(run.output, isNot(contains('file:///')), reason: run.output);
      expect(run.output, contains('ignoring'), reason: run.output);
      expect(run.output, contains('home.json'), reason: run.output);
      // Advisory, so the run ends where a sound project ends: at the
      // device it cannot find, not at the design - which since
      // RUN-ENV-EXIT is exit 2.
      expect(run.output, contains('adb'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('preflight notes it and still reaches a verdict', () async {
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, isNot(contains('file:///')), reason: run.output);
      expect(run.output, contains('home.json'), reason: run.output);
      // The severity that must not move: a design nobody can read is a
      // notice, never a block.
      expect(run.output, contains(RegExp(r'\[note\]\s+screen configuration')),
          reason: run.output);
      expect(run.output, isNot(contains(RegExp(r'\[BLOCK\]\s+screen config'))),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('suite run notes it and still reaches a verdict', () async {
      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, isNot(contains('file:///')), reason: run.output);
      expect(run.output, contains('home.json'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });

  group('what the loader guards must not have changed', () {
    test('a readable mapping still gets the run to the device stage',
        () async {
      _soundRunProject();

      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('MappingsFormatException')),
          reason: run.output);
      expect(run.output, contains('adb'), reason: run.output);
      // The device stage, which since RUN-ENV-EXIT is exit 2.
      expect(run.code, 2, reason: run.output);
    });

    test('a readable design is read and nothing is reported', () async {
      // The control for the advisory group above. Without it those
      // three would also hold for a loader that had quietly stopped
      // reading the directory at all.
      _soundRunProject();
      _write(
        'figma/home.json',
        '{"screen":"/home","nodeId":"1:1","figmaName":"Home","width":400.0,'
        '"height":800.0,"elements":[],"totalNodesWalked":1}',
      );

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('ignoring')), reason: run.output);
      expect(run.output, contains(RegExp(r'\[ok\]\s+screen configuration')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a design that decodes but is not a spec is still advisory',
        () async {
      // The guard beside the new one: a file that reads perfectly well
      // and is not a design must keep its own sentence and its own
      // severity.
      _soundRunProject();
      _write('figma/home.json', '{"a": 1}');

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, contains('home.json'), reason: run.output);
      expect(run.output, contains(RegExp(r'\[note\]\s+screen configuration')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a byte-order mark on a UTF-8 mapping is still read', () async {
      // Dart strips this one, and must keep doing so.
      _soundRunProject();
      _writeBytes(
        'mappings/home.yaml',
        _utf8WithBom(
          'screen: /home\napi: GET /home\n'
          'mappings:\n  - {target: home.title, source: response.title}\n',
        ),
      );

      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('MappingsFormatException')),
          reason: run.output);
      expect(run.output, contains('adb'), reason: run.output);
      // The device stage, which since RUN-ENV-EXIT is exit 2.
      expect(run.code, 2, reason: run.output);
    });
  });

  // The suite file itself, in the wrong encoding.
  //
  // The last of the four readers `preflight` and `suite run` share, and
  // the same shape as the three in `project_config.dart`:
  // `readAsString` reports a failure to decode as a
  // `FileSystemException`, which is not the `SuiteFormatException` this
  // function catches and is caught nowhere above it. Measured at
  // a201c6b: exit 255, an unhandled exception, six frames, and this
  // tool's install path in the trace while the suite was named nowhere.
  //
  // Command-blocking rather than fatal-to-a-run or advisory: a suite
  // nobody can read names no tests, so there is nothing to report a
  // verdict about. That is what `return null` already means here.
  group('a suite file that cannot be decoded', () {
    setUp(() {
      _soundRunProject();
      _writeBytes('suites/s.yaml', _utf16leWithBom('suite: s\n'));
    });

    test('preflight names it and exits 2', () async {
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 's.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
      // The contract it must enter, not a second one beside it.
      expect(run.output, contains('SuiteFormatException'), reason: run.output);
    });

    test('suite run names it and exits 2', () async {
      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 's.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
      expect(run.output, contains('SuiteFormatException'), reason: run.output);
    });

    test('and no other command is drawn into it', () async {
      // The boundary is the suite file, which `run` does not read. It
      // must still stop where a sound project stops it.
      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, isNot(contains('SuiteFormatException')),
          reason: run.output);
      expect(run.output, contains('adb'), reason: run.output);
      // The device stage, which since RUN-ENV-EXIT is exit 2.
      expect(run.code, 2, reason: run.output);
    });
  });

  group('what the suite-read guard must not have changed', () {
    test('a readable suite still reaches the preflight verdict', () async {
      _soundRunProject();

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('SuiteFormatException')),
          reason: run.output);
      expect(run.output, contains('preflight'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a suite that decodes but will not parse still says why', () async {
      // The guard beside the new one. A file that reads perfectly well
      // and is not a suite must keep its own sentence.
      _soundRunProject();
      _write('suites/s.yaml', 'suite: s\nteests:\n  - {id: home}\n');

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'SuiteFormatException');
      expect(run.output, contains('s.yaml'), reason: run.output);
    });

    test('a suite file that is not there is still its own sentence',
        () async {
      // The other refusal in this function, which must not be absorbed
      // into "cannot be read": a missing file and an unreadable one are
      // different things to go and do.
      _soundRunProject();

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/nosuch.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, contains('No such suite file'), reason: run.output);
      expect(run.output, isNot(contains('SuiteFormatException')),
          reason: run.output);
    });

    test('a byte-order mark on a UTF-8 suite is still read', () async {
      // Dart strips this one, and must keep doing so.
      _soundRunProject();
      _writeBytes(
        'suites/s.yaml',
        _utf8WithBom(
          'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
          'device: {profile: p}\n'
          'tests:\n  - {id: home, flow: tests/home.yaml}\n',
        ),
      );

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('SuiteFormatException')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });

  // A mock API scenario in the wrong encoding.
  //
  // `ScenarioLibrary.load` reads every file in `mock_api/scenarios`
  // before parsing it, and `readAsStringSync` reports a failure to
  // decode as a `FileSystemException` - not the `ScenarioFormatException`
  // this library raises for everything else it cannot use. Measured at
  // 0c27e4f: `preflight` and `generate` exited 255 on it, while an
  // invalid-JSON scenario in the same place was reported and survived.
  //
  // `suite run` already survived both, because its guard catches
  // anything; what it could not do was say *which* kind of problem it
  // was, so an encoding arrived in the suite.json row as a raw
  // `FileSystemException` rather than as a scenario problem.
  group('a scenario file that cannot be decoded', () {
    setUp(() {
      _soundRunProject();
      _write(
        'suites/s.yaml',
        'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
        'device: {profile: p}\nmockApi: {port: 8551}\n'
        'tests:\n  - {id: home, flow: tests/home.yaml}\n',
      );
      _writeBytes(
        'mock_api/scenarios/default.json',
        _utf16leWithBom('{"name":"default","routes":{}}'),
      );
    });

    test('preflight names it and exits 2', () async {
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 2, names: 'default.json');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('generate names it and exits 1', () async {
      final run = await _testsmith(
        ['generate', '--app', _app.path],
        environment: _offlineEnvironment,
      );

      expectConfigurationError(run, code: 1, names: 'default.json');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('suite run reports it as a scenario problem, not a raw error',
        () async {
      // Its guard caught this already. What changes is which of the two
      // branches at the blocked-suite row is taken: restated, the
      // encoding is a scenario problem like any other, rather than a
      // `FileSystemException` printed verbatim with the path in it.
      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, isNot(contains('FileSystemException')),
          reason: run.output);
      expect(run.output, contains('default.json'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });

  group('what the scenario-read guard must not have changed', () {
    setUp(() {
      _soundRunProject();
      _write(
        'suites/s.yaml',
        'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
        'device: {profile: p}\nmockApi: {port: 8551}\n'
        'tests:\n  - {id: home, flow: tests/home.yaml}\n',
      );
    });

    test('a readable scenario still gets preflight to its verdict',
        () async {
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('ScenarioFormatException')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a scenario that decodes but is not JSON is still reported',
        () async {
      // The guard beside the new one, through the command that already
      // survived it: a file that reads perfectly well and is not JSON
      // must keep its own sentence.
      _write('mock_api/scenarios/default.json', '{ this is not json');

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, contains('default.json'), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a byte-order mark on a UTF-8 scenario is still read', () async {
      // Dart strips this one, and must keep doing so.
      _writeBytes(
        'mock_api/scenarios/default.json',
        _utf8WithBom(
          '{"name":"default","routes":{"GET /home":{"status":200,'
          '"body":{"title":"Home"}}}}',
        ),
      );

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offlineEnvironment,
      );

      expect(run.output, isNot(contains('ScenarioFormatException')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('run --mock-api meets it the way it meets any unreadable scenario',
        () async {
      // When this was written `run` called `ScenarioLibrary.load`
      // outside the guard that catches `ScenarioFormatException`, so
      // this and an invalid-JSON scenario both ended it at 255, and the
      // test pinned only the contract entered. RUN-MOCK-API moved the
      // load inside that guard; `run_mock_api_scenario_test.dart` holds
      // the full case. The exit code is now asserted here too.
      _writeBytes(
        'mock_api/scenarios/default.json',
        _utf16leWithBom('{"name":"default","routes":{}}'),
      );

      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path,
          '--mock-api', '8551'],
        environment: _offlineEnvironment,
      );

      expect(run.output, contains('ScenarioFormatException'),
          reason: run.output);
      expect(run.output, isNot(contains('FileSystemException')),
          reason: run.output);
      expect(run.output, contains('default.json'), reason: run.output);
      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });

  // `ai.yaml` in the wrong encoding.
  //
  // `_client` reads it with `readAsStringSync`, which decodes as well as
  // reads and reports a failure to decode as a `FileSystemException` -
  // not the `FormatException` `LlmConfig.parse` raises and the clause
  // around this call already catches. Measured at 13bd428: exit 255 on
  // a file the command was about to describe.
  group('an ai.yaml that cannot be decoded', () {
    setUp(() {
      _soundGenerateProject();
      _writeBytes('ai.yaml', _utf16leWithBom('apiKeyEnv: SOMETHING\n'));
    });

    test('generate names it and exits 1', () async {
      final run = await _testsmith(['generate', '--app', _app.path]);

      expectConfigurationError(run, code: 1, names: 'ai.yaml');
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });
  });

  // `_appIdFrom` reads `tests/` itself and returns the first flow it can
  // parse. Two things followed from that, both measured at 13bd428.
  //
  // A flow it cannot decode raised a `FileSystemException` where a
  // malformed one is skipped, so `generate` ended at 255 - but only when
  // that file came back from `listSync` *before* a readable one. Named
  // to sort after, the same project finished. `Directory.listSync` order
  // is unspecified by dart:io, so the answer was a property of the
  // filesystem rather than of the project, which is the defect R9
  // removed from this command's mapping choice.
  //
  // The gate below is R9's: `ai.yaml` names a variable nothing sets, so
  // a run that reaches it has proved it got all the way through
  // gathering its evidence.
  group('a test flow generate cannot decode', () {
    test('is skipped when it sorts before a readable flow', () async {
      _soundGenerateProject();
      _writeBytes('tests/aaa_broken.yaml', _utf16leWithBom(_flowText));

      final run = await _testsmith(['generate', '--app', _app.path]);

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, isNot(contains('#0 ')), reason: run.output);
      expect(run.output, isNot(contains('file:///')), reason: run.output);
      expect(run.output, contains('MYTEST_FIXTURE_ABSENT_KEY'),
          reason: run.output);
      expect(run.code, 1, reason: run.output);
    });

    test('and when it sorts after one', () async {
      _soundGenerateProject();
      _writeBytes('tests/zzz_broken.yaml', _utf16leWithBom(_flowText));

      final run = await _testsmith(['generate', '--app', _app.path]);

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.output, contains('MYTEST_FIXTURE_ABSENT_KEY'),
          reason: run.output);
      expect(run.code, 1, reason: run.output);
    });
  });

  group('what generate answers does not depend on a filename', () {
    // R9's shape, for the flow choice rather than the mapping choice:
    // the same project content under two names must give the same
    // answer. Asserted by comparing two runs rather than by reading the
    // chosen appId, which never reaches the output - the command stops
    // at the credential gate, which is exactly what proves it got past
    // the choice.
    Future<Run> withBrokenNamed(String name) async {
      _soundGenerateProject();
      _writeBytes('tests/$name', _utf16leWithBom(_flowText));
      return _testsmith(['generate', '--app', _app.path]);
    }

    test('an undecodable flow gives the same answer either way', () async {
      final first = await withBrokenNamed('aaa_broken.yaml');
      final second = await withBrokenNamed('zzz_broken.yaml');

      expect(first.code, second.code,
          reason: '${first.output}\n---\n${second.output}');
      expect(
        first.output.contains('MYTEST_FIXTURE_ABSENT_KEY'),
        second.output.contains('MYTEST_FIXTURE_ABSENT_KEY'),
        reason: '${first.output}\n---\n${second.output}',
      );
      expect(first.output.contains('Unhandled exception'), isFalse,
          reason: first.output);
      expect(second.output.contains('Unhandled exception'), isFalse,
          reason: second.output);
    });

    test('a malformed but decodable flow gives the same answer either way',
        () async {
      // The policy that must not move: `_appIdFrom` already skips a flow
      // it cannot parse, and an undecodable one now joins it rather
      // than acquiring a severity of its own.
      Future<Run> withMalformedNamed(String name) async {
        _soundGenerateProject();
        _write('tests/$name', 'appId: 5\nflow: x\nsteps:\n  - launchApp\n');
        return _testsmith(['generate', '--app', _app.path]);
      }

      final first = await withMalformedNamed('aaa_bad.yaml');
      final second = await withMalformedNamed('zzz_bad.yaml');

      expect(first.code, second.code,
          reason: '${first.output}\n---\n${second.output}');
      expect(
        first.output.contains('MYTEST_FIXTURE_ABSENT_KEY'),
        second.output.contains('MYTEST_FIXTURE_ABSENT_KEY'),
        reason: '${first.output}\n---\n${second.output}',
      );
    });

    test('two readable flows give the same answer either way', () async {
      Future<Run> withSecondNamed(String name) async {
        _soundGenerateProject();
        _write(
          'tests/$name',
          'appId: com.example.other\nflow: other\nsteps:\n  - launchApp\n',
        );
        return _testsmith(['generate', '--app', _app.path]);
      }

      final first = await withSecondNamed('aaa_other.yaml');
      final second = await withSecondNamed('zzz_other.yaml');

      expect(first.code, second.code,
          reason: '${first.output}\n---\n${second.output}');
      expect(
        first.output.contains('MYTEST_FIXTURE_ABSENT_KEY'),
        second.output.contains('MYTEST_FIXTURE_ABSENT_KEY'),
        reason: '${first.output}\n---\n${second.output}',
      );
    });

    test('a project whose only flow cannot be decoded still finishes',
        () async {
      // `_appIdFrom` has always had an answer for a directory with
      // nothing usable in it, and that answer must still be reached
      // rather than thrown past.
      _soundGenerateProject();
      _writeBytes('tests/home.yaml', _utf16leWithBom(_flowText));

      final run = await _testsmith(['generate', '--app', _app.path]);

      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
      expect(run.code, 1, reason: run.output);
    });

    test('one readable flow still reaches the gate', () async {
      // The control. Without it every comparison above would also hold
      // for a command that had stopped reading `tests/` at all.
      _soundGenerateProject();

      final run = await _testsmith(['generate', '--app', _app.path]);

      expect(run.output, contains('MYTEST_FIXTURE_ABSENT_KEY'),
          reason: run.output);
      expect(run.code, 1, reason: run.output);
    });
  });
}
