// OUT-UNUSABLE: an `--out` that cannot hold what is written into it.
//
// `run` and `auth setup` both create `--out` and write into it without a
// guard. Measured at 25fdc3b, offline: `auth setup --out <a file>` with
// its preflight blocked printed NOT AUTHENTICATED, then
//
//   Unhandled exception:
//   PathExistsException: Creation failed, path = '...' (OS Error: ...)
//   #2 AuthSetupSubcommand._finish (package:flutter_testsmith_cli/...)
//
// at exit 255. `run` writes `result.json` through the same unguarded
// create, and reaches it only after a device run: the build, the launch
// and every step, then the same stack trace and none of it recorded.
//
// An `--out` that is a file, or sits under one, is a fact about the
// invocation and is refused before anything is looked for - exit 2, the
// code both commands give every other unusable input. A write that fails
// for a reason nothing could foresee is reported, never a stack trace.
//
// Offline: no adb is reachable, so a control that gets past the check is
// recognised by the adb refusal it reaches next.
@Timeout(Duration(minutes: 8))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

const String _flow = 'appId: com.example.x\nflow: home\nsteps:\n'
    '  - launchApp\n'
    '  - expectScreen:\n      id: /home\n';

const String _authFile = '''
auth: t
app: {path: ../.., target: lib/main_uat.dart}
appId: com.example.package
device: {profile: p}
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/login]
login:
  - tap: {id: continue_button}
verify: {route: /home, element: home.body}
''';

Map<String, String> get _offline => {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
      'MYTEST_AUTH_PIN': '1234',
    };

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: _offline,
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

Future<Run> _run(String out) => _testsmith(
      ['run', '${_app.path}/flow.yaml', '--app', _app.path, '--out', out],
    );

Future<Run> _authSetup(String out) => _testsmith([
      'auth',
      'setup',
      '${_app.path}/mytest/auth/uat.yaml',
      '--device',
      'X',
      '--out',
      out,
    ]);

void _expectNoCrash(Run run) {
  expect('${run.stdout}${run.stderr}', isNot(contains('Unhandled exception')));
  expect('${run.stdout}${run.stderr}', isNot(contains('package:flutter_testsmith')));
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('out_unusable');
    addTearDown(() => _root.deleteSync(recursive: true));
    _app = Directory('${_root.path}/app')..createSync();

    _write('pubspec.yaml', 'name: app\n');
    _write('flow.yaml', _flow);
    _write('device_profiles/p.yaml', 'id: p\n');
    _write('lib/main_uat.dart', 'void main() {}');
    _write('mytest/auth/uat.yaml', _authFile);
    _write('blocker', 'a file, not a directory');
  });

  group('run', () {
    test('an --out that is a file is refused before the device', () async {
      final run = await _run('blocker');

      _expectNoCrash(run);
      expect(run.code, 2);
      expect(run.stdout, contains('blocker'));
      expect(run.stdout, contains('is a file'));
      expect(run.stdout, isNot(contains('adb could not be found')));
    });

    test('an --out under a file is refused the same way', () async {
      final run = await _run('blocker/reports');

      _expectNoCrash(run);
      expect(run.code, 2);
      expect(run.stdout, contains('is a file'));
      expect(run.stdout, isNot(contains('adb could not be found')));
    });

    test('control: a usable --out reaches the device gate', () async {
      final run = await _run('reports/nested');

      expect(run.code, 2);
      expect(run.stdout, isNot(contains('is a file')));
      expect(run.stdout, contains('adb could not be found'));
    });
  });

  group('auth setup', () {
    test('an --out that is a file is refused before preflight', () async {
      final run = await _authSetup('blocker');

      _expectNoCrash(run);
      expect(run.code, 2);
      expect(run.stdout, contains('blocker'));
      expect(run.stdout, contains('is a file'));
      expect(run.stdout, isNot(contains('NOT AUTHENTICATED')));
    });

    test('a write that fails anyway is reported, not a stack trace',
        () async {
      // Nothing about the directory rules it out, so it passes the check
      // and the write is what fails: the name auth.json is taken by a
      // directory.
      Directory('${_app.path}/taken/auth.json').createSync(recursive: true);

      final run = await _authSetup('taken');

      _expectNoCrash(run);
      expect(run.code, 2);
      expect(run.stdout, contains('NOT AUTHENTICATED'));
      expect(run.stdout, contains('could not be written'));
    });

    test('control: a usable --out records the blocked result', () async {
      final run = await _authSetup('reports');

      _expectNoCrash(run);
      expect(run.code, 2);
      expect(run.stdout, contains('NOT AUTHENTICATED'));
      expect(File('${_app.path}/reports/auth.json').existsSync(), isTrue);
    });
  });
}
