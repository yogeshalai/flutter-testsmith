// The auth file, and the four steps it refuses.
//
// The refusals are the reason this parser exists rather than reusing
// TestFlow: a security property that depends on nobody writing the wrong
// line is not a security property. `screenshot` would photograph a
// screen showing an unobscured mobile number; `validateScreen`
// photographs and writes trees into a report; `input` is a plaintext
// credential; and an assertion belongs in `verify:`, where its shape is
// constrained.

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const String _valid = '''
auth: test
app:
  path: ../..
  target: lib/main_example.dart
  flavor: example
appId: com.example.testapp.alpha
sdkAppId: com.example.testapp.beta
device:
  profile: samsung-m127g
  permissions:
    - android.permission.ACCESS_FINE_LOCATION
secrets:
  mobile: env:MYTEST_AUTH_MOBILE
  pin: env:MYTEST_AUTH_PIN
signedOutOn: [/onboarding, /login]
onboarding:
  - expectScreen: {id: /onboarding, timeoutMs: 40000}
  - tap: {id: onboarding.get_started}
login:
  - expectScreen: {id: /login, timeoutMs: 40000}
  - waitForSettle: {timeoutMs: 30000}
  - inputSecret: {id: login.mobile_field, secret: mobile}
  - tap: {id: login.continue_button}
  - inputSecret: {id: secure_login.pin_field, secret: pin}
  - tap: {id: secure_login.continue_button}
verify:
  route: /home
  timeoutMs: 60000
  element: home.body
  request: {endpoint: POST /login/consumer, status: 200}
  notOn: [/set-location]
  invalidCredentialOn:
    route: /secure-login
    element: secure_login.pin_error
''';

AuthFile _parse(String yaml) => AuthFile.parse(yaml, source: 'auth.yaml');

/// Removes one top-level block from the valid document, for the
/// "required key" tests.
String _without(String block) {
  final out = <String>[];
  var skipping = false;
  for (final line in _valid.split('\n')) {
    if (line.startsWith('$block:')) {
      skipping = true;
      continue;
    }
    if (skipping && line.isNotEmpty && !line.startsWith(' ')) skipping = false;
    if (!skipping) out.add(line);
  }
  return out.join('\n');
}

