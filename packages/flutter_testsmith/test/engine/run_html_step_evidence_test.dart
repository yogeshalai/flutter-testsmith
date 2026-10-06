// The page and the terminal printed different amounts of the same run.
//
// Two gaps, both in the steps table:
//
//   * `StepOutcome.detail` has been serialised since the first schema
//     and the page never read it. It is where the executor records *why*
//     a step did not work - the thrown error's own words - so a failing
//     row said what was attempted and nothing about what happened;
//
//   * every `expectApi` step was listed as a UI step. An `expectApi`
//     produces two results by design - a UI-dimension step outcome and
//     an API-dimension check - and the terminal summary has always shown
//     the second in an API section of its own, for the reason its own
//     comment gives: "a line in both would make the report look like
//     twice as much happened".
//
// The page had no API section at all. `apiChecks` is in `result.json`
// and had no reader anywhere on the page, which is *why* the steps table
// was carrying the assertions: it was the only place they appeared.
//
// So filtering the steps alone would have deleted the API assertions
// from the page rather than moved them. Both halves are here, and the
// API section is what makes the filter a move instead of a loss.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

String _page({
  List<StepOutcome> steps = const [],
  List<ApiExpectationOutcome> apiChecks = const [],
}) =>
    const HtmlReporter().render(
      RunResult(
        flowName: 'f',
        appId: 'a',
        device: 'd',
        startedAt: DateTime.utc(2026, 9, 18),
        duration: Duration.zero,
        steps: steps,
        screens: const [],
        apiChecks: apiChecks,
      ).toJson(),
    );

/// The wording `ExpectApiStep.describe()` actually produces.
const StepOutcome _apiStep = StepOutcome(
  description: 'expect GET /api/login to have answered 200, 2 fields',
  kind: StepKind.expectApi,
  status: StepStatus.ok,
  durationMs: 31,
);

String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

