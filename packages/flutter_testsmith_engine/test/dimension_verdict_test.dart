import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

ValidationResult _r(ValidationStatus s, ValidationDimension d) => switch (s) {
      ValidationStatus.pass =>
        ValidationResult.pass(validatorId: 'v', message: 'm', dimension: d),
      ValidationStatus.fail =>
        ValidationResult.fail(validatorId: 'v', message: 'm', dimension: d),
      ValidationStatus.skip =>
        ValidationResult.skip(validatorId: 'v', message: 'm', dimension: d),
      ValidationStatus.error =>
        ValidationResult.error(validatorId: 'v', message: 'm', dimension: d),
    };

/// A run shaped the way `FlowExecutor` builds one: the steps it ran, the
/// screens it validated and the API assertions it made, each kept apart.
RunResult _executed({
  required List<StepOutcome> steps,
  List<ValidationResult> screenResults = const [],
  List<ApiExpectationOutcome> apiChecks = const [],
}) =>
    RunResult(
      flowName: 'f',
      appId: 'a',
      device: 'd',
      startedAt: DateTime.utc(2026, 9, 15),
      duration: Duration.zero,
      steps: steps,
      screens: screenResults.isEmpty
          ? const []
          : [
              ScreenResult(
                screenId: '/s',
                report: ValidationReport(screenResults),
              ),
            ],
      apiChecks: apiChecks,
    );

/// The step the assertions below are about, as a flow would declare it.
const ExpectApiStep _assertion = ExpectApiStep(
  endpoint: ApiEndpoint('GET', '/products/123'),
  status: 200,
);

/// The outcome `FlowExecutor` records for [_assertion].
///
/// Description and kind are taken from the step itself rather than
/// written out, so this cannot drift from what the executor stores.
StepOutcome _assertionStep(StepStatus status, {String? detail}) => StepOutcome(
      description: _assertion.describe(),
      kind: stepKindOf(_assertion),
      status: status,
      durationMs: 5,
      detail: detail,
    );

/// What `FlowExecutor` puts in `detail` when the assertion does not hold:
/// the thrown `StateError`'s own words.
const String _assertionDetail =
    'the API assertion on GET /products/123 did not hold: '
    'answered 500, expected 200';

const ApiExpectationOutcome _unsatisfied = ApiExpectationOutcome(
  endpoint: 'GET /products/123',
  failures: ['answered 500, expected 200'],
  status: 500,
);

const ApiExpectationOutcome _satisfied = ApiExpectationOutcome(
  endpoint: 'GET /products/123',
  failures: [],
  status: 200,
);

RunResult _run(List<ValidationResult> results, {List<StepOutcome>? steps}) =>
    RunResult(
      flowName: 'f',
      appId: 'a',
      device: 'd',
      startedAt: DateTime.utc(2026, 9, 15),
      duration: Duration.zero,
      steps: steps ??
          const [
            StepOutcome(
              description: 'launch the app',
              kind: StepKind.launchApp,
              status: StepStatus.ok,
              durationMs: 1,
            ),
          ],
      screens: [
        ScreenResult(screenId: '/s', report: ValidationReport(results)),
      ],
    );

