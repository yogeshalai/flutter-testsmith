// A screen that could not be checked was printed as a screen that was
// wrong.
//
// `ValidationStatus` has said this from the beginning, in as many words:
// "`skip` and `error` are not `fail`. 'Figma is not configured' and 'the
// price is wrong' must never render as the same red X - conflating them
// teaches people to ignore failures."
//
// The model kept the distinction and every renderer threw it away.
// `ValidationReport.passed` is `!results.any((r) => r.blocksPass)`, which
// is false for a FAIL and equally false for an ERROR, and each of the
// three places that render a screen asked only that one question:
//
//     report.passed ? 'PASS' : 'FAIL'
//
// So a screen whose visual check reported "the screen would not hold
// still, there is no picture worth comparing" was printed in red next to
// a genuine price mismatch - and, worse, its message was never printed
// at all, because the detail loop reads `report.failures`, which is FAIL
// only.
//
// Nothing about the model changes here. `passed` keeps its meaning, the
// JSON keeps its shape, and the aggregation keeps its precedence. The
// renderers stop inferring `passed == false → FAIL` and read the status
// that was always there.
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

ValidationResult _pass() => const ValidationResult.pass(
      validatorId: 'v',
      message: 'the price matches',
      dimension: ValidationDimension.ui,
    );

ValidationResult _fail() => const ValidationResult.fail(
      validatorId: 'v',
      message: 'the price reads 9.99, expected 10.99',
      dimension: ValidationDimension.ui,
    );

ValidationResult _error() => const ValidationResult.error(
      validatorId: 'visual',
      message: 'the screen would not hold still, so there is no picture '
          'worth comparing',
      dimension: ValidationDimension.visual,
    );

ValidationResult _skip() => const ValidationResult.skip(
      validatorId: 'figma',
      message: 'no design is configured for this screen',
      dimension: ValidationDimension.figma,
    );

ScreenResult _screen(List<ValidationResult> results) => ScreenResult(
      screenId: '/product/details',
      report: ValidationReport(results),
    );

RunResult _run({
  List<StepOutcome> steps = const [
    StepOutcome(description: 'launch', kind: StepKind.launchApp, status: StepStatus.ok, durationMs: 0),
  ],
  List<ScreenResult> screens = const [],
}) =>
    RunResult(
      flowName: 'f',
      appId: 'com.example.app',
      device: 'fake',
      startedAt: DateTime.utc(2026, 9, 18),
      duration: Duration.zero,
      steps: steps,
      screens: screens,
    );

/// The screen status, read where it now lives.
ValidationStatus screenStatus(ValidationReport report) =>
    ScreenResult(screenId: '/s', report: report).status;

