// Two answers to one question, kept apart by a bug that no longer exists.
//
// `RunResult.overall` aggregates through the dimension block. Until the
// dimension invariant became structural, a result carrying no dimension
// belonged to no block, so `overall` could be blind to evidence that was
// plainly in `report.results`. Two reporting milestones worked around
// that by computing their own run-level status from the raw results -
// `runStatus`, and the HTML badge's `_anyError`.
//
// A report now refuses an undimensioned result, so every valid result is
// in exactly one block and `overall` sees all of them. The workaround is
// not merely redundant: a second aggregator is a second thing to drift.
//
// These tests pin the equivalence before it is relied upon, and then
// guard that only one run-level aggregation remains. `screenStatus` is
// *not* removed - a screen has a status of its own, and one screen
// erroring while another passes is a real and useful distinction.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

ValidationResult _r(ValidationStatus status, ValidationDimension dimension) =>
    switch (status) {
      ValidationStatus.pass => ValidationResult.pass(
          validatorId: 'v', message: 'ok', dimension: dimension),
      ValidationStatus.fail => ValidationResult.fail(
          validatorId: 'v', message: 'wrong', dimension: dimension),
      ValidationStatus.error => ValidationResult.error(
          validatorId: 'v', message: 'could not be established',
          dimension: dimension),
      ValidationStatus.skip => ValidationResult.skip(
          validatorId: 'v', message: 'not configured', dimension: dimension),
    };

ScreenResult _screen(String id, List<ValidationResult> results) =>
    ScreenResult(screenId: id, report: ValidationReport(results));

RunResult _run({
  List<StepOutcome> steps = const [
    StepOutcome(description: 'launch', kind: StepKind.launchApp, status: StepStatus.ok, durationMs: 0),
  ],
  List<ScreenResult> screens = const [],
  List<ApiExpectationOutcome> apiChecks = const [],
}) =>
    RunResult(
      flowName: 'f',
      appId: 'a',
      device: 'd',
      startedAt: DateTime.utc(2026, 9, 18),
      duration: Duration.zero,
      steps: steps,
      screens: screens,
      apiChecks: apiChecks,
    );

String _resultLine(RunResult run) =>
    const E2eSummary().renderLines(run).firstWhere((l) => l.startsWith('RESULT:'));

String _badge(RunResult run) => const HtmlReporter().render(run.toJson());

String _source(String name) {
  for (final candidate in ['lib/src/engine/reporting/$name', 'packages/flutter_testsmith/lib/src/engine/reporting/$name']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $name');
}

/// Every run shape worth checking, with the status each must report.
final Map<String, RunResult> _shapes = {
  'all pass': _run(screens: [_screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)])]),
  'a failed step': _run(steps: const [
    StepOutcome(description: 'tap', kind: StepKind.tap, status: StepStatus.failed, durationMs: 0),
  ]),
  'a step that could not be carried out': _run(steps: const [
    StepOutcome(
      description: 'tap',
      kind: StepKind.tap,
      status: StepStatus.observationFailed,
      durationMs: 0,
    ),
  ]),
  'a screen that errored': _run(
      screens: [_screen('/a', [_r(ValidationStatus.error, ValidationDimension.visual)])]),
  'an unsatisfied api check': _run(apiChecks: const [
    ApiExpectationOutcome(
      endpoint: 'GET /a',
      status: 500,
      failures: ['expected 200'],
    ),
  ]),
  'API PASS + UI ERROR': _run(screens: [
    _screen('/a', [
      _r(ValidationStatus.pass, ValidationDimension.api),
      _r(ValidationStatus.error, ValidationDimension.ui),
    ]),
  ]),
  'API PASS + UI FAIL': _run(screens: [
    _screen('/a', [
      _r(ValidationStatus.pass, ValidationDimension.api),
      _r(ValidationStatus.fail, ValidationDimension.ui),
    ]),
  ]),
  'UI FAIL + FIGMA ERROR': _run(screens: [
    _screen('/a', [
      _r(ValidationStatus.fail, ValidationDimension.ui),
      _r(ValidationStatus.error, ValidationDimension.figma),
    ]),
  ]),
  'API PASS + FIGMA SKIP + VISUAL SKIP': _run(screens: [
    _screen('/a', [
      _r(ValidationStatus.pass, ValidationDimension.api),
      _r(ValidationStatus.skip, ValidationDimension.figma),
      _r(ValidationStatus.skip, ValidationDimension.visual),
    ]),
  ]),
  'several screens, different statuses': _run(screens: [
    _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
    _screen('/b', [_r(ValidationStatus.error, ValidationDimension.visual)]),
  ]),
  'nothing was checked at all': _run(steps: const []),
};

/// The screen status, read where it now lives.
ValidationStatus screenStatus(ValidationReport report) =>
    ScreenResult(screenId: '/s', report: report).status;