void main() {
  group('precedence within a dimension', () {
    test('error outranks fail', () {
      final run = _run([
        _r(ValidationStatus.fail, ValidationDimension.api),
        _r(ValidationStatus.error, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.api),
      ]);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.error);
    });

    test('fail outranks pass', () {
      final run = _run([
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.fail, ValidationDimension.api),
      ]);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.fail);
    });

    test('pass outranks skip', () {
      final run = _run([
        _r(ValidationStatus.skip, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.api),
      ]);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.pass);
    });

    test('a dimension with nothing in it is SKIP, never PASS', () {
      final run = _run([_r(ValidationStatus.pass, ValidationDimension.ui)]);
      expect(run.dimensions[ValidationDimension.figma]!.status,
          ValidationStatus.skip);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.skip);
      expect(run.dimensions[ValidationDimension.figma]!.reason,
          contains('nothing was checked'));
    });

    test('a dimension that only skipped is SKIP, never PASS', () {
      final run = _run([
        _r(ValidationStatus.skip, ValidationDimension.figma),
        _r(ValidationStatus.skip, ValidationDimension.figma),
      ]);
      expect(run.dimensions[ValidationDimension.figma]!.status,
          ValidationStatus.skip);
    });

    test('every dimension is always present in the block', () {
      final run = _run([_r(ValidationStatus.pass, ValidationDimension.ui)]);
      expect(run.dimensions.keys, containsAll(ValidationDimension.values));
    });

    test('the counts add up', () {
      final run = _run([
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.fail, ValidationDimension.api),
      ]);
      final counts = run.dimensions[ValidationDimension.api]!.counts;
      expect(counts['pass'], 2);
      expect(counts['fail'], 1);
      expect(counts['error'], 0);
      expect(counts['skip'], 0);
    });
  });

  group('the milestone combinations', () {
    test('API PASS + Figma PASS + UI PASS -> overall PASS', () {
      final run = _run([
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.figma),
        _r(ValidationStatus.pass, ValidationDimension.ui),
      ]);
      expect(run.overall, ValidationStatus.pass);
      expect(run.passed, isTrue);
    });

    test('API FAIL + Figma PASS + UI PASS -> overall FAIL', () {
      final run = _run([
        _r(ValidationStatus.fail, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.figma),
        _r(ValidationStatus.pass, ValidationDimension.ui),
      ]);
      expect(run.dimensions[ValidationDimension.figma]!.status,
          ValidationStatus.pass);
      expect(run.dimensions[ValidationDimension.ui]!.status,
          ValidationStatus.pass);
      expect(run.overall, ValidationStatus.fail);
      expect(run.passed, isFalse);
    });

    test('API PASS + Figma FAIL + UI PASS -> overall FAIL', () {
      final run = _run([
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.fail, ValidationDimension.figma),
        _r(ValidationStatus.pass, ValidationDimension.ui),
      ]);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.pass);
      expect(run.overall, ValidationStatus.fail);
    });

    test('a passing dimension cannot hide a failing one', () {
      for (final failing in ValidationDimension.values) {
        final run = _run([
          for (final d in ValidationDimension.values)
            _r(d == failing ? ValidationStatus.fail : ValidationStatus.pass, d),
        ]);
        expect(run.overall, ValidationStatus.fail,
            reason: 'a FAIL in ${failing.wire} was hidden');
      }
    });

    test('a passing dimension cannot hide an errored one', () {
      for (final erroring in ValidationDimension.values) {
        final run = _run([
          for (final d in ValidationDimension.values)
            _r(d == erroring ? ValidationStatus.error : ValidationStatus.pass,
                d),
        ]);
        expect(run.overall, ValidationStatus.error,
            reason: 'an ERROR in ${erroring.wire} was hidden');
      }
    });
  });

  group('the equivalence that pins E-03 and E-04', () {
    test('passed is true exactly when overall does not block a pass', () {
      for (final a in ValidationStatus.values) {
        for (final b in ValidationStatus.values) {
          final run = _run([
            _r(a, ValidationDimension.api),
            _r(b, ValidationDimension.figma),
          ]);
          final blocks = run.overall == ValidationStatus.fail ||
              run.overall == ValidationStatus.error;
          expect(run.passed, !blocks,
              reason: 'api=${a.wire} figma=${b.wire} gave '
                  'overall=${run.overall.wire}');
        }
      }
    });

    test('a failed step lands in UI and blocks the overall verdict', () {
      final run = _run(
        [_r(ValidationStatus.pass, ValidationDimension.api)],
        steps: const [
          StepOutcome(
            description: 'tap "home.open_product"',
            kind: StepKind.tap,
            status: StepStatus.failed,
            durationMs: 5,
          ),
        ],
      );
      expect(run.dimensions[ValidationDimension.ui]!.status,
          ValidationStatus.fail);
      expect(run.overall, ValidationStatus.fail);
      expect(run.passed, isFalse);
    });

    test('an unsatisfied expectApi lands in API', () {
      final run = RunResult(
        flowName: 'f',
        appId: 'a',
        device: 'd',
        startedAt: DateTime.utc(2026, 9, 15),
        duration: Duration.zero,
        steps: const [
          StepOutcome(
            description: 'launch the app',
            kind: StepKind.launchApp,
            status: StepStatus.ok,
            durationMs: 1,
          ),
        ],
        screens: const [],
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: 'GET /products/123',
            failures: ['answered 500, expected 200'],
          ),
        ],
      );
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.fail);
      expect(run.overall, ValidationStatus.fail);
      expect(run.passed, isFalse);
    });
  });

  // An `expectApi` produces *two* results, and the two tests above check
  // one each in isolation. Neither pins the shape the executor actually
  // writes, where both exist at once: `_expectApi` appends the outcome to
  // `apiChecks` and then throws, so the step is recorded as failed too.
  //
  // That is deliberate, and §6.2 of the E-06 document now says so: the
  // execution outcome of a user-written step is UI evidence, and the
  // finding is stamped with the source of truth it was measured against.
  // It held by construction and nothing pinned it, which is what these
  // tests are for.
  group('a step that measures produces two results, not one', () {
    RunResult failed() => _executed(
          steps: [_assertionStep(StepStatus.failed, detail: _assertionDetail)],
          apiChecks: const [_unsatisfied],
        );

    test('one failed expectApi is a UI failure and an API failure', () {
      final run = failed();

      expect(run.dimensions[ValidationDimension.ui]!.status,
          ValidationStatus.fail);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.fail);
      expect(run.overall, ValidationStatus.fail);
      expect(run.passed, isFalse);
    });

    test('each dimension gives the reason its own producer recorded', () {
      final run = failed();
      final ui = run.dimensions[ValidationDimension.ui]!;
      final api = run.dimensions[ValidationDimension.api]!;

      // The step's own detail - the thrown error's words.
      expect(ui.reason, _assertionDetail);
      // The evaluator's own words, through `ApiExpectationOutcome`.
      expect(api.reason, contains('answered 500, expected 200'));
      expect(api.reason, isNot(ui.reason));
    });

    test('one result lands in each, and nowhere else', () {
      final run = failed();

      expect(run.dimensions[ValidationDimension.ui]!.counts['fail'], 1);
      expect(run.dimensions[ValidationDimension.api]!.counts['fail'], 1);
      expect(run.dimensions[ValidationDimension.figma]!.status,
          ValidationStatus.skip);
      expect(run.dimensions[ValidationDimension.visual]!.status,
          ValidationStatus.skip);
    });

    test('a satisfied expectApi passes in both', () {
      final run = _executed(
        steps: [_assertionStep(StepStatus.ok)],
        apiChecks: const [_satisfied],
      );

      expect(run.dimensions[ValidationDimension.ui]!.status,
          ValidationStatus.pass);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.pass);
      expect(run.overall, ValidationStatus.pass);
      expect(run.passed, isTrue);
    });

    test('an API failure does not need a UI failure to be reported', () {
      // The contrast that shows the dual contribution is about the step
      // having an execution outcome, not about the dimensions being
      // wired together.
      //
      // A model-level case rather than an executor-shaped one: the
      // executor cannot produce it, because the only writer of
      // `apiChecks` throws when an assertion does not hold. It is here
      // because the dimensions must stay independent of one another.
      final run = _executed(
        steps: const [
          StepOutcome(
            description: 'tap "home.open_product"',
            kind: StepKind.tap,
            status: StepStatus.ok,
            durationMs: 5,
          ),
        ],
        apiChecks: const [_unsatisfied],
      );

      expect(run.dimensions[ValidationDimension.ui]!.status,
          ValidationStatus.pass);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.fail);
      expect(run.overall, ValidationStatus.fail);
    });

    test('a failed validateScreen keeps its finding in its own dimension',
        () {
      // The same shape, one layer along. `_validate` throws when the
      // report does not pass, so the step is failed *and* the screen
      // carries the finding - and the finding keeps the dimension its
      // validator stamped, rather than being pulled into UI with it.
      const validate = ValidateScreenStep();
      final run = _executed(
        steps: [
          StepOutcome(
            description: validate.describe(),
            kind: stepKindOf(validate),
            status: StepStatus.failed,
            durationMs: 30,
            detail: 'validation failed: 1 failed, 0 errored',
          ),
        ],
        screenResults: [
          _r(ValidationStatus.fail, ValidationDimension.figma),
          _r(ValidationStatus.pass, ValidationDimension.api),
        ],
      );

      expect(run.dimensions[ValidationDimension.ui]!.status,
          ValidationStatus.fail);
      expect(run.dimensions[ValidationDimension.figma]!.status,
          ValidationStatus.fail);
      // The API check on that screen passed, and says so independently.
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.pass);
      expect(run.overall, ValidationStatus.fail);
      expect(run.passed, isFalse);
    });
  });

  test('the block reaches the JSON, and the schema version moves', () {
    final json = _run([
      _r(ValidationStatus.pass, ValidationDimension.api),
    ]).toJson();
    expect(json['resultSchemaVersion'], '1.6');
    final dims = json['dimensions']! as Map<String, Object?>;
    expect((dims['api']! as Map)['status'], 'pass');
    expect((dims['figma']! as Map)['status'], 'skip');
    expect(json['overall'], 'pass');
    // Nothing that existed at 1.0 changed meaning.
    expect(json['passed'], isTrue);
  });
}
