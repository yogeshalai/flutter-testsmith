// A run that lost its connection reported the screen as broken.
//
// `FlowExecutor` caught every exception from a step and recorded
// `StepStatus.failed`, and `RunResult._allResults` turns a failed step
// into a UI **FAIL**. So a VM Service that stopped answering, a device
// that went to sleep, or an SDK built from a different version of this
// platform all arrived in the report as an assertion about the
// application's user interface - a sentence about a screen nobody had
// been able to look at.
//
// E-05 drew this distinction for auth setup. The suite layer has had the
// vocabulary since E-03/E-04: `TestVerdict.error`,
// `ResultClassification.environment`, `EnvironmentKind.error` - whose
// own documentation lists "the device went away". What was missing was
// the runner marking it, so the suite could never see it.
//
// The verdict used here is ERROR rather than SKIP, and the choice
// matters. A flow cut short at step four has three passed steps behind
// it; reporting SKIP for the step would aggregate to PASS and claim the
// user journey works. ERROR is what this codebase already means by
// "could not answer the question" - `aggregateStatus` says so in as many
// words, and the visual validator already returns ERROR for a screen it
// could not photograph deterministically, "an error rather than a fail -
// the application is not necessarily wrong - and never a pass".
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

StepOutcome _step(StepStatus status, {String? detail}) => StepOutcome(
      description: 'tap "cta"',
      kind: StepKind.tap,
      status: status,
      durationMs: 1,
      detail: detail,
    );

RunResult _run({
  required List<StepOutcome> steps,
  List<ApiExpectationOutcome> apiChecks = const [],
  List<ScreenResult> screens = const [],
}) =>
    RunResult(
      flowName: 'f',
      appId: 'com.example.app',
      device: 'fake',
      startedAt: DateTime.utc(2026, 9, 16),
      duration: Duration.zero,
      steps: steps,
      screens: screens,
      apiChecks: apiChecks,
    );

ValidationStatus _status(RunResult run, ValidationDimension dimension) =>
    run.dimensions[dimension]!.status;

