// What a step *was*, and who gets to say so.
//
// This file used to pin a description classifier, because that was all a
// serialised step had. Run schema 1.3 gives every step an explicit
// `kind`, sourced from the concrete sealed `Step` in `FlowExecutor`, and
// the file's purpose changes with it:
//
//   * the concrete `Step` → `StepKind` mapping is total and stable;
//   * a present kind is **authoritative** - a description is never
//     consulted to disagree with it;
//   * an artefact written before 1.3 has no kind, and the old
//     description classifier still decides those, wrong cases included.
//
// The two wrong cases are why the field exists. An `expectElement` whose
// expected text contains "to have answered", and an `expectScreen` whose
// screen id does, both read as API assertions to the description
// classifier and vanish from the UI section of a report that has no API
// entry for them either. At 1.3 they are UI steps, because the step says
// so. Before 1.3 they are still wrong, and deliberately left that way:
// guessing at an old file is how a report starts disagreeing with the
// run it describes.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Names the kind of a step, for the test's own reporting.
///
/// Exhaustive over the sealed hierarchy deliberately: adding a `Step`
/// stops this compiling until someone decides what it is. That is the
/// same question `stepKindOf` asks, asked a second time so the fixture
/// below cannot quietly fall behind the production mapping.
String _name(Step step) => switch (step) {
      LaunchAppStep() => 'LaunchAppStep',
      WaitForSettleStep() => 'WaitForSettleStep',
      TapStep() => 'TapStep',
      InputStep() => 'InputStep',
      SecretInputStep() => 'SecretInputStep',
      BackStep() => 'BackStep',
      ExpectScreenStep() => 'ExpectScreenStep',
      ExpectElementStep() => 'ExpectElementStep',
      ScreenshotStep() => 'ScreenshotStep',
      ExpectApiStep() => 'ExpectApiStep',
      ValidateScreenStep() => 'ValidateScreenStep',
    };

/// Every concrete kind, with the kind it must map to.
///
/// Realistic values, and no credential in any of them: `SecretInputStep`
/// carries a *reference*, which is the half of a secret allowed to
/// travel into a report.
const List<(Step, StepKind)> _representative = [
  (LaunchAppStep(), StepKind.launchApp),
  (WaitForSettleStep(), StepKind.waitForSettle),
  (TapStep('login.submit'), StepKind.tap),
  (
    InputStep(elementId: 'login.mobile_field', value: '9000000001'),
    StepKind.input
  ),
  (
    SecretInputStep(
      elementId: 'login.password_field',
      ref: SecretRef(scheme: 'env', name: 'LOGIN_PASSWORD'),
    ),
    StepKind.secretInput
  ),
  (BackStep(), StepKind.back),
  (ExpectScreenStep('/dashboard'), StepKind.expectScreen),
  (
    ExpectElementStep(elementId: 'dashboard.greeting', text: 'Good morning'),
    StepKind.expectElement
  ),
  (ScreenshotStep('dashboard'), StepKind.screenshot),
  (
    ExpectApiStep(endpoint: ApiEndpoint('GET', '/api/dashboard'), status: 200),
    StepKind.expectApi
  ),
  (ValidateScreenStep(), StepKind.validateScreen),
];

/// The two descriptions that broke the pre-1.3 classifier.
const String _elementCollision =
    'expect "chat.last_reply" textContains = to have answered';
const String _screenCollision = 'expect to be on "/faq/to have answered"';

String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

