// The CI contract for `testsmith auth setup`, driven through the real
// executable, because an exit code is not something a library call has.
//
// 0 authenticated, 2 the run is wrong, 64 the invocation is wrong. Never
// 1: auth setup judges no screen, so it is never in a position to say
// the application is wrong.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/no_device_adb.dart';

Future<ProcessResult> _mytest(List<String> arguments) => Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/testsmith.dart', ...arguments],
      workingDirectory: Directory.current.path,
      // MYTEST_AUTH_PIN unset and no device, arranged: a developer who
      // exports the PIN for real E-05 runs otherwise sent "a missing
      // secret" straight past the presence check.
      environment: noDeviceEnvironment(_root),
    );

late Directory _root;

void _write(String path, String contents) {
  File('${_root.path}/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

const String _authFile = '''
auth: t
app: {path: ., target: lib/main_uat.dart, flavor: f}
appId: com.example.package
sdkAppId: com.example.sdkidentity
device: {profile: p}
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/login]
login:
  - tap: {id: continue_button}
verify: {route: /home, element: home.body}
''';

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('auth_cmd');
    addTearDown(() => _root.deleteSync(recursive: true));

    _write('proj/device_profiles/p.yaml', 'id: p\n');
    _write('proj/lib/main_uat.dart', 'void main() {}');
    _write('proj/mytest/auth/uat.yaml', _authFile);
  });

  test('the command is registered', () async {
    final result = await _mytest(['--help']);
    expect(result.stdout.toString(), contains('auth'));
  });

  test('no argument is 64', () async {
    expect((await _mytest(['auth', 'setup'])).exitCode, 64);
  });

  test('more than one argument is 64', () async {
    expect((await _mytest(['auth', 'setup', 'a.yaml', 'b.yaml'])).exitCode, 64);
  });

  test('no such auth file is 2', () async {
    final result = await _mytest(['auth', 'setup', '${_root.path}/nope.yaml']);
    expect(result.exitCode, 2);
    expect(result.stdout.toString(), contains('No such auth file'));
  });

  test('a malformed auth file is 2 and says what is wrong', () async {
    _write('proj/mytest/auth/bad.yaml', 'auth: t\nbypass: true\n');
    final result = await _mytest(
      ['auth', 'setup', '${_root.path}/proj/mytest/auth/bad.yaml'],
    );
    expect(result.exitCode, 2);
    expect(result.stdout.toString(), contains('bypass'));
  });

  test('a missing secret is 2, and nothing is built', () async {
    // MYTEST_AUTH_PIN is not set in this process, so the presence check
    // refuses before any device is touched.
    final result = await _mytest([
      'auth',
      'setup',
      '${_root.path}/proj/mytest/auth/uat.yaml',
      '-d',
      'NO_SUCH_DEVICE',
    ]);
    expect(result.exitCode, 2);
    final output = result.stdout.toString();
    expect(output, contains('MYTEST_AUTH_PIN'));
    expect(output, isNot(contains('Building')));
  });

  test('the usage line names the file, not a suite', () async {
    final result = await _mytest(['auth', 'setup', '--help']);
    expect(result.stdout.toString(), contains('auth setup <auth.yaml>'));
  });

  test('no output ever prints a secret value', () async {
    final result = await _mytest([
      'auth',
      'setup',
      '${_root.path}/proj/mytest/auth/uat.yaml',
      '-d',
      'NO_SUCH_DEVICE',
    ]);
    final text = '${result.stdout}${result.stderr}';
    expect(text, isNot(contains('SEEDED')));
    expect(text, contains('env:MYTEST_AUTH_PIN'));
  });
}
