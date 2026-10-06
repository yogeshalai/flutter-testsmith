// A result with no dimension was invisible to the verdict that quoted it.
//
// `verdictFor` filters `r.dimension == dimension`, and `RunResult.overall`
// aggregates those four buckets. So a result carrying no dimension sat in
// `report.results` - counted, printed, serialised - and belonged to no
// bucket at all. A real FAIL or ERROR could be present in the raw
// evidence and absent from every dimension, leaving OVERALL free to say
// PASS or SKIP about a screen that had plainly reported otherwise.
//
// The previous two milestones worked around it rather than fixing it:
// `runStatus` and the HTML badge both deliberately read the raw results
// instead of `overall`, precisely because `overall` could not be trusted
// to have seen everything.
//
// Nullability is not an accident, though, and the fix is not simply to
// forbid it. Of 93 result constructions in this repository, about 78
// deliberately omit the dimension: a validator says what it found and
// `runValidator` stamps the validator's own dimension onto it, once, in
// one place. Requiring it at each construction would replace one correct
// stamp with 78 literals free to drift - a weaker guarantee wearing a
// stronger type.
//
// So the invariant is enforced where it is actually stated: *entering a
// ValidationReport*. That boundary has exactly one production call site,
// and past it every consumer - dimensions, overall, reporting, suite
// classification - can trust that raw evidence and dimension evidence
// are the same evidence.
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

ValidationResult _dimensioned(
  ValidationStatus status,
  ValidationDimension dimension,
) =>
    switch (status) {
      ValidationStatus.pass => ValidationResult.pass(
          validatorId: 'v',
          message: 'satisfied',
          dimension: dimension,
        ),
      ValidationStatus.fail => ValidationResult.fail(
          validatorId: 'v',
          message: 'contradicted',
          dimension: dimension,
        ),
      ValidationStatus.error => ValidationResult.error(
          validatorId: 'v',
          message: 'could not be established',
          dimension: dimension,
        ),
      ValidationStatus.skip => ValidationResult.skip(
          validatorId: 'v',
          message: 'not configured',
          dimension: dimension,
        ),
    };

/// A result as a validator builds one: no dimension yet.
const ValidationResult _unstamped = ValidationResult.fail(
  validatorId: 'api-to-ui',
  message: 'the price does not match',
);

RunResult _run(List<ValidationResult> results, {
  List<ApiExpectationOutcome> apiChecks = const [],
}) =>
    RunResult(
      flowName: 'f',
      appId: 'a',
      device: 'd',
      startedAt: DateTime.utc(2026, 9, 18),
      duration: Duration.zero,
      steps: const [
        StepOutcome(description: 's', kind: StepKind.tap, status: StepStatus.ok, durationMs: 0),
      ],
      apiChecks: apiChecks,
      screens: [
        ScreenResult(screenId: '/s', report: ValidationReport(results)),
      ],
    );

ValidationStatus _of(RunResult run, ValidationDimension dimension) =>
    run.dimensions[dimension]!.status;

/// Every result the dimension blocks actually accounted for.
int _counted(RunResult run) => run.dimensions.values
    .expand((verdict) => verdict.counts.values)
    .fold(0, (sum, count) => sum + count);