void main() {
  group('a valid file', () {
    test('reads its name, build and application id', () {
      final file = _parse(_valid);
      expect(file.name, 'test');
      expect(file.app.target, 'lib/main_example.dart');
      expect(file.app.flavor, 'example');
      expect(file.app.path, '../..');
      expect(file.appId, 'com.example.testapp.alpha');
    });

    test('the package and the SDK identity are read as two separate things',
        () {
      // They genuinely differ in the application this was built against:
      // the package is what Android installed, and the SDK identity is
      // what `TestSdk.initialize` declares. One field for both would
      // mean comparing a package name against a value that was never
      // going to equal it.
      final file = _parse(_valid);
      expect(file.appId, 'com.example.testapp.alpha');
      expect(file.sdkAppId, 'com.example.testapp.beta');
    });

    test('sdkAppId may be omitted, and is then null rather than guessed', () {
      expect(_parse(_without('sdkAppId')).sdkAppId, isNull);
    });

    test('reads its device profile and permissions', () {
      final file = _parse(_valid);
      expect(file.deviceProfile, 'samsung-m127g');
      expect(
        file.devicePermissions,
        ['android.permission.ACCESS_FINE_LOCATION'],
      );
    });

    test('reads secrets as references, never as values', () {
      final file = _parse(_valid);
      expect(file.secrets['pin'].toString(), 'env:MYTEST_AUTH_PIN');
      expect(file.secrets['mobile'].toString(), 'env:MYTEST_AUTH_MOBILE');
      expect(file.declaredSecrets, hasLength(2));
    });

    test('reads both step blocks', () {
      final file = _parse(_valid);
      expect(file.onboarding, hasLength(2));
      expect(file.login, hasLength(6));
      expect(file.login[2], isA<SecretInputStep>());
    });

    test('a secret step carries the reference the secrets block named', () {
      final step = _parse(_valid).login[2] as SecretInputStep;
      expect(step.elementId, 'login.mobile_field');
      expect(step.ref.name, 'MYTEST_AUTH_MOBILE');
      expect(step.describe(), contains('env:MYTEST_AUTH_MOBILE'));
    });

    test('reads the verify block', () {
      final verify = _parse(_valid).verify;
      expect(verify.route, '/home');
      expect(verify.element, 'home.body');
      expect(verify.timeout, const Duration(milliseconds: 60000));
      expect(verify.notOn, ['/set-location']);
      expect(verify.request!.status, 200);
      expect(verify.request!.expectations, isEmpty);
      expect(verify.invalidCredentialOn!.route, '/secure-login');
      expect(verify.invalidCredentialOn!.element, 'secure_login.pin_error');
    });

    test('onboarding may be omitted', () {
      final file = _parse(_without('onboarding'));
      expect(file.onboarding, isEmpty);
    });
  });

  group('refusals that are security properties', () {
    Matcher refusedBecause(String reason) => throwsA(
          isA<AuthFormatException>()
              .having((e) => e.message, 'message', contains(reason)),
        );

    test('screenshot is refused', () {
      expect(
        () => _parse(_valid.replaceFirst(
          '  - tap: {id: login.continue_button}',
          '  - screenshot: {name: login}',
        )),
        refusedBecause('screenshot'),
      );
    });

    test('validateScreen is refused', () {
      expect(
        () => _parse(_valid.replaceFirst(
          '  - tap: {id: login.continue_button}',
          '  - validateScreen: {figma: true}',
        )),
        refusedBecause('validateScreen'),
      );
    });

    test('plaintext input is refused, and says why', () {
      expect(
        () => _parse(_valid.replaceFirst(
          '  - inputSecret: {id: login.mobile_field, secret: mobile}',
          '  - input: {id: login.mobile_field, value: "9876543210"}',
        )),
        refusedBecause('secret reference'),
      );
    });

    test('expectApi in a step block is refused', () {
      expect(
        () => _parse(_valid.replaceFirst(
          '  - tap: {id: login.continue_button}',
          '  - expectApi: {endpoint: GET /x, status: 200}',
        )),
        refusedBecause('verify'),
      );
    });
  });

  group('malformed files', () {
    test('a secret named by a step but not declared is refused', () {
      expect(
        () => _parse(_valid.replaceFirst('secret: pin}', 'secret: otp}')),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('a literal credential in the secrets block is refused', () {
      expect(
        () => _parse(_valid.replaceFirst('env:MYTEST_AUTH_PIN', '1234')),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('an unknown top-level key is refused', () {
      expect(
        () => _parse('$_valid\nbypass: true\n'),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('a missing verify block is refused', () {
      expect(
        () => _parse(_without('verify')),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('an empty signedOutOn is refused, because it could never match', () {
      expect(
        () => _parse(_valid.replaceFirst(
          'signedOutOn: [/onboarding, /login]',
          'signedOutOn: []',
        )),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('a missing appId is refused', () {
      expect(
        () => _parse(_without('appId')),
        throwsA(isA<AuthFormatException>()),
      );
    });

    // A value of the wrong *type*, as distinct from the missing and
    // unknown keys above. `requireString` beside it has always checked;
    // `timeoutMs` was a cast, so an ordinary slip left the parser as a
    // `TypeError` - which no caller guards - and `auth setup` exited 255
    // with a stack trace and an absolute path. Measured on all four
    // forms that accept the key, against 4ef96a7.
    group('a timeoutMs that is not a number', () {
      void expectRejected(String yaml) {
        expect(
          () => _parse(yaml),
          throwsA(
            isA<AuthFormatException>()
                .having((e) => e.toString(), 'message', contains('timeoutMs'))
                // The file, which is what sends somebody to the right
                // place - the provenance every other refusal carries.
                .having((e) => e.toString(), 'source', contains('auth.yaml')),
          ),
          reason: yaml,
        );
      }

      test('on waitForSettle', () {
        expectRejected(
          _valid.replaceFirst(
            '  - waitForSettle: {timeoutMs: 30000}',
            '  - waitForSettle: {timeoutMs: soon}',
          ),
        );
      });

      test('on expectScreen', () {
        expectRejected(
          _valid.replaceFirst(
            '  - expectScreen: {id: /login, timeoutMs: 40000}',
            '  - expectScreen: {id: /login, timeoutMs: soon}',
          ),
        );
      });

      test('on expectElement', () {
        expectRejected(
          _valid.replaceFirst(
            '  - tap: {id: login.continue_button}',
            '  - expectElement: {id: login.banner, timeoutMs: soon}',
          ),
        );
      });

      test('on verify, which is parsed elsewhere', () {
        expectRejected(_valid.replaceFirst('  timeoutMs: 60000', '  timeoutMs: soon'));
      });
    });

    group('and what a wrong timeoutMs must not change', () {
      test('a well-typed timeoutMs is still read', () {
        final file = _parse(_valid);

        expect(file.verify.timeout, const Duration(milliseconds: 60000));
      });

      test('an absent timeoutMs still falls back to the default', () {
        final file = _parse(
          _valid.replaceFirst('  timeoutMs: 60000\n', ''),
        );

        expect(file.verify.timeout, const Duration(milliseconds: 60000));
      });

      test('an explicit null still means "not given"', () {
        // YAML `timeoutMs:` with nothing after it. The cast accepted
        // this and so must the guard - tightening it would refuse files
        // that have always been valid.
        final file = _parse(
          _valid.replaceFirst('  timeoutMs: 60000', '  timeoutMs:'),
        );

        expect(file.verify.timeout, const Duration(milliseconds: 60000));
      });

      test('a sound file still parses end to end', () {
        expect(() => _parse(_valid), returnsNormally);
      });
    });
  });
}