void main() {
  group('a failing step says why, not only what was attempted', () {
    String page() => _page(steps: const [
          StepOutcome(
            description: 'tap "login.submit"',
            kind: StepKind.tap,
            status: StepStatus.failed,
            durationMs: 120,
            detail: 'no element with testId "login.submit" is on /login',
          ),
        ]);

    test('the step is still named', () {
      expect(page(), contains('tap &quot;login.submit&quot;'));
    });

    test('the recorded detail is rendered', () {
      expect(
        page(),
        contains('no element with testId &quot;login.submit&quot; is on '
            '/login'),
      );
    });

    test('the detail sits with the step, not in a section of its own', () {
      // One row, one place to look. A detail rendered elsewhere is a
      // second thing to correlate by hand.
      //
      // Scoped to the steps table deliberately: this same sentence is
      // also the UI dimension's `reason`, because `verdictFor` takes the
      // decisive result's message - so it legitimately appears higher up
      // the page, and a search of the whole document would find that one
      // instead.
      final section = page().substring(page().indexOf('<h2>Steps</h2>'));
      final row = section.indexOf('tap &quot;login.submit&quot;');
      final rowEnd = section.indexOf('</tr>', row);
      final detail = section.indexOf('no element with testId');

      expect(row, isNonNegative);
      expect(detail, greaterThan(row));
      expect(detail, lessThan(rowEnd));
    });
  });

  group('a step that could not be carried out is not a failure', () {
    String page() => _page(steps: const [
          StepOutcome(
            description: 'expect screen "/home"',
            kind: StepKind.expectScreen,
            status: StepStatus.observationFailed,
            durationMs: 4000,
            detail: 'the VM Service connection closed while waiting',
          ),
        ]);

    test('its own status is rendered', () {
      expect(page(), contains('class="status s-observationFailed"'));
    });

    test('it is not rendered as a failed step', () {
      expect(page(), isNot(contains('class="status s-failed"')));
    });

    test('its detail is rendered too', () {
      expect(page(), contains('the VM Service connection closed'));
    });
  });

  group('passing steps are rendered in full', () {
    test('a pass without detail renders, and nothing is invented', () {
      final html = _page(steps: const [
        StepOutcome(
          description: 'type "9000000001" into "login.mobile_field"',
          kind: StepKind.input,
          status: StepStatus.ok,
          durationMs: 40,
        ),
      ]);

      expect(html, contains('login.mobile_field'));
      expect(html, isNot(contains('<div class="detail"></div>')));
    });

    test('a pass carrying detail keeps it', () {
      // Passing steps are not compacted: the audit found a step
      // description already names the action and its target, so there is
      // no bare row to fold away.
      final html = _page(steps: const [
        StepOutcome(
          description: 'wait for settle',
          kind: StepKind.waitForSettle,
          status: StepStatus.ok,
          durationMs: 900,
          detail: 'settled after 2 frames',
        ),
      ]);

      expect(html, contains('settled after 2 frames'));
    });

    test('every step of a flow is listed', () {
      final html = _page(steps: const [
        StepOutcome(description: 'a', kind: StepKind.tap, status: StepStatus.ok, durationMs: 1),
        StepOutcome(description: 'b', kind: StepKind.tap, status: StepStatus.ok, durationMs: 1),
        StepOutcome(description: 'c', kind: StepKind.tap, status: StepStatus.ok, durationMs: 1),
      ]);

      expect(html, isNot(contains('checks passed')));
      for (final step in const ['>a<', '>b<', '>c<']) {
        expect(html, contains(step));
      }
    });
  });

  group('an API assertion appears once, in the API section', () {
    test('it is not listed among the UI steps', () {
      // The step description is the thing that would appear twice.
      expect(
        _page(steps: const [_apiStep]),
        isNot(contains('to have answered')),
      );
    });

    test('a satisfied assertion is on the page', () {
      final html = _page(
        steps: const [_apiStep],
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: 'GET /api/login',
            failures: [],
            status: 200,
          ),
        ],
      );

      expect(html, contains('GET /api/login'));
      expect(html, contains('200'));
    });

    test('an unsatisfied assertion carries every one of its reasons', () {
      // More than one reason on purpose. The API row of the dimension
      // table already carries the *first* decisive message, so a test
      // asserting one line would pass without an API section existing.
      // The second line is the one only this section can show.
      final html = _page(
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: 'GET /api/cart',
            failures: [
              'data.total was 0, expected 3',
              'data.currency was absent',
            ],
            status: 200,
          ),
        ],
      );

      expect(html, contains('data.total was 0, expected 3'));
      expect(html, contains('data.currency was absent'));
    });

    test('a failing and a passing assertion are both named', () {
      // The dimension reason is null when a dimension passes, so a run
      // whose API assertions all held named none of them.
      final html = _page(
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: 'GET /api/cart',
            failures: ['data.total was 0, expected 3'],
            status: 200,
          ),
          ApiExpectationOutcome(
            endpoint: 'GET /api/offers',
            failures: [],
            status: 200,
          ),
        ],
      );

      expect(html, contains('GET /api/cart'));
      expect(html, contains('GET /api/offers'));
    });

    test('where the request went out is kept', () {
      // STOP-1: a dashboard whose data was fetched on the splash screen
      // is normal, and the report has to be able to say so.
      final html = _page(
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: 'GET /api/profile/me',
            failures: [],
            status: 200,
            screenId: '/splash',
          ),
        ],
      );

      expect(html, contains('/splash'));
    });

    test('a flow with no API assertions grows no API section', () {
      expect(
        _page(steps: const [
          StepOutcome(
            description: 'tap "a"',
            kind: StepKind.tap,
            status: StepStatus.ok,
            durationMs: 1,
          ),
        ]),
        isNot(contains('API assertions')),
      );
    });

    test('a flow of only API assertions still says its steps ran', () {
      // "No UI steps ran" and "the steps table was left out" are
      // different facts, and an absent section reads as the second.
      final html = _page(steps: const [_apiStep]);

      expect(html, contains('Steps'));
    });
  });

  group('a fail-fast flow reads in the order it happened', () {
    test('the surviving steps keep their order and their statuses', () {
      final html = _page(
        steps: const [
          StepOutcome(
            description: 'launch app',
            kind: StepKind.launchApp,
            status: StepStatus.ok,
            durationMs: 10,
          ),
          _apiStep,
          StepOutcome(
            description: 'tap "cart.checkout"',
            kind: StepKind.tap,
            status: StepStatus.failed,
            durationMs: 90,
            detail: 'the button is covered by a modal route',
          ),
          StepOutcome(
            description: 'expect screen "/payment"',
            kind: StepKind.expectScreen,
            status: StepStatus.skipped,
            durationMs: 0,
          ),
        ],
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: 'GET /api/login',
            failures: [],
            status: 200,
          ),
        ],
      );

      final launch = html.indexOf('launch app');
      final tap = html.indexOf('cart.checkout');
      final skipped = html.indexOf('/payment');

      expect(launch, isNonNegative);
      expect(tap, greaterThan(launch));
      expect(skipped, greaterThan(tap));
      expect(html, contains('the button is covered by a modal route'));
      expect(html, contains('class="status s-skipped"'));
      expect(html, isNot(contains('to have answered')));
    });
  });

  group('the page escapes what it now renders', () {
    test('a detail cannot rewrite the report it appears in', () {
      final html = _page(steps: const [
        StepOutcome(
          description: 'tap "x"',
          kind: StepKind.tap,
          status: StepStatus.failed,
          durationMs: 1,
          detail: '<script>alert(1)</script> & "quoted"',
        ),
      ]);

      expect(html, isNot(contains('<script>alert(1)')));
      expect(html, contains('&lt;script&gt;'));
      expect(html, contains('&amp;'));
    });

    test('an API failure line cannot either', () {
      final html = _page(
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: '<img src=x onerror=1>',
            failures: ['<b>nope</b>'],
            status: 500,
          ),
        ],
      );

      expect(html, isNot(contains('<img src=x')));
      expect(html, isNot(contains('<b>nope</b>')));
      expect(html, contains('&lt;img'));
    });

    test('no payload or credential is newly exposed', () {
      const seeded = 'SEEDED_ACCESS_TOKEN_8a17fc';
      final html = _page(
        steps: const [
          StepOutcome(
            description: 'tap "a"',
            kind: StepKind.tap,
            status: StepStatus.failed,
            durationMs: 1,
            detail: 'the element is not hit-testable',
          ),
        ],
        apiChecks: const [
          ApiExpectationOutcome(
            endpoint: 'POST /api/login',
            failures: [],
            status: 200,
          ),
        ],
      );

      expect(html, isNot(contains(seeded)));
      for (final forbidden in const [
        'Authorization',
        'Cookie',
        'Bearer',
        'requestBody',
        'responseBody',
        'headers',
      ]) {
        expect(html, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });

  group('an older artefact renders as it always did', () {
    Map<String, Object?> legacy() => {
          'flow': 'f',
          'passed': true,
          'steps': [
            {'description': 'tap "a"', 'status': 'ok', 'durationMs': 12},
            {'description': 'tap "b"', 'status': 'failed', 'durationMs': 12},
          ],
          'screens': <Object?>[],
        };

    test('steps with no detail render unchanged', () {
      final html = const HtmlReporter().render(legacy());

      expect(html, contains('tap &quot;a&quot;'));
      expect(html, contains('tap &quot;b&quot;'));
    });

    test('no detail block is fabricated', () {
      expect(
        const HtmlReporter().render(legacy()),
        isNot(contains('class="detail"')),
      );
    });

    test('no API section is fabricated', () {
      expect(
        const HtmlReporter().render(legacy()),
        isNot(contains('API assertions')),
      );
    });
  });

  group('one rule, two readers', () {
    test('the page uses the shared predicate', () {
      expect(
        _source('flutter_testsmith/lib/src/engine/reporting/html_reporter.dart'),
        contains('isApiAssertionStep'),
      );
    });

    test('the terminal summary uses the same one', () {
      expect(
        _source('flutter_testsmith/lib/src/engine/reporting/e2e_summary.dart'),
        contains('isApiAssertionStep'),
      );
    });

    test('neither carries a copy of the wording', () {
      // Two copies of a description match is two rules to drift apart.
      for (final file in const [
        'flutter_testsmith/lib/src/engine/reporting/html_reporter.dart',
        'flutter_testsmith/lib/src/engine/reporting/e2e_summary.dart',
      ]) {
        expect(
          _source(file),
          isNot(contains('to have answered')),
          reason: file,
        );
      }
    });

    test('the page still decides nothing', () {
      final source =
          _source('flutter_testsmith/lib/src/engine/reporting/html_reporter.dart');

      expect(source, isNot(contains('aggregateStatus')));
      expect(source, isNot(contains('errorCount')));
      expect(source, isNot(contains('.every(')));
    });

    test('the API rows are read, not re-evaluated', () {
      // `satisfied` is canonical and already in the file. Recomputing it
      // from `failures` here would give the page licence to disagree
      // with the JSON beside it.
      expect(
        _source('flutter_testsmith/lib/src/engine/reporting/html_reporter.dart'),
        contains("check['satisfied']"),
      );
    });
  });
}