void main() {
  group('the boundary refuses a result it could not place', () {
    test('a report will not accept an undimensioned result', () {
      expect(
        () => ValidationReport([_unstamped]),
        throwsA(isA<UndimensionedResultException>()),
      );
    });

    test('it refuses even when other results are well formed', () {
      // The dangerous shape: one good result would make the report look
      // populated while the other silently belonged nowhere.
      expect(
        () => ValidationReport([
          _dimensioned(ValidationStatus.pass, ValidationDimension.ui),
          _unstamped,
        ]),
        throwsA(isA<UndimensionedResultException>()),
      );
    });

    test('the refusal names the validator and the status', () {
      try {
        ValidationReport([_unstamped]);
        fail('an undimensioned result entered a report');
      } on UndimensionedResultException catch (error) {
        expect(error.validatorId, 'api-to-ui');
        expect(error.status, ValidationStatus.fail);
        expect('$error', contains('api-to-ui'));
      }
    });

    test('the refusal carries no message text', () {
      // A result's message can quote what a screen displayed. The
      // diagnostic needs the validator and the status and nothing else.
      try {
        ValidationReport([_unstamped]);
        fail('accepted');
      } on UndimensionedResultException catch (error) {
        expect('$error', isNot(contains('the price does not match')));
      }
    });

    test('a fully dimensioned report is accepted', () {
      expect(
        ValidationReport([
          _dimensioned(ValidationStatus.pass, ValidationDimension.ui),
          _dimensioned(ValidationStatus.skip, ValidationDimension.figma),
        ]).results,
        hasLength(2),
      );
    });

    test('an empty report is accepted', () {
      expect(ValidationReport(const []).results, isEmpty);
    });
  });

  group('malformed is not a product failure and not a pass', () {
    test('it is recognised as the engine failing, not the application', () {
      // Reuses the existing vocabulary rather than inventing a
      // validation-specific taxonomy: the run could not establish a
      // trustworthy observation, which is what this predicate means.
      expect(
        isInfrastructureFailure(
          const UndimensionedResultException(
            validatorId: 'v',
            status: ValidationStatus.fail,
          ),
        ),
        isTrue,
      );
    });

    test('it is not a StateError, so it cannot be read as an assertion', () {
      expect(
        const UndimensionedResultException(
          validatorId: 'v',
          status: ValidationStatus.fail,
        ),
        isNot(isA<StateError>()),
      );
    });
  });

  group('the stamp that makes results legitimate still works', () {
    test('runValidator stamps the validator dimension onto every result', () {
      // This is why the dimension is nullable at construction: one
      // stamp, in one place, from the validator that knows.
      const validator = UiPresenceValidator();
      expect(validator.dimension, ValidationDimension.ui);
      expect(_unstamped.dimension, isNull);
      expect(
        _unstamped.inDimension(validator.dimension).dimension,
        ValidationDimension.ui,
      );
    });

    test('an explicit dimension is never overwritten', () {
      // A validator whose default is api still emits ui results when the
      // reason it could not compare was that the UI could not be read.
      final explicit =
          _dimensioned(ValidationStatus.error, ValidationDimension.ui);

      expect(
        explicit.inDimension(ValidationDimension.api).dimension,
        ValidationDimension.ui,
      );
    });
  });

  group('every status stays visible in its own dimension', () {
    for (final status in ValidationStatus.values) {
      test('a ${status.wire} is counted in the dimension it belongs to', () {
        final run = _run([_dimensioned(status, ValidationDimension.figma)]);

        expect(_of(run, ValidationDimension.figma), status);
      });
    }

    test('a SKIP is still SKIP, not a missing dimension', () {
      final run = _run([_dimensioned(ValidationStatus.skip, ValidationDimension.visual)]);

      expect(_of(run, ValidationDimension.visual), ValidationStatus.skip);
      expect(run.dimensions[ValidationDimension.visual]!.counts['skip'], 1);
    });
  });

  group('no result disappears between raw evidence and the blocks', () {
    test('every result in the report is accounted for by a dimension', () {
      final results = [
        _dimensioned(ValidationStatus.pass, ValidationDimension.ui),
        _dimensioned(ValidationStatus.fail, ValidationDimension.ui),
        _dimensioned(ValidationStatus.error, ValidationDimension.visual),
        _dimensioned(ValidationStatus.skip, ValidationDimension.figma),
      ];
      final run = _run(results);

      // One step (ui) plus the four screen results. Nothing is filtered
      // into nowhere.
      expect(_counted(run), results.length + 1);
    });

    test('api checks are accounted for too', () {
      final run = _run(
        [_dimensioned(ValidationStatus.pass, ValidationDimension.ui)],
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: 'GET /a',
            status: 200,
            failures: [],
          ),
        ],
      );

      // 1 step + 1 api check + 1 screen result.
      expect(_counted(run), 3);
    });

    test('overall agrees with the raw results', () {
      final results = [
        _dimensioned(ValidationStatus.pass, ValidationDimension.api),
        _dimensioned(ValidationStatus.error, ValidationDimension.visual),
      ];
      final run = _run(results);

      expect(
        run.overall,
        aggregateStatus([
          ...results.map((r) => r.status),
          ValidationStatus.pass, // the ok step
        ]),
      );
    });
  });

  group('several dimensions at once', () {
    test('UI PASS and API PASS', () {
      final run = _run([
        _dimensioned(ValidationStatus.pass, ValidationDimension.ui),
        _dimensioned(ValidationStatus.pass, ValidationDimension.api),
      ]);

      expect(_of(run, ValidationDimension.ui), ValidationStatus.pass);
      expect(_of(run, ValidationDimension.api), ValidationStatus.pass);
      expect(run.overall, ValidationStatus.pass);
    });

    test('UI FAIL and API PASS', () {
      final run = _run([
        _dimensioned(ValidationStatus.fail, ValidationDimension.ui),
        _dimensioned(ValidationStatus.pass, ValidationDimension.api),
      ]);

      expect(_of(run, ValidationDimension.ui), ValidationStatus.fail);
      expect(_of(run, ValidationDimension.api), ValidationStatus.pass);
      expect(run.overall, ValidationStatus.fail);
    });

    test('UI ERROR and API PASS keeps the API evidence', () {
      final run = _run([
        _dimensioned(ValidationStatus.error, ValidationDimension.ui),
        _dimensioned(ValidationStatus.pass, ValidationDimension.api),
      ]);

      expect(_of(run, ValidationDimension.ui), ValidationStatus.error);
      expect(_of(run, ValidationDimension.api), ValidationStatus.pass);
      expect(run.overall, ValidationStatus.error);
    });

    test('UI PASS and API ERROR', () {
      final run = _run([
        _dimensioned(ValidationStatus.pass, ValidationDimension.ui),
        _dimensioned(ValidationStatus.error, ValidationDimension.api),
      ]);

      expect(_of(run, ValidationDimension.api), ValidationStatus.error);
      expect(run.overall, ValidationStatus.error);
    });

    test('UI FAIL and FIGMA ERROR', () {
      final run = _run([
        _dimensioned(ValidationStatus.fail, ValidationDimension.ui),
        _dimensioned(ValidationStatus.error, ValidationDimension.figma),
      ]);

      expect(_of(run, ValidationDimension.ui), ValidationStatus.fail);
      expect(_of(run, ValidationDimension.figma), ValidationStatus.error);
      expect(run.overall, ValidationStatus.error);
    });

    test('all four dimensions at once, with a FAIL', () {
      final run = _run([
        _dimensioned(ValidationStatus.fail, ValidationDimension.ui),
        _dimensioned(ValidationStatus.pass, ValidationDimension.api),
        _dimensioned(ValidationStatus.skip, ValidationDimension.figma),
        _dimensioned(ValidationStatus.skip, ValidationDimension.visual),
      ]);

      expect(_of(run, ValidationDimension.ui), ValidationStatus.fail);
      expect(_of(run, ValidationDimension.api), ValidationStatus.pass);
      expect(_of(run, ValidationDimension.figma), ValidationStatus.skip);
      expect(_of(run, ValidationDimension.visual), ValidationStatus.skip);
      expect(run.overall, ValidationStatus.fail);
    });

    test('all four dimensions at once, with an ERROR', () {
      final run = _run([
        _dimensioned(ValidationStatus.error, ValidationDimension.ui),
        _dimensioned(ValidationStatus.pass, ValidationDimension.api),
        _dimensioned(ValidationStatus.skip, ValidationDimension.figma),
        _dimensioned(ValidationStatus.skip, ValidationDimension.visual),
      ]);

      expect(_of(run, ValidationDimension.ui), ValidationStatus.error);
      expect(_of(run, ValidationDimension.api), ValidationStatus.pass);
      expect(run.overall, ValidationStatus.error);
    });
  });

  group('the wire contract does not move', () {
    test('a result still serialises its dimension', () {
      final json =
          _dimensioned(ValidationStatus.fail, ValidationDimension.api).toJson();

      expect(json['dimension'], ValidationDimension.api.wire);
    });

    test('the report keys are unchanged', () {
      expect(
        ValidationReport([
          _dimensioned(ValidationStatus.pass, ValidationDimension.ui),
        ]).toJson().keys.toSet(),
        {'passed', 'counts', 'results'},
      );
    });

    test('the result schema version is unchanged', () {
      expect(
        _run([_dimensioned(ValidationStatus.pass, ValidationDimension.ui)])
            .toJson()['resultSchemaVersion'],
        '1.6',
      );
    });
  });
}
