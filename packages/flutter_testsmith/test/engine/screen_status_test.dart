// A screen's verdict existed only while it was being printed.
//
// The run level got `overall` at schema 1.1 and the last milestone made
// it the single source of truth. The screen level never got the same
// treatment: `ScreenResult.toJson` emitted `validation.passed` and four
// counts, and the CLI computed `screenStatus(report)` at render time.
//
// So anything reading `result.json` - CI, a dashboard, the HTML page -
// had to re-derive PASS / FAIL / ERROR / SKIP for itself, from counts,
// with the precedence rule copied out by hand. That is the same
// duplicate-aggregation shape just removed from the run level, one
// level down, and it is worse here because the second implementation
// lives outside this repository entirely.
//
// The status is now a property of the screen, derived once from the
// results and serialised. There is no second answer to find.
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
          validatorId: 'v',
          message: 'could not be established',
          dimension: dimension),
      ValidationStatus.skip => ValidationResult.skip(
          validatorId: 'v', message: 'not configured', dimension: dimension),
    };

ScreenResult _screen(String id, List<ValidationResult> results) =>
    ScreenResult(screenId: id, report: ValidationReport(results));

RunResult _run(List<ScreenResult> screens) => RunResult(
      flowName: 'f',
      appId: 'a',
      device: 'd',
      startedAt: DateTime.utc(2026, 9, 18),
      duration: Duration.zero,
      steps: const [
        StepOutcome(description: 'launch', kind: StepKind.launchApp, status: StepStatus.ok, durationMs: 0),
      ],
      screens: screens,
    );

