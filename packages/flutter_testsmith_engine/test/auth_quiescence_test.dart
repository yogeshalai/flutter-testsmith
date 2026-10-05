// DEF-E05-02 - an auth flow may declare a perpetual animation.
//
// Measured on a Samsung SM-M127G against an external application: the
// onboarding screen runs a Lottie for ever, so `waitForSettle` could
// never succeed and a signed-out run was unreachable. The suite DSL
// already had the answer; an auth file had no way to say it.
//
// The point of this file is that there is exactly ONE dialect. Every
// refusal below is the mappings parser's refusal, reached through the
// auth parser.
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// A minimal auth file, plus whatever block a test is about.
String _authFile(String extra) => '''
auth: a
app: {path: ., target: lib/main.dart}
appId: com.example.app
device: {profile: p}
secrets: {pin: env:PIN}
signedOutOn: [/login]
login:
  - expectScreen: {id: /login}
  - inputSecret: {id: login.pin, secret: pin}
verify: {route: /home, element: home.body}
$extra''';

const String _declaration = '''
quiescence:
  allow:
    - element: onboarding.illustration
      widget: Lottie
      count: 1
      reason: the onboarding illustration loops for ever by design
''';

void main() {
  test('a valid quiescence block parses', () {
    final file = AuthFile.parse(_authFile(_declaration), source: 'auth.yaml');

    expect(file.quiescence.allow, hasLength(1));
    final allowed = file.quiescence.allow.single;
    expect(allowed.element, 'onboarding.illustration');
    expect(allowed.widget, 'Lottie');
    expect(allowed.count, 1);
    expect(allowed.reason, contains('loops for ever'));
  });

  test('an auth file that says nothing permits nothing', () {
    final file = AuthFile.parse(_authFile(''), source: 'auth.yaml');
    expect(file.quiescence.allow, isEmpty);
  });

  test('the same text parses identically in a mappings file', () {
    // One parser, one dialect. If these ever disagree, there are two.
    final fromAuth =
        AuthFile.parse(_authFile(_declaration), source: 'a').quiescence;
    final fromMappings = MappingsFile.parse(
      'screen: /onboarding\n$_declaration',
      source: 'm',
    ).quiescence;

    expect(fromAuth.allow.single.element, fromMappings.allow.single.element);
    expect(fromAuth.allow.single.widget, fromMappings.allow.single.widget);
    expect(fromAuth.allow.single.count, fromMappings.allow.single.count);
    expect(fromAuth.allow.single.reason, fromMappings.allow.single.reason);
  });

  group('an invalid declaration is refused, never a silent permit', () {
    void refused(String block, {String? because}) {
      expect(
        () => AuthFile.parse(_authFile(block), source: 'auth.yaml'),
        throwsA(
          because == null
              ? isA<AuthFormatException>()
              : isA<AuthFormatException>()
                  .having((e) => e.message, 'message', contains(because)),
        ),
      );
    }

    test('a wildcard element, as in a mappings file', () {
      refused('''
quiescence:
  allow:
    - element: "onboarding.*"
      reason: everything moves
''', because: 'not a pattern');
    });

    test('a declaration with no reason', () {
      refused('''
quiescence:
  allow:
    - element: onboarding.illustration
''', because: 'reason');
    });

    test('an unknown key inside the block', () {
      refused('''
quiescence:
  permit:
    - element: x
''');
    });

    test('an unknown key on an allow entry', () {
      refused('''
quiescence:
  allow:
    - element: onboarding.illustration
      reason: it loops
      forever: true
''');
    });

    test('the same element declared twice', () {
      refused('''
quiescence:
  allow:
    - element: onboarding.illustration
      widget: Lottie
      reason: it loops
    - element: onboarding.illustration
      widget: Lottie
      reason: again
''', because: 'twice');
    });

    test('a count that is not a whole number of animations', () {
      refused('''
quiescence:
  allow:
    - element: onboarding.illustration
      count: 0
      reason: it loops
''', because: 'count');
    });

    test('allow that is not a list', () {
      refused('''
quiescence:
  allow: onboarding.illustration
''');
    });
  });
}