void main() {
  group('a screen rolls up to a status, not to a boolean', () {
    test('everything satisfied is PASS', () {
      expect(screenStatus(ValidationReport([_pass()])), ValidationStatus.pass);
    });

    test('a contradicted measurement is FAIL', () {
      expect(
        screenStatus(ValidationReport([_pass(), _fail()])),
        ValidationStatus.fail,
      );
    });

    test('a measurement that could not be established is ERROR, not FAIL', () {
      // The whole milestone, in one assertion.
      final status = screenStatus(ValidationReport([_pass(), _error()]));

      expect(status, ValidationStatus.error);
      expect(status, isNot(ValidationStatus.fail));
    });

    test('nothing checked is SKIP', () {
      expect(screenStatus(ValidationReport([_skip()])), ValidationStatus.skip);
    });

    test('a report with no results at all is SKIP', () {
      expect(screenStatus(ValidationReport([])), ValidationStatus.skip);
    });

    test('FAIL and ERROR together follow the existing precedence', () {
      // ERROR > FAIL is E-03's order, unchanged. ERROR must not collapse
      // into FAIL just because both are present.
      expect(
        screenStatus(ValidationReport([_fail(), _error()])),
        ValidationStatus.error,
      );
    });

    test('it is the same aggregation the dimensions already use', () {
      // One source of truth. A second rule here would drift from the
      // verdict block on the same page.
      final results = [_pass(), _error(), _skip()];
      expect(
        screenStatus(ValidationReport(results)),
        aggregateStatus(results.map((r) => r.status)),
      );
    });
  });

  group('passed keeps exactly the meaning it had', () {
    test('true when everything passed', () {
      expect(ValidationReport([_pass()]).passed, isTrue);
    });

    test('false for a failure', () {
      expect(ValidationReport([_pass(), _fail()]).passed, isFalse);
    });

    test('false for an error - it still blocks a pass', () {
      // A validator that could not run has not shown the screen correct.
      expect(ValidationReport([_pass(), _error()]).passed, isFalse);
    });

    test('true when nothing was checked', () {
      expect(ValidationReport([_skip()]).passed, isTrue);
    });
  });

  group('the section summary names the status', () {
    String resultLine(RunResult run) => const E2eSummary()
        .renderLines(run)
        .firstWhere((l) => l.startsWith('RESULT:'));

    test('a passing run still reads PASS', () {
      expect(resultLine(_run(screens: [_screen([_pass()])])), 'RESULT: PASS');
    });

    test('a failing run still reads FAIL', () {
      expect(resultLine(_run(screens: [_screen([_fail()])])), 'RESULT: FAIL');
    });

    test('a run whose check could not be established reads ERROR', () {
      expect(resultLine(_run(screens: [_screen([_error()])])), 'RESULT: ERROR');
    });

    test('ERROR is not rendered as FAIL', () {
      expect(
        resultLine(_run(screens: [_screen([_error()])])),
        isNot(contains('FAIL')),
      );
    });

    test('a run that checked nothing reads SKIP', () {
      // The line reads the run's own `overall` now, and `overall` has
      // always called this shape SKIP: a PASS is a positive claim, and
      // nothing was compared. `passed` stays vacuously true - it answers
      // a narrower question - and the exit code is unchanged at 0.
      //
      // No producible run is affected: a flow must declare at least one
      // step, so every real run has a UI result.
      expect(resultLine(_run(steps: const [])), 'RESULT: SKIP');
      expect(_run(steps: const []).passed, isTrue);
    });

    test('a run whose step could not be carried out reads ERROR', () {
      expect(
        resultLine(
          _run(steps: const [
            StepOutcome(
              description: 'tap',
              kind: StepKind.tap,
              status: StepStatus.observationFailed,
              durationMs: 0,
            ),
          ]),
        ),
        'RESULT: ERROR',
      );
    });
  });

  group('the HTML report names the status', () {
    // Built from a real serialised run, because the reporter's whole
    // premise is that the page is a pure function of the file CI reads.
    String badge(RunResult run) =>
        const HtmlReporter().render(run.toJson());

    test('a passing run still shows PASS', () {
      expect(badge(_run(screens: [_screen([_pass()])])), contains('>PASS<'));
    });

    test('a failing run still shows FAIL', () {
      expect(badge(_run(screens: [_screen([_fail()])])), contains('>FAIL<'));
    });

    test('a check that could not be run shows ERROR, not FAIL', () {
      final html = badge(_run(screens: [_screen([_error()])]));

      expect(html, contains('>ERROR<'));
      expect(html, isNot(contains('>FAIL<')));
    });

    test('a step that could not be carried out shows ERROR', () {
      final html = badge(
        _run(steps: const [
          StepOutcome(
            description: 'tap',
            kind: StepKind.tap,
            status: StepStatus.observationFailed,
            durationMs: 0,
          ),
        ]),
      );

      expect(html, contains('>ERROR<'));
    });

    test('an error is styled apart from a failure', () {
      // A red pill next to a genuine defect is the thing being fixed.
      final html = badge(_run(screens: [_screen([_error()])]));

      expect(html, contains('verdict error'));
      expect(html, isNot(contains('verdict fail')));
    });

    test('a result file predating these keys still renders', () {
      // The reporter takes whatever JSON it is handed, including one
      // written by an older build.
      final html = const HtmlReporter().render({
        'flow': 'f',
        'passed': false,
        'steps': const [],
        'screens': const [],
      });

      expect(html, contains('>FAIL<'));
    });
  });

  group('the machine-readable shape is untouched', () {
    test('the report still serialises passed and the four counts', () {
      final json = ValidationReport([_pass(), _error()]).toJson();

      expect(json['passed'], isFalse);
      expect((json['counts']! as Map)['error'], 1);
      expect((json['counts']! as Map)['fail'], 0);
    });

    test('each result already carries its own status', () {
      // Which is why no schema change is needed: ERROR was always
      // distinguishable in the file, only not on the screen.
      final json = ValidationReport([_error()]).toJson();
      final results = json['results']! as List<Object?>;

      expect(
        (results.single! as Map<String, Object?>)['status'],
        ValidationStatus.error.wire,
      );
    });

    test('no key was added to the report', () {
      expect(
        ValidationReport([_pass()]).toJson().keys.toSet(),
        {'passed', 'counts', 'results'},
      );
    });

    test('the result schema version is unchanged', () {
      expect(_run().toJson()['resultSchemaVersion'], '1.6');
    });
  });
}
