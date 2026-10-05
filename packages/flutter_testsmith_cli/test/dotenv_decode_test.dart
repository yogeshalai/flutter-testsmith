// DOTENV-DECODE: a `.env` that exists but cannot be decoded.
//
// `DotEnv.load` read the first `.env` it found with `readAsStringSync`,
// which decodes as well as reads and reports a failure to decode as a
// `FileSystemException`. Nothing between it and `bin/testsmith.dart`
// caught one. Measured at 39073eb on Windows, with a UTF-16 LE `.env`
// (what Notepad and PowerShell's `>` write) beside the application:
//
//   generate, preflight, suite run, auth setup, figma pull, run
//     -> Unhandled exception: FileSystemException: Failed to decode ...
//        and exit 255, with this tool's install path in the trace
//
// Skipping the file was not the answer. `.env` is optional, and a
// missing one is silent - but a file that is *there* is one the operator
// wrote, usually to hold a credential. Treating it as absent would turn
// "your .env could not be read" into "FIGMA_TOKEN is not set", or would
// quietly fall through to a `.env` in the working directory holding a
// different value. So the two stay distinct: absent is still nothing,
// present-but-undecodable is a `FormatException` naming the file.
//
// `FormatException` because it is the channel a caller already had.
// `generate` wraps the call that loads `.env` in `on FormatException`
// and renders it at exit 1 - the same restatement GENERATE-DECODE made
// for `ai.yaml` two lines above it. The other callers had no guard of
// any kind around `DotEnv.load`; measured with only the restatement in
// place, each still exited 255, now with a FormatException naming the
// file. Each now catches it into the exit code it already gives a file
// the operator has to correct: 2 for `preflight`, `suite run`, `auth
// setup` and - since RUN-CONFIG-EXIT - `run`, 1 for `figma pull`.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/dotenv.dart';

/// A value that must never appear in any output, message or report.
const String _secret = 'DOTENV_DECODE_SENTINEL_VALUE';

/// A representative `.env`: two credentials and a comment.
///
/// The AI key is deliberately not among them. `generate` would otherwise
/// reach a real endpoint with it on the control runs below.
const String _envText = '# local credentials\n'
    'MYTEST_AUTH_PIN=$_secret\n'
    'FIGMA_TOKEN=$_secret\n';

/// [text] as UTF-16 LE with a byte-order mark: `FF FE` is not valid
/// UTF-8, so `readAsString` refuses the file outright.
List<int> _utf16leWithBom(String text) => [
      0xFF,
      0xFE,
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];

late Directory _root;
late Directory _app;

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

