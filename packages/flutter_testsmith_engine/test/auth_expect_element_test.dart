// An auth flow accepted assertions it never made.
//
// `AuthFile.parse` admitted every argument of `expectElement` - present,
// enabled, visible, text, textContains - and `AuthRunner._drive` read
// the id and nothing else. An author writing
//
//     - expectElement: {id: login.continue_button, enabled: true}
//
// got a green from a step that had only asked whether the element was in
// the tree. Worse for `present: false`, where the runner asserted the
// *opposite* of what was written: it raised "not found" for an element
// the author had said must be absent.
//
// A step that parses and asserts less than it says is the defect this
// repository already refuses by name elsewhere - `screenshot`,
// `validateScreen`, `input` and `expectApi` are all rejected from an
// auth flow with the reason printed. These arguments join them: an auth
// flow's `expectElement` is a waypoint on the way to the login form, and
// assertions about state belong in `verify:`, whose shape is constrained
// so that nothing of a credential can ride into a report.
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// An auth file whose login block contains [step].
String _withLoginStep(String step) => '''
auth: t
app: {path: .}
appId: com.example.package
device: {profile: p}
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/login]
login:
  - expectScreen: {id: /login}
  - $step
  - inputSecret: {id: login.pin, secret: pin}
verify:
  route: /home
  element: home.body
''';

AuthFile _parse(String step) =>
    AuthFile.parse(_withLoginStep(step), source: 'auth.yaml');

/// The `expectElement` step of a parsed login block.
ExpectElementStep _stepOf(AuthFile file) =>
    file.login.whereType<ExpectElementStep>().single;

void main() {
  group('an argument the runner cannot honour is refused by name', () {
    for (final argument in const [
      'enabled: true',
      'enabled: false',
      'visible: true',
      'text: Continue',
      'textContains: Cont',
      'present: true',
      'present: false',
    ]) {
      test('"$argument" is refused', () {
        expect(
          () => _parse('expectElement: {id: login.cta, $argument}'),
          throwsA(isA<AuthFormatException>()),
        );
      });
    }

    test('the refusal names the argument and where the assertion belongs',
        () {
      try {
        _parse('expectElement: {id: login.cta, enabled: true}');
        fail('an assertion the runner never makes was accepted');
      } on AuthFormatException catch (error) {
        expect(error.message, contains('enabled'));
        expect(error.message, contains('verify'),
            reason: 'a refusal that does not say where to put it instead '
                'just moves the problem');
      }
    });

    test('several offending arguments are all named', () {
      try {
        _parse('expectElement: {id: login.cta, enabled: true, visible: true}');
        fail('accepted');
      } on AuthFormatException catch (error) {
        expect(error.message, contains('enabled'));
        expect(error.message, contains('visible'));
      }
    });
  });

  group('the waypoint itself still parses', () {
    test('an id alone is accepted', () {
      expect(
        _stepOf(_parse('expectElement: {id: login.cta}')).elementId,
        'login.cta',
      );
    });

    test('a declared timeout is carried onto the step', () {
      // Parsed *and* honoured. It used to be read here and dropped by
      // the runner, which read the tree once.
      expect(
        _stepOf(_parse('expectElement: {id: login.cta, timeoutMs: 3000}'))
            .timeout,
        const Duration(milliseconds: 3000),
      );
    });

    test('no timeout keeps the existing default', () {
      expect(
        _stepOf(_parse('expectElement: {id: login.cta}')).timeout,
        const Duration(seconds: 5),
      );
    });

    test('an unknown argument is still refused as unknown', () {
      expect(
        () => _parse('expectElement: {id: login.cta, colour: red}'),
        throwsA(isA<AuthFormatException>()),
      );
    });
  });

  group('the product flow DSL is unaffected', () {
    test('a test flow may still assert enabled', () {
      // The refusal is a property of auth files, where a report may not
      // carry a credential. A product flow has always been able to say
      // this, and `examples/ecommerce_app` does.
      final flow = TestFlow.parse('''
appId: com.example.app
steps:
  - expectElement: {id: product.add_to_cart, enabled: false}
''', source: 'flow.yaml');

      final step = flow.steps.whereType<ExpectElementStep>().single;
      expect(step.enabled, isFalse);
    });
  });
}
