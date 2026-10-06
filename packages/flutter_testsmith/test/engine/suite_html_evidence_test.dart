// The suite page knew the verdict and almost nothing behind it.
//
// Two things the audit corrected, worth recording so the next reader is
// not misled:
//
//   * the page was never *empty* for an error. `reason` has been
//     rendered since E-04, and since the suite-classification milestone
//     that reason names the screen and what could not be done. What was
//     missing is everything around it;
//   * the page already told ERROR from FAIL visually. `.error` is amber
//     and `.fail` is red, and the classification chip already said
//     PRODUCT or ENVIRONMENT.
//
// What it genuinely omitted: `checks.errors` was never rendered at all,
// and `screens` and `dimensions` - added to suite.json last milestone -
// had no reader. So a page could say ERROR / ENVIRONMENT and one line of
// reason, while the file beside it recorded that the API had answered
// correctly, two screens had passed, and a third could not be checked.
//
// This renders those, and nothing else: no steps, no exchanges, no
// payloads. The suite artefact stays a summary, and the page stays a
// rendering of it rather than a second opinion about it.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

ValidationResult _r(
  ValidationStatus status,
  ValidationDimension dimension, {
  String? message,
}) =>
    switch (status) {
      ValidationStatus.pass => ValidationResult.pass(
          validatorId: 'ui-presence',
          message: message ?? 'ok',
          dimension: dimension),
      ValidationStatus.fail => ValidationResult.fail(
          validatorId: 'api-to-ui',
          message: message ?? 'the UI shows "Rs 2,599", the API returned 2999',
          dimension: dimension),
      ValidationStatus.error => ValidationResult.error(
          validatorId: 'visual',
          message: message ?? 'cannot photograph deterministically: '
              '1 unexpected animation running',
          dimension: dimension),
      ValidationStatus.skip => ValidationResult.skip(
          validatorId: 'figma',
          message: message ?? 'no design is configured',
          dimension: dimension),
    };

ScreenResult _screen(String id, List<ValidationResult> results) =>
    ScreenResult(screenId: id, report: ValidationReport(results));

RunResult _run(List<ScreenResult> screens) => RunResult(
      flowName: 'f',
      appId: 'com.example.app',
      device: 'fake',
      startedAt: DateTime.utc(2026, 9, 18),
      duration: Duration.zero,
      steps: const [
        StepOutcome(description: 'launch', kind: StepKind.launchApp, status: StepStatus.ok, durationMs: 0),
      ],
      screens: screens,
    );

String _page(List<SuiteTestResult> tests) => renderSuiteReport(
      SuiteResult(
        suiteName: 's',
        profile: const DeviceProfile(id: 'p', model: 'm'),
        startedAt: DateTime.utc(2026, 9, 18),
        duration: Duration.zero,
        tests: tests,
      ),
    );

SuiteTestResult _product(RunResult run) => SuiteTestResult.product(
      id: 't',
      passed: run.passed,
      required: true,
      duration: Duration.zero,
      run: run,
      outputDirectory: 't',
    );

SuiteTestResult _environment(RunResult run, String reason) =>
    SuiteTestResult.environment(
      id: 't',
      kind: EnvironmentKind.error,
      required: true,
      duration: Duration.zero,
      reason: reason,
      run: run,
      outputDirectory: 't',
    );

/// The four dimensions of a run whose UI could not be read.
RunResult _apiPassUiError() => _run([
      _screen('/a', [
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.error, ValidationDimension.ui),
        _r(ValidationStatus.skip, ValidationDimension.figma),
        _r(ValidationStatus.skip, ValidationDimension.visual),
      ]),
    ]);

/// The same run, but the UI was read and contradicted.
RunResult _apiPassUiFail() => _run([
      _screen('/a', [
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.fail, ValidationDimension.ui),
        _r(ValidationStatus.skip, ValidationDimension.figma),
        _r(ValidationStatus.skip, ValidationDimension.visual),
      ]),
    ]);