void _writeUndecodableEnv(Directory directory) =>
    File('${directory.path}/.env').writeAsBytesSync(_utf16leWithBom(_envText));

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _testsmith(
  List<String> arguments, {
  required Map<String, String> environment,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: environment,
    // Not the application, so the only `.env` in play is the one the
    // test put beside it.
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}';

/// Nothing from the file's contents, on either stream.
void _expectNoSecret(Run run) {
  expect(run.stdout, isNot(contains(_secret)), reason: _both(run));
  expect(run.stderr, isNot(contains(_secret)), reason: _both(run));
}

/// A PATH holding the Dart SDK and nothing else, and no adb.
///
/// The isolation `project_configuration_errors_test.dart` uses: Dart is
/// launched by absolute path, so this removes flutter and adb without
/// removing the ability to run the CLI, and a handset plugged into the
/// host cannot change an answer.
Map<String, String> get _offline => {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    };

const String _serial = 'FAKESERIAL1';

/// Any well-formed design URL. Nothing below gets far enough to fetch it.
const String _figmaUrl = 'https://www.figma.com/design/ABC123/x?node-id=1-2';

/// An adb that reports one attached device, so `run` passes its device
/// gate - the one it checks before loading `.env` - without hardware.
String _fakeAdb() {
  final directory = Directory('${_root.path}/fake_adb')..createSync();
  if (Platform.isWindows) {
    return (File('${directory.path}/adb.bat')
          ..writeAsStringSync(
            '@echo off\r\n'
            'echo List of devices attached\r\n'
            'echo $_serial            device product:fake model:Fake device:fake\r\n',
          ))
        .path;
  }
  final file = File('${directory.path}/adb')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'echo "List of devices attached"\n'
      'echo "$_serial            device product:fake model:Fake device:fake"\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// One project every caller of `DotEnv.load` can reach it through.
///
/// `ai.yaml` names a variable nothing sets, so `generate` stops at its
/// credential gate and never reaches an endpoint.
void _soundProject() {
  _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
  _write('lib/main.dart', 'void main() {}\n');
  _write('lib/main_mytest.dart', 'void main() {}\n');
  _write('lib/main_uat.dart', 'void main() {}\n');
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

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('dotenv_decode');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('DotEnv.load', () {
    late Directory other;

    setUp(() {
      other = Directory('${_root.path}/other')..createSync();
    });

    test('an absent .env is still nothing, and says nothing', () {
      final env = DotEnv.load([_app.path, other.path]);

      expect(env.isEmpty, isTrue);
    });

    test('a valid .env is still read', () {
      File('${_app.path}/.env').writeAsStringSync(_envText);

      final env = DotEnv.load([_app.path, other.path]);

      expect(env.names, ['FIGMA_TOKEN', 'MYTEST_AUTH_PIN']);
      expect(env['FIGMA_TOKEN'], _secret);
    });

    test('a .env that decodes but is not KEY=VALUE is still lenient', () {
      File('${_app.path}/.env')
          .writeAsStringSync('this is not dotenv\n=orphan\nA=1\n');

      expect(DotEnv.load([_app.path, other.path]).names, ['A']);
    });

    test('an undecodable .env is a FormatException naming the file', () {
      _writeUndecodableEnv(_app);

      expect(
        () => DotEnv.load([_app.path, other.path]),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message',
                  contains('${_app.path}/.env'))
              .having((e) => e.message, 'message', isNot(contains(_secret))),
        ),
      );
    });

    test('and it is not treated as absent', () {
      // The case skipping would have got wrong: an unreadable project
      // `.env` falling through to a readable one elsewhere, and a
      // credential the operator never meant for this project being used.
      _writeUndecodableEnv(_app);
      File('${other.path}/.env').writeAsStringSync('FIGMA_TOKEN=elsewhere\n');

      expect(
        () => DotEnv.load([_app.path, other.path]),
        throwsA(isA<FormatException>()),
      );
    });

    test('discovery order is unchanged: a later file is never opened', () {
      File('${_app.path}/.env').writeAsStringSync('A=1\n');
      _writeUndecodableEnv(other);

      expect(DotEnv.load([_app.path, other.path])['A'], '1');
    });
  });

  group('what the guard must not have changed', () {
    setUp(_soundProject);

    test('generate with no .env still reaches its credential gate', () async {
      final run = await _testsmith(
        ['generate', '--app', _app.path],
        environment: _offline,
      );

      expect(run.stdout, contains('MYTEST_FIXTURE_ABSENT_KEY'),
          reason: _both(run));
      expect(run.stdout, isNot(contains('.env:')), reason: _both(run));
      expect(run.code, 1, reason: _both(run));
    });

    test('generate with a malformed .env still reaches it too', () async {
      _write('.env', 'this is not dotenv\n=orphan\n');

      final run = await _testsmith(
        ['generate', '--app', _app.path],
        environment: _offline,
      );

      expect(run.stdout, contains('MYTEST_FIXTURE_ABSENT_KEY'),
          reason: _both(run));
      expect(run.code, 1, reason: _both(run));
    });

    test('auth setup with no .env still reports the missing credential',
        () async {
      final run = await _testsmith(
        ['auth', 'setup', '${_app.path}/auth/login.yaml'],
        environment: _offline,
      );

      expect(run.stdout, contains('env:MYTEST_AUTH_PIN is not set'),
          reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });

    test('auth setup with a valid .env still takes the credential from it',
        () async {
      _write('.env', _envText);

      final run = await _testsmith(
        ['auth', 'setup', '${_app.path}/auth/login.yaml'],
        environment: _offline,
      );

      // Past the presence check, to the device stage.
      expect(run.stdout, isNot(contains('is not set')), reason: _both(run));
      expect(run.stdout, contains('adb could not be found'),
          reason: _both(run));
      _expectNoSecret(run);
      expect(run.code, 2, reason: _both(run));
    });
  });

  // Every caller of `DotEnv.load`, on the same undecodable file.
  //
  // Each exit code is the one the command already gives a file the
  // operator has to correct - not a code chosen for this milestone.
  // `run` was 1 here when this was written, the code it then gave every
  // failure before launching. RUN-CONFIG-EXIT made that 2: configuration
  // is the run being wrong, as E-03 files it for a suite.
  group('every caller, on an undecodable .env', () {
    setUp(() {
      _soundProject();
      _writeUndecodableEnv(_app);
    });

    /// A configuration answer on stdout, and no crash on either stream.
    void expectReported(Run run, {required int code}) {
      for (final stream in [run.stdout, run.stderr]) {
        expect(stream, isNot(contains('Unhandled exception')),
            reason: _both(run));
        expect(stream, isNot(contains('#0 ')), reason: _both(run));
        expect(stream, isNot(contains('file:///')), reason: _both(run));
        expect(stream, isNot(contains('FileSystemException')),
            reason: _both(run));
      }
      expect(run.stdout, contains('.env'), reason: _both(run));
      expect(run.stdout, contains('Failed to decode'), reason: _both(run));
      _expectNoSecret(run);
      expect(run.code, code, reason: _both(run));
    }

    test('generate exits 1', () async {
      final run = await _testsmith(
        ['generate', '--app', _app.path],
        environment: _offline,
      );

      expectReported(run, code: 1);
    });

    test('preflight blocks on it and exits 2', () async {
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offline,
      );

      expectReported(run, code: 2);
      expect(run.stdout, contains('[BLOCK] credentials'), reason: _both(run));
    });

    test('suite run blocks on it, exits 2 and still writes suite.json',
        () async {
      final run = await _testsmith(
        ['suite', 'run', '${_app.path}/suites/s.yaml'],
        environment: _offline,
      );

      expectReported(run, code: 2);

      // Read from the file, not from either stream: CI's answer.
      final suiteJson = File('${_app.path}/out/suite/suite.json');
      expect(suiteJson.existsSync(), isTrue, reason: _both(run));
      final text = suiteJson.readAsStringSync();
      final json = jsonDecode(text) as Map<String, Object?>;
      final preflight = json['preflight'] as Map<String, Object?>;
      expect(preflight['blocked'], isTrue, reason: text);
      final checks =
          (preflight['checks'] as List).cast<Map<String, Object?>>();
      expect(checks.single['name'], 'credentials', reason: text);
      expect(checks.single['detail'], contains('.env'), reason: text);
      expect(text, isNot(contains(_secret)));
    });

    test('auth setup exits 2', () async {
      final run = await _testsmith(
        ['auth', 'setup', '${_app.path}/auth/login.yaml'],
        environment: _offline,
      );

      expectReported(run, code: 2);
      // Not the sentence skipping the file would have produced.
      expect(run.stdout, isNot(contains('is not set')), reason: _both(run));
    });

    test('figma pull exits 1', () async {
      final run = await _testsmith(
        ['figma', 'pull', '--app', _app.path, '--url', _figmaUrl],
        environment: _offline,
      );

      expectReported(run, code: 1);
      expect(run.stdout, isNot(contains('FIGMA_TOKEN is not set')),
          reason: _both(run));
    });

    test('figma pull still refuses it when the environment has the token',
        () async {
      // The real environment wins over the file's *values*; it does not
      // make an unreadable file somebody wrote beside the application
      // stop mattering. Stops before any request is made.
      final run = await _testsmith(
        ['figma', 'pull', '--app', _app.path, '--url', _figmaUrl],
        environment: {..._offline, 'FIGMA_TOKEN': 'from-environment'},
      );

      expectReported(run, code: 1);
    });

    test('run exits 2', () async {
      // `run` loads `.env` only after its device gate, so it is given a
      // device. `_analyse` loads it a second time, from the same
      // directories, after a verdict - unreachable once this one fails.
      final run = await _testsmith(
        [
          'run',
          '--app',
          _app.path,
          '--device',
          _serial,
          '${_app.path}/tests/home.yaml',
        ],
        environment: {..._offline, 'MYTEST_ADB': _fakeAdb()},
      );

      expectReported(run, code: 2);
      expect(run.stdout, isNot(contains('launching app')), reason: _both(run));
    });

    test('run exits 2 with the fixture server already up', () async {
      // The server binds before `.env` is loaded, so this return is the
      // one that has something open. A readable scenario: the separate
      // `run --mock-api` scenario-read defect is not what this is about.
      final run = await _testsmith(
        [
          'run',
          '--app',
          _app.path,
          '--device',
          _serial,
          '--mock-api',
          '0',
          '${_app.path}/tests/home.yaml',
        ],
        environment: {..._offline, 'MYTEST_ADB': _fakeAdb()},
      );

      expect(run.stdout, contains('mock API on'), reason: _both(run));
      expectReported(run, code: 2);
    });
  });

  group('what the caller guards must not have changed', () {
    setUp(_soundProject);

    test('preflight with no .env reports no credentials row', () async {
      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offline,
      );

      expect(run.stdout, contains('[ok]    flows'), reason: _both(run));
      expect(run.stdout, isNot(contains('credentials')), reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });

    test('preflight with a valid .env is the same', () async {
      _write('.env', _envText);

      final run = await _testsmith(
        ['preflight', '${_app.path}/suites/s.yaml'],
        environment: _offline,
      );

      expect(run.stdout, contains('[ok]    flows'), reason: _both(run));
      expect(run.stdout, isNot(contains('credentials')), reason: _both(run));
      _expectNoSecret(run);
      expect(run.code, 2, reason: _both(run));
    });

    test('figma pull with a malformed .env still reports the missing token',
        () async {
      _write('.env', 'this is not dotenv\n=orphan\n');

      final run = await _testsmith(
        ['figma', 'pull', '--app', _app.path, '--url', _figmaUrl],
        environment: _offline,
      );

      expect(run.stdout, contains('FIGMA_TOKEN is not set'),
          reason: _both(run));
      expect(run.code, 1, reason: _both(run));
    });

    test('run with no .env still gets as far as launching', () async {
      final run = await _testsmith(
        [
          'run',
          '--app',
          _app.path,
          '--device',
          _serial,
          '${_app.path}/tests/home.yaml',
        ],
        environment: {..._offline, 'MYTEST_ADB': _fakeAdb()},
      );

      // Past the guard, to whichever stage follows it. Since RUN-FLUTTER
      // that is the Flutter check, which this PATH - the Dart SDK alone -
      // never satisfies; on a machine where it did, the launch.
      expect(
        run.stdout,
        anyOf(
          contains('launching app'),
          contains('flutter was not found on PATH.'),
        ),
        reason: _both(run),
      );
      expect(run.stdout, isNot(contains('.env')), reason: _both(run));
    });
  });
}