/// Reads a source file by its path under `packages/`.
///
/// Two layouts, because the suite is launched from both: the repository
/// root, and the package directory - from which a sibling package, and
/// this one, are one level up.
String _source(String underPackages) {
  for (final candidate in ['packages/$underPackages', '../$underPackages']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $underPackages');
}

void main() {
  group('a screen has a status of its own', () {
    test('everything satisfied is PASS', () {
      expect(
        _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]).status,
        ValidationStatus.pass,
      );
    });

    test('a contradicted measurement is FAIL', () {
      expect(
        _screen('/a', [
          _r(ValidationStatus.pass, ValidationDimension.ui),
          _r(ValidationStatus.fail, ValidationDimension.api),
        ]).status,
        ValidationStatus.fail,
      );
    });

    test('a measurement that could not be established is ERROR', () {
      expect(
        _screen('/a', [
          _r(ValidationStatus.pass, ValidationDimension.ui),
          _r(ValidationStatus.error, ValidationDimension.visual),
        ]).status,
        ValidationStatus.error,
      );
    });

    test('nothing checked is SKIP', () {
      expect(
        _screen('/a', [_r(ValidationStatus.skip, ValidationDimension.figma)])
            .status,
        ValidationStatus.skip,
      );
    });

    test('a screen with no results at all is SKIP', () {
      expect(_screen('/a', const []).status, ValidationStatus.skip);
    });

    test('ERROR outranks FAIL, unchanged', () {
      expect(
        _screen('/a', [
          _r(ValidationStatus.fail, ValidationDimension.ui),
          _r(ValidationStatus.error, ValidationDimension.figma),
        ]).status,
        ValidationStatus.error,
      );
    });

    test('it is exactly the aggregation of its own results', () {
      // The rule in section 10: no filtering, no second algorithm.
      final results = [
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.error, ValidationDimension.ui),
        _r(ValidationStatus.skip, ValidationDimension.figma),
      ];
      final screen = _screen('/a', results);

      expect(
        screen.status,
        aggregateStatus(results.map((r) => r.status)),
      );
    });
  });

  group('the binary field is untouched', () {
    test('passed is true for a passing screen', () {
      expect(
        _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)])
            .report
            .passed,
        isTrue,
      );
    });

    test('passed is false for a failing screen', () {
      expect(
        _screen('/a', [_r(ValidationStatus.fail, ValidationDimension.ui)])
            .report
            .passed,
        isFalse,
      );
    });

    test('passed is false for an erroring screen', () {
      expect(
        _screen('/a', [_r(ValidationStatus.error, ValidationDimension.ui)])
            .report
            .passed,
        isFalse,
      );
    });

    test('a skipped check still passes the report', () {
      expect(
        _screen('/a', [_r(ValidationStatus.skip, ValidationDimension.figma)])
            .report
            .passed,
        isTrue,
      );
    });
  });

  group('screens keep their own answers', () {
    test('an erroring screen beside a passing one', () {
      final run = _run([
        _screen('/a', [_r(ValidationStatus.error, ValidationDimension.ui)]),
        _screen('/b', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
      ]);

      expect(run.screens[0].status, ValidationStatus.error);
      expect(run.screens[1].status, ValidationStatus.pass);
      expect(run.overall, ValidationStatus.error);
    });

    test('a failing screen beside an erroring one', () {
      final run = _run([
        _screen('/a', [_r(ValidationStatus.fail, ValidationDimension.ui)]),
        _screen('/b', [_r(ValidationStatus.error, ValidationDimension.visual)]),
      ]);

      expect(run.screens[0].status, ValidationStatus.fail);
      expect(run.screens[1].status, ValidationStatus.error);
      expect(run.overall, ValidationStatus.error);
    });

    test('every screen passing gives a passing run', () {
      final run = _run([
        _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
        _screen('/b', [_r(ValidationStatus.pass, ValidationDimension.api)]),
      ]);

      expect(run.screens.every((s) => s.status == ValidationStatus.pass),
          isTrue);
      expect(run.overall, ValidationStatus.pass);
    });

    test('one erroring screen errors the run without erasing the others', () {
      final run = _run([
        _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
        _screen('/b', [_r(ValidationStatus.error, ValidationDimension.visual)]),
        _screen('/c', [_r(ValidationStatus.pass, ValidationDimension.api)]),
      ]);

      expect(run.overall, ValidationStatus.error);
      expect(run.screens[0].status, ValidationStatus.pass);
      expect(run.screens[2].status, ValidationStatus.pass);
    });
  });

  group('the screen carries its status on the wire', () {
    test('the status is serialised', () {
      final json =
          _screen('/a', [_r(ValidationStatus.error, ValidationDimension.ui)])
              .toJson();

      expect(json['status'], ValidationStatus.error.wire);
    });

    test('it uses the spelling every other status uses', () {
      for (final status in ValidationStatus.values) {
        final json =
            _screen('/a', [_r(status, ValidationDimension.ui)]).toJson();
        expect(json['status'], status.wire);
      }
    });

    test('nothing that was there before was removed', () {
      final json =
          _screen('/a', [_r(ValidationStatus.fail, ValidationDimension.ui)])
              .toJson();

      expect(json.containsKey('screenId'), isTrue);
      expect(json.containsKey('validation'), isTrue);
      expect(json.containsKey('exchanges'), isTrue);
      expect(
        (json['validation']! as Map<String, Object?>)['passed'],
        isFalse,
      );
      expect((json['validation']! as Map<String, Object?>)['counts'], isNotNull);
    });

    test('the schema version records the addition', () {
      // 1.0 -> 1.1 was bumped for exactly this - two additive keys,
      // documented as leaving every earlier key's meaning intact. A new
      // key on the screen is the same situation, so it gets the same
      // treatment rather than a silent change.
      expect(_run(const []).toJson()['resultSchemaVersion'], '1.6');
    });
  });

  group('there is one screen-level aggregation, not several', () {
    test('the summary no longer exposes a screen aggregator', () {
      expect(
        _source('flutter_testsmith/lib/src/engine/reporting/e2e_summary.dart'),
        isNot(contains('screenStatus')),
      );
    });

    test('the CLI reads the screen status rather than recomputing it', () {
      final source = _source('flutter_testsmith_cli/lib/src/commands/run_command.dart');

      expect(source, isNot(contains('screenStatus(')));
      expect(source, contains('screen.status'));
    });

    test('the HTML page shows the screen status from the file', () {
      final html = const HtmlReporter().render(
        _run([
          _screen('/a', [_r(ValidationStatus.error, ValidationDimension.ui)]),
        ]).toJson(),
      );

      // The screen's own badge, beside its heading - not merely the
      // word appearing somewhere in the stylesheet.
      expect(html, contains('<span class="verdict error">ERROR</span>'));
    });

    test('a screen that passed shows its own badge too', () {
      final html = const HtmlReporter().render(
        _run([
          _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
        ]).toJson(),
      );

      expect(html, contains('<span class="verdict pass">PASS</span>'));
    });

    test('the HTML page does not re-derive it from counts', () {
      expect(
        _source('flutter_testsmith/lib/src/engine/reporting/html_reporter.dart'),
        isNot(contains("counts?['error']")),
      );
    });
  });

  group('nothing above the screen moves', () {
    test('the run verdict is unchanged', () {
      final run = _run([
        _screen('/a', [_r(ValidationStatus.fail, ValidationDimension.ui)]),
      ]);

      expect(run.overall, ValidationStatus.fail);
      expect(run.passed, isFalse);
    });

    test('an unchecked dimension is still SKIP', () {
      final run = _run([
        _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
      ]);

      expect(
        run.dimensions[ValidationDimension.figma]!.status,
        ValidationStatus.skip,
      );
    });
  });
}