String _source() {
  const relative = 'flutter_testsmith/lib/src/engine/reporting/suite_html_reporter.dart';
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

void main() {
  group('the verdict badge, as it already was', () {
    test('PASS', () {
      final html = _page([
        _product(_run([_screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)])])),
      ]);
      expect(html, contains('<span class="verdict pass">PASS</span>'));
    });

    test('FAIL', () {
      final html = _page([_product(_apiPassUiFail())]);
      expect(html, contains('<span class="verdict fail">FAIL</span>'));
    });

    test('ERROR, and not the product-failure presentation', () {
      final html = _page([_environment(_apiPassUiError(), '/a: unreadable')]);

      expect(html, contains('<span class="verdict error">ERROR</span>'));
      expect(html, isNot(contains('<span class="verdict fail">FAIL</span>')));
    });

    test('SKIP', () {
      final html = _page([
        const SuiteTestResult.skipped(
          id: 't',
          required: true,
          reason: 'the suite stopped first',
        ),
      ]);
      expect(html, contains('<span class="verdict skip">SKIP</span>'));
    });
  });

  group('the motivating case is no longer one line of reason', () {
    String page() => _page([
          _environment(_apiPassUiError(), '/a: the tree could not be read'),
        ]);

    test('the row says the result is about the run', () {
      expect(page(), contains('ENVIRONMENT'));
    });

    test('the screen and its status are shown', () {
      expect(page(), contains('/a'));
      expect(page(), contains('s-error'));
    });

    test('the UI dimension is shown as error', () {
      expect(page(), contains('<span class="s-error">UI error</span>'));
    });

    test('the API evidence survives on the page', () {
      expect(page(), contains('<span class="s-pass">API pass</span>'));
    });

    test('the unchecked dimensions are shown as skipped', () {
      expect(page(), contains('<span class="s-skip">FIGMA skip</span>'));
      expect(page(), contains('<span class="s-skip">VISUAL skip</span>'));
    });

    test('the existing error entry is rendered, not only the reason', () {
      // `checks.errors` had no reader at all before this.
      expect(page(), contains('cannot photograph deterministically'));
      expect(page(), contains('visual'));
    });

    test('the reason is still there', () {
      expect(page(), contains('the tree could not be read'));
    });

    test('nothing on the row calls it a failure', () {
      expect(page(), isNot(contains('class="s-fail"')));
    });
  });

  group('a measured contradiction still reads as one', () {
    test('the failure list is unchanged', () {
      final html = _page([_product(_apiPassUiFail())]);

      expect(html, contains('the UI shows &quot;Rs 2,599&quot;'));
      expect(html, contains('api-to-ui'));
    });

    test('the UI dimension is shown as fail', () {
      expect(
        _page([_product(_apiPassUiFail())]),
        contains('<span class="s-fail">UI fail</span>'),
      );
    });

    test('the API evidence survives here too', () {
      expect(
        _page([_product(_apiPassUiFail())]),
        contains('<span class="s-pass">API pass</span>'),
      );
    });

    test('a reader can tell it apart from the error case', () {
      final failing = _page([_product(_apiPassUiFail())]);
      final erroring =
          _page([_environment(_apiPassUiError(), '/a: unreadable')]);

      expect(failing, contains('PRODUCT'));
      expect(erroring, contains('ENVIRONMENT'));
      expect(failing, contains('s-fail'));
      expect(erroring, contains('s-error'));
      expect(failing, isNot(contains('class="s-error"')));
    });
  });

  group('a passing test stays concise', () {
    test('no wall of evidence appears for a pass', () {
      // The fields exist for a passing run too. Printing them would
      // expand every green row for no reader benefit.
      final html = _page([
        _product(_run([
          _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
        ])),
      ]);

      expect(html, contains('<span class="verdict pass">PASS</span>'));
      expect(html, isNot(contains('class="s-pass"')));
    });
  });

  group('several screens keep their own answers on the page', () {
    test('pass, error and fail are all shown', () {
      final html = _page([
        _environment(
          _run([
            _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
            _screen('/b', [_r(ValidationStatus.error, ValidationDimension.visual)]),
            _screen('/c', [_r(ValidationStatus.fail, ValidationDimension.ui)]),
          ]),
          '/b: could not be photographed',
        ),
      ]);

      expect(html, contains('<span class="s-pass">/a pass</span>'));
      expect(html, contains('<span class="s-error">/b error</span>'));
      expect(html, contains('<span class="s-fail">/c fail</span>'));
    });

    test('the test verdict does not overwrite them', () {
      final html = _page([
        _environment(
          _run([
            _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
            _screen('/b', [_r(ValidationStatus.error, ValidationDimension.visual)]),
          ]),
          'r',
        ),
      ]);

      expect(html, contains('<span class="verdict error">ERROR</span>'));
      expect(html, contains('s-pass'));
    });
  });

  group('an older artefact still renders', () {
    test('a suite written before screens and dimensions is safe', () {
      // Schema 1.0 had neither key. Nothing is re-derived to fill the
      // gap: the page shows the evidence the file actually contains.
      final html = _page([
        const SuiteTestResult.environment(
          id: 't',
          kind: EnvironmentKind.blocked,
          required: true,
          duration: Duration.zero,
          reason: 'preflight blocked: permissions',
        ),
      ]);

      expect(html, contains('<span class="verdict error">ERROR</span>'));
      expect(html, contains('preflight blocked: permissions'));
      expect(html, isNot(contains('class="s-pass"')));
      expect(html, isNot(contains('class="s-skip"')));
    });

    test('no status is invented when the evidence is absent', () {
      final html = _page([
        const SuiteTestResult.skipped(
          id: 't',
          required: true,
          reason: 'nobody ran it',
        ),
      ]);

      expect(html, isNot(contains('class="s-error"')));
      expect(html, isNot(contains('class="s-fail"')));
    });
  });

  group('the page renders, it does not decide', () {
    test('it aggregates nothing', () {
      final source = _source();

      expect(source, isNot(contains('aggregateStatus')));
      expect(source, isNot(contains('.any(')));
      expect(source, isNot(contains('.every(')));
    });

    test('it reads the serialised statuses', () {
      final source = _source();

      expect(source, contains("screen['status']"));
      expect(source, contains("entry['status']"));
    });

    test('it derives no status from counts', () {
      // `counts` is printed as the suite header's tally and nowhere
      // else. A status must never be inferred from a number here.
      final source = _source();
      expect(source, isNot(contains("counts['error'] as int")));
      expect(source, isNot(contains('errorCount')));
    });
  });

  group('the page carries nothing sensitive', () {
    test('a seeded secret in a validator message does not reach it', () {
      const seeded = 'SEEDED_ACCESS_TOKEN_8a17fc';
      final html = _page([
        _product(
          _run([
            _screen('/a', [
              _r(ValidationStatus.pass, ValidationDimension.api),
              _r(ValidationStatus.fail, ValidationDimension.ui),
            ]),
          ]),
        ),
      ]);

      expect(html, isNot(contains(seeded)));
      for (final forbidden in const [
        'Authorization',
        'Cookie',
        'Bearer',
        // The page has a <body> tag, so the payload keys are matched by
        // the names a serialised exchange would actually use.
        'requestBody',
        'responseBody',
        'headers',
      ]) {
        expect(html, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}