void main() {
  group('what is rendered is what the run decided', () {
    for (final entry in _shapes.entries) {
      test('${entry.key}: the summary line is the overall verdict', () {
        final run = entry.value;
        expect(
          _resultLine(run),
          'RESULT: ${run.overall.wire.toUpperCase()}',
        );
      });

      test('${entry.key}: the HTML badge is the overall verdict', () {
        final run = entry.value;
        expect(_badge(run), contains('>${run.overall.wire.toUpperCase()}<'));
      });
    }
  });

  group('the four statuses read the same everywhere', () {
    test('PASS', () {
      final run = _shapes['all pass']!;
      expect(run.overall, ValidationStatus.pass);
      expect(_resultLine(run), 'RESULT: PASS');
      expect(_badge(run), contains('verdict pass'));
    });

    test('FAIL', () {
      final run = _shapes['API PASS + UI FAIL']!;
      expect(run.overall, ValidationStatus.fail);
      expect(_resultLine(run), 'RESULT: FAIL');
      expect(_badge(run), contains('verdict fail'));
    });

    test('ERROR, and never FAIL', () {
      final run = _shapes['API PASS + UI ERROR']!;
      expect(run.overall, ValidationStatus.error);
      expect(_resultLine(run), 'RESULT: ERROR');
      expect(_badge(run), contains('verdict error'));
      expect(_badge(run), isNot(contains('verdict fail')));
    });

    test('SKIP, and never FAIL', () {
      final run = _shapes['nothing was checked at all']!;
      expect(run.overall, ValidationStatus.skip);
      expect(_resultLine(run), 'RESULT: SKIP');
      expect(_badge(run), isNot(contains('verdict fail')));
    });
  });

  group('a screen keeps a status of its own', () {
    test('one screen may error while another passes', () {
      // Not collapsed into the run verdict. A reader needs to know which
      // screen could not be checked, and the run headline cannot say.
      final run = _shapes['several screens, different statuses']!;

      expect(screenStatus(run.screens[0].report), ValidationStatus.pass);
      expect(screenStatus(run.screens[1].report), ValidationStatus.error);
      expect(run.overall, ValidationStatus.error);
    });

    test('screen-local aggregation is still available', () {
      expect(
        screenStatus(ValidationReport([
          _r(ValidationStatus.fail, ValidationDimension.ui),
        ])),
        ValidationStatus.fail,
      );
    });
  });

  group('there is one run-level aggregation, not two', () {
    test('the summary no longer computes its own run status', () {
      expect(_source('e2e_summary.dart'), isNot(contains('runStatus')));
    });

    test('the summary reads the run verdict', () {
      expect(_source('e2e_summary.dart'), contains('result.overall'));
    });

    test('the HTML badge no longer scans raw counts', () {
      final html = _source('html_reporter.dart');
      expect(html, isNot(contains('_anyError')));
      expect(html, isNot(contains("counts?['error']")));
    });

    test('the summary no longer scans the run for evidence', () {
      // `aggregateStatus` is used by `verdictFor` (per dimension), by
      // `RunResult.overall` (over dimensions) and by `screenStatus`
      // (over one screen). None of those is a second run-level answer.
      final summary = _source('e2e_summary.dart');

      expect(summary, isNot(contains('errorCount')));
      expect(summary, isNot(contains('result.screens.any')));
    });

    test('rendering a step symbol is not aggregation', () {
      // The guard above must not outlaw per-step rendering: a step still
      // shows whether it ran, failed, or could not be carried out.
      expect(
        _source('e2e_summary.dart'),
        contains('StepStatus.observationFailed =>'),
      );
    });
  });

  group('the invariant this rests on', () {
    test('an undimensioned result cannot enter a report', () {
      expect(
        () => ValidationReport(const [
          ValidationResult.fail(validatorId: 'v', message: 'm'),
        ]),
        throwsA(isA<UndimensionedResultException>()),
      );
    });

    test('so every reported result is in exactly one dimension block', () {
      final results = [
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.error, ValidationDimension.ui),
        _r(ValidationStatus.skip, ValidationDimension.figma),
      ];
      final run = _run(screens: [_screen('/a', results)]);

      final counted = run.dimensions.values
          .expand((v) => v.counts.values)
          .fold<int>(0, (sum, n) => sum + n);

      // Three screen results plus the one ok step.
      expect(counted, results.length + 1);
    });

    test('so overall sees the error', () {
      final run = _run(screens: [
        _screen('/a', [
          _r(ValidationStatus.pass, ValidationDimension.api),
          _r(ValidationStatus.error, ValidationDimension.ui),
        ]),
      ]);

      expect(run.overall, ValidationStatus.error);
    });
  });

  group('nothing else moves', () {
    test('passed stays a binary convenience', () {
      expect(_shapes['all pass']!.passed, isTrue);
      expect(_shapes['API PASS + UI FAIL']!.passed, isFalse);
      expect(_shapes['API PASS + UI ERROR']!.passed, isFalse);
      // Vacuously true, and still true. `overall` says SKIP; `passed`
      // answers a different, narrower question.
      expect(_shapes['nothing was checked at all']!.passed, isTrue);
    });

    test('the JSON shape is unchanged', () {
      final json = _shapes['all pass']!.toJson();

      expect(json.containsKey('overall'), isTrue);
      expect(json.containsKey('passed'), isTrue);
      expect(json['resultSchemaVersion'], '1.6');
    });
  });
}