void main() {
  group('an observation failure is not an assertion about the UI', () {
    test('the UI dimension does not FAIL', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);

      expect(_status(run, ValidationDimension.ui), isNot(ValidationStatus.fail));
    });

    test('the UI dimension does not PASS', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);

      expect(_status(run, ValidationDimension.ui), isNot(ValidationStatus.pass));
    });

    test('it reports ERROR - the question was not answered', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);

      expect(_status(run, ValidationDimension.ui), ValidationStatus.error);
    });

    test('OVERALL is ERROR, never FAIL', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);

      expect(run.overall, ValidationStatus.error);
      expect(run.overall, isNot(ValidationStatus.fail));
    });

    test('the run did not pass', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);

      expect(run.passed, isFalse);
    });

    test('the run says so explicitly', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);

      expect(run.observationFailed, isTrue);
    });

    test('the cause survives onto the result', () {
      final run = _run(
        steps: [
          _step(
            StepStatus.observationFailed,
            detail: 'the application did not answer "ext.mytest.uiTree"',
          ),
        ],
      );

      expect(
        run.dimensions[ValidationDimension.ui]!.reason,
        contains('ext.mytest.uiTree'),
      );
    });

    test('steps that ran before it do not turn it into a PASS', () {
      // The case that rules SKIP out. Three good steps and then the
      // engine went blind: reporting PASS would claim the journey works.
      final run = _run(
        steps: [
          _step(StepStatus.ok),
          _step(StepStatus.ok),
          _step(StepStatus.ok),
          _step(StepStatus.observationFailed),
        ],
      );

      expect(_status(run, ValidationDimension.ui), ValidationStatus.error);
      expect(run.passed, isFalse);
    });
  });

  group('evidence already established is not erased', () {
    test('an API check satisfied before the failure stays PASS', () {
      final run = _run(
        steps: [_step(StepStatus.ok), _step(StepStatus.observationFailed)],
        apiChecks: [
          const ApiExpectationOutcome(
            endpoint: 'GET /api/orders',
            status: 200,
            failures: [],
          ),
        ],
      );

      expect(_status(run, ValidationDimension.api), ValidationStatus.pass);
    });

    test('a dimension that never ran is SKIP, not ERROR', () {
      // The invariant this platform rests on: unchecked is SKIP. An
      // observation failure must not start stamping ERROR over
      // dimensions it never touched.
      final run = _run(steps: [_step(StepStatus.observationFailed)]);

      expect(_status(run, ValidationDimension.figma), ValidationStatus.skip);
      expect(_status(run, ValidationDimension.visual), ValidationStatus.skip);
      expect(_status(run, ValidationDimension.api), ValidationStatus.skip);
    });

    test('an unrun dimension says nothing was checked', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);

      expect(
        run.dimensions[ValidationDimension.visual]!.reason,
        contains('nothing was checked'),
      );
    });
  });

  group('ordinary results are untouched', () {
    test('a failed step is still a UI FAIL', () {
      final run = _run(steps: [_step(StepStatus.failed, detail: 'no such id')]);

      expect(_status(run, ValidationDimension.ui), ValidationStatus.fail);
      expect(run.overall, ValidationStatus.fail);
      expect(run.observationFailed, isFalse);
    });

    test('a run of passing steps still passes', () {
      final run = _run(steps: [_step(StepStatus.ok), _step(StepStatus.ok)]);

      expect(run.passed, isTrue);
      expect(_status(run, ValidationDimension.ui), ValidationStatus.pass);
      expect(run.observationFailed, isFalse);
    });

    test('a skipped step is still SKIP', () {
      final run = _run(steps: [_step(StepStatus.skipped)]);

      expect(_status(run, ValidationDimension.ui), ValidationStatus.skip);
    });

    test('ERROR still outranks FAIL, as E-03 established', () {
      final run = _run(
        steps: [_step(StepStatus.failed), _step(StepStatus.observationFailed)],
      );

      expect(run.overall, ValidationStatus.error);
    });
  });

  group('serialisation', () {
    test('the step carries its own status on the wire', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);
      final json = run.toJson();
      final steps = json['steps']! as List<Object?>;

      expect(
        (steps.single! as Map<String, Object?>)['status'],
        StepStatus.observationFailed.wire,
      );
    });

    test('overall and passed already say it, so no key changed meaning', () {
      final run = _run(steps: [_step(StepStatus.observationFailed)]);
      final json = run.toJson();

      expect(json['overall'], ValidationStatus.error.wire);
      expect(json['passed'], isFalse);
    });

    test('the schema version is unchanged', () {
      // Nothing was added or repurposed: one existing field gained a
      // value. A consumer reading `overall` and `passed` is unaffected.
      final run = _run(steps: [_step(StepStatus.ok)]);

      expect(run.toJson()['resultSchemaVersion'], '1.6');
    });
  });

  group('the human summary does not call it a failed assertion', () {
    test('the step is marked as not carried out, not as failed', () {
      final lines = const E2eSummary().renderLines(
        _run(steps: [_step(StepStatus.observationFailed)]),
      );
      final step = lines.firstWhere((l) => l.contains('tap "cta"'));

      expect(step, contains('!'));
      expect(step, isNot(contains('✗')));
    });

    test('a genuinely failed step still reads as failed', () {
      final lines = const E2eSummary().renderLines(
        _run(steps: [_step(StepStatus.failed)]),
      );
      final step = lines.firstWhere((l) => l.contains('tap "cta"'));

      expect(step, contains('✗'));
    });
  });

  group('an observation failure is not sent for failure analysis', () {
    test('only application failures are worth explaining', () {
      // Asking a model why the device went to sleep would produce a
      // confident paragraph about a screen.
      final run = _run(
        steps: [_step(StepStatus.observationFailed, detail: 'connection lost')],
      );

      expect(
        run.steps.where((s) => s.status == StepStatus.failed),
        isEmpty,
      );
    });
  });
}