void main() {
  group('every concrete Step has exactly one kind', () {
    for (final (step, kind) in _representative) {
      test('${_name(step)} -> ${kind.wire}', () {
        expect(stepKindOf(step), kind);
      });
    }

    test('the fixture covers every kind in the vocabulary', () {
      // Adding a `StepKind` without a representative step fails here;
      // adding a `Step` without a kind fails to compile in `stepKindOf`
      // and in `_name`. Between them there is no way in.
      expect(
        _representative.map((e) => e.$2).toSet(),
        StepKind.values.toSet(),
      );
    });

    test('no two steps share a kind', () {
      expect(_representative.map((e) => e.$2).toSet().length,
          _representative.length);
    });
  });

  group('the wire vocabulary is the contract', () {
    // Spelled out rather than derived from `name`. These strings are
    // what lands in `result.json`; a rename of a Dart identifier must
    // not be able to change them silently.
    const expected = {
      StepKind.launchApp: 'launchApp',
      StepKind.waitForSettle: 'waitForSettle',
      StepKind.tap: 'tap',
      StepKind.input: 'input',
      StepKind.secretInput: 'secretInput',
      StepKind.back: 'back',
      StepKind.expectScreen: 'expectScreen',
      StepKind.expectElement: 'expectElement',
      StepKind.screenshot: 'screenshot',
      StepKind.expectApi: 'expectApi',
      StepKind.validateScreen: 'validateScreen',
    };

    test('every kind has its documented string', () {
      expect(
        {for (final k in StepKind.values) k: k.wire},
        expected,
      );
    });

    test('there are eleven of them, and no spelling appears twice', () {
      expect(StepKind.values.length, 11);
      expect(expected.values.toSet().length, 11);
    });
  });

  group('a present kind decides, and the description is not consulted', () {
    test('expectApi is an API assertion whatever it says', () {
      for (final description in const [
        'expect GET /api/login to have answered 200',
        'something else entirely',
        '',
      ]) {
        expect(
          isApiAssertionStep(
            kind: StepKind.expectApi.wire,
            description: description,
          ),
          isTrue,
          reason: description,
        );
      }
    });

    test('an expectElement is not, even wearing the API wording', () {
      expect(
        isApiAssertionStep(
          kind: StepKind.expectElement.wire,
          description: _elementCollision,
        ),
        isFalse,
      );
    });

    test('an expectScreen is not either', () {
      expect(
        isApiAssertionStep(
          kind: StepKind.expectScreen.wire,
          description: _screenCollision,
        ),
        isFalse,
      );
    });

    test('no other kind is ever an API assertion', () {
      for (final kind in StepKind.values) {
        if (kind == StepKind.expectApi) continue;
        expect(
          isApiAssertionStep(
            kind: kind.wire,
            description: 'expect GET /api/x to have answered 200',
          ),
          isFalse,
          reason: kind.wire,
        );
      }
    });

    test('an unknown future kind is treated as a UI step', () {
      // Forward compatibility: a kind this build does not know is not an
      // `expectApi`, and falling back to the description would be
      // exactly the second-guessing the field exists to stop.
      expect(
        isApiAssertionStep(
          kind: 'somethingAddedLater',
          description: 'expect GET /api/x to have answered 200',
        ),
        isFalse,
      );
    });

    test('the live mapping and the classifier agree, per kind', () {
      for (final (step, _) in _representative) {
        expect(
          isApiAssertionStep(
            kind: stepKindOf(step).wire,
            description: step.describe(),
          ),
          step is ExpectApiStep,
          reason: _name(step),
        );
      }
    });
  });

  group('a pre-1.3 artefact still uses the description classifier', () {
    test('an expectApi description is classified as API', () {
      expect(
        isApiAssertionStep(
          kind: null,
          description: 'expect GET /api/dashboard to have answered 200',
        ),
        isTrue,
      );
    });

    test('an ordinary step is not', () {
      expect(
        isApiAssertionStep(kind: null, description: 'tap "login.submit"'),
        isFalse,
      );
    });

    test('the two known false positives are preserved, not repaired', () {
      // Asserted as they are, on purpose. An old file cannot be made to
      // say what it never recorded, and inventing a kind for it would
      // put a guess where the report promises a measurement.
      expect(
        isApiAssertionStep(kind: null, description: _elementCollision),
        isTrue,
      );
      expect(
        isApiAssertionStep(kind: null, description: _screenCollision),
        isTrue,
      );
    });

    test('the fallback is reachable on its own terms', () {
      expect(isApiAssertionDescription(_elementCollision), isTrue);
      expect(isApiAssertionDescription('tap "x"'), isFalse);
      expect(
        isApiAssertionDescription(
          'expect GET /api/cart to have answered 200, 2 fields',
        ),
        isTrue,
      );
    });
  });

  group('the exact description ExpectApiStep produces today', () {
    const step = ExpectApiStep(
      endpoint: ApiEndpoint('GET', '/api/dashboard/summary'),
      status: 200,
      expectations: [ApiExpectation(path: 'token', present: true)],
    );

    test('is what it has always been', () {
      expect(
        step.describe(),
        'expect GET /api/dashboard/summary to have answered '
        '200, 1 field',
      );
    });

    test('is classified as API by kind, and by the legacy text', () {
      expect(stepKindOf(step), StepKind.expectApi);
      expect(isApiAssertionDescription(step.describe()), isTrue);
    });
  });

  group('one rule, and nothing that guesses', () {
    test('the mapping reads no type name and no text', () {
      // `.runtimeType`, not `runtimeType`: the doc comments in that file
      // mention the word to say the mapping does not use it, and a guard
      // that cannot tell prose from a call would forbid explaining
      // itself.
      final steps = _source('flutter_testsmith/lib/src/engine/dsl/steps.dart');

      expect(steps, isNot(contains('.runtimeType')));
      expect(steps, isNot(contains('dart:mirrors')));
      expect(steps, contains('StepKind stepKindOf(Step step) => switch'));
    });

    test('the classifier holds the only copy of the fallback wording', () {
      for (final file in const [
        'flutter_testsmith/lib/src/engine/reporting/e2e_summary.dart',
        'flutter_testsmith/lib/src/engine/reporting/html_reporter.dart',
      ]) {
        expect(_source(file), isNot(contains('to have answered')),
            reason: file);
        expect(_source(file), contains('isApiAssertionStep'), reason: file);
      }
    });

    test('both reporters pass a kind to it', () {
      for (final file in const [
        'flutter_testsmith/lib/src/engine/reporting/e2e_summary.dart',
        'flutter_testsmith/lib/src/engine/reporting/html_reporter.dart',
      ]) {
        expect(_source(file), contains('kind:'), reason: file);
      }
    });

    test('the reporters still decide no verdict', () {
      for (final file in const [
        'flutter_testsmith/lib/src/engine/reporting/e2e_summary.dart',
        'flutter_testsmith/lib/src/engine/reporting/html_reporter.dart',
      ]) {
        expect(_source(file), isNot(contains('aggregateStatus')), reason: file);
        expect(_source(file), isNot(contains('errorCount')), reason: file);
      }
    });

    test('the kind comes from the step, in the executor', () {
      final executor = _source('flutter_testsmith_cli/lib/src/flow_executor.dart');

      expect(executor, contains('kind: stepKindOf(step)'));
      expect(executor, isNot(contains('kind: StepKind.')));
    });
  });
}
