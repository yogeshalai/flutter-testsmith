// AUTH-DECODE: an auth file that exists but cannot be decoded.
//
// `auth setup` reads its file with `readAsString`, which decodes as well
// as reads and reports a failure to decode as a `FileSystemException` -
// not the `AuthFormatException` or `SecretRefFormatException` the clause
// around that read already catches. Measured at abda924 on Windows with
// a UTF-16 LE `auth/login.yaml` (what Notepad and PowerShell's `>`
// write): an unhandled exception, exit 255, and this tool's install path
// in the trace.
//
// It is now reported the way every other unusable auth file is: as an
// `AuthFormatException` naming the file, at exit 2.
//
// Offline throughout. No `.env` exists anywhere these runs look, so the
// auth file is the only thing that can fail; DOTENV-DECODE covered that
// file separately.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

/// A value that must never appear in any output.
const String _secret = 'AUTH_DECODE_SENTINEL_VALUE';

/// A sound auth file. Its one secret is a reference, never a value.
const String _authText = 'auth: t\n'
    'app: {path: .., target: lib/main_uat.dart}\n'
    'appId: com.example.x\n'
    'device:\n  profile: p\n'
    'secrets: {pin: env:MYTEST_AUTH_PIN}\n'
    'signedOutOn: [/login]\n'
    'login:\n  - tap: {id: login.submit}\n'
    'verify: {route: /home, element: home.body}\n';

/// [text] as UTF-16 LE with a byte-order mark: `FF FE` is not valid
/// UTF-8, so `readAsString` refuses the file outright.
List<int> _utf16leWithBom(String text) => [
      0xFF,
      0xFE,
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];

late Directory _root;
late Directory _app;

String get _authPath => '${_app.path}/auth/login.yaml';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

typedef Run = ({String stdout, String stderr, int code});

/// The declared secret set in the environment, and a PATH holding the
/// Dart SDK and nothing else, so no adb is reachable and a handset on
/// the host cannot change an answer. The isolation
/// `project_configuration_errors_test.dart` uses for `auth setup`.
Future<Run> _authSetup(String path) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', 'auth', 'setup',
        path],
    environment: {
      'MYTEST_AUTH_PIN': _secret,
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
    // Not the application, and holding no `.env`.
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}';

/// No crash on either stream, and nothing secret on either.
void _expectClean(Run run) {
  for (final stream in [run.stdout, run.stderr]) {
    expect(stream, isNot(contains('Unhandled exception')), reason: _both(run));
    expect(stream, isNot(contains('#0 ')), reason: _both(run));
    expect(stream, isNot(contains('file:///')), reason: _both(run));
    expect(stream, isNot(contains(_secret)), reason: _both(run));
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('auth_decode');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main_uat.dart', 'void main() {}\n');
    _write('device_profiles/p.yaml', 'id: p\nmodel: FakePhone\n');
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  test('an undecodable auth file is an AuthFormatException, exit 2', () async {
    File(_authPath)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(_utf16leWithBom(_authText));

    final run = await _authSetup(_authPath);

    _expectClean(run);
    expect(run.stdout, contains('AuthFormatException in $_authPath: '),
        reason: _both(run));
    expect(run.stdout, contains('Failed to decode'), reason: _both(run));
    for (final stream in [run.stdout, run.stderr]) {
      expect(stream, isNot(contains('FileSystemException')),
          reason: _both(run));
    }
    expect(run.code, 2, reason: _both(run));
  });

  group('what the guard must not have changed', () {
    test('a valid auth file still reaches the device stage', () async {
      _write('auth/login.yaml', _authText);

      final run = await _authSetup(_authPath);

      _expectClean(run);
      expect(run.stdout, isNot(contains('AuthFormatException')),
          reason: _both(run));
      expect(run.stdout, contains('adb could not be found'),
          reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });

    test('a malformed auth file is still reported by the parser', () async {
      _write('auth/login.yaml', '${_authText}unexpected: key\n');

      final run = await _authSetup(_authPath);

      _expectClean(run);
      expect(run.stdout, contains('AuthFormatException in $_authPath: '),
          reason: _both(run));
      expect(run.stdout, isNot(contains('Failed to decode')),
          reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });

    test('a bad secret reference is still reported by the parser', () async {
      // `AuthFile.parse` restates a `SecretRefFormatException` as its own
      // `AuthFormatException`, naming the secret; that is the contract
      // this pins, and it is unchanged.
      _write(
        'auth/login.yaml',
        _authText.replaceFirst('env:MYTEST_AUTH_PIN', 'vault:MYTEST_AUTH_PIN'),
      );

      final run = await _authSetup(_authPath);

      _expectClean(run);
      // Since AUTH-SECRET-DISCLOSURE the scheme is not repeated: for a
      // literal with a colon in it, it would be the front of the value.
      expect(
        run.stdout,
        contains('AuthFormatException in $_authPath: '
            'secret "pin": unknown secret scheme.'),
        reason: _both(run),
      );
      expect(run.code, 2, reason: _both(run));
    });

    test('a literal credential is refused without being printed', () async {
      // AUTH-SECRET-DISCLOSURE, as the operator sees it. Measured at
      // c24656b: `secret "pin": "<the literal>" is not a secret
      // reference`, on stdout, at exit 2.
      const literal = 'SUPER_SECRET_SENTINEL_DO_NOT_PRINT';
      _write(
        'auth/login.yaml',
        _authText.replaceFirst('env:MYTEST_AUTH_PIN', literal),
      );

      final run = await _authSetup(_authPath);

      _expectClean(run);
      for (final stream in [run.stdout, run.stderr]) {
        expect(stream, isNot(contains(literal)), reason: _both(run));
      }
      expect(
        run.stdout,
        contains('AuthFormatException in $_authPath: '
            'secret "pin": the value is not a secret reference.'),
        reason: _both(run),
      );
      expect(run.code, 2, reason: _both(run));
    });

    test('an absent auth file is still its own sentence', () async {
      final run = await _authSetup(_authPath);

      _expectClean(run);
      expect(run.stdout, contains('No such auth file: $_authPath'),
          reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });
  });
}
