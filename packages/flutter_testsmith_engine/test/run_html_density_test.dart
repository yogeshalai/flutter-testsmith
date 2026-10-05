// The run page printed every green row; the suite page had learned not
// to. Two renderings of the same evidence, with opposite editorial
// rules.
//
// The audit turned up the thing that decides the shape of this change:
// **STOP-1 provenance hangs off passing results.** A row that says
// "response.data.firstName matches profile.display_name.text, from
// GET /api/profile/me captured on / 15s earlier" is a PASS, and
// it is the one row on the page that stops a reader assuming the data
// belonged to the screen in front of them. A blanket "drop the passes"
// would have deleted exactly that.
//
// So the rule is not about status. It is about whether a row says
// anything beyond "this passed": a bare pass is summarised, and a pass
// carrying provenance or measured values is kept. Skips are kept too -
// a screen that passed because nothing was compared is the single thing
// this codebase is most careful never to let read as evidence.
//
// FAIL, ERROR, SKIP and legacy screens render exactly as before.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

ValidationResult _pass({
  String validatorId = 'ui-presence',
  String message = 'present',
  Object? expected,
  Object? actual,
  List<Evidence> evidence = const [],
}) =>
    ValidationResult.pass(
      validatorId: validatorId,
      message: message,
      dimension: ValidationDimension.ui,
      expected: expected,
      actual: actual,
      evidence: evidence,
    );

ValidationResult _fail() => const ValidationResult.fail(
      validatorId: 'api-to-ui',
      elementId: 'product.price',
      message: 'the UI shows "Rs 2,599", the API returned 2999',
      expected: 'Rs 2,999',
      actual: 'Rs 2,599',
      dimension: ValidationDimension.api,
    );

ValidationResult _error() => const ValidationResult.error(
      validatorId: 'visual',
      message: 'cannot photograph deterministically: 1 unexpected animation',
      dimension: ValidationDimension.visual,
    );

ValidationResult _skip() => const ValidationResult.skip(
      validatorId: 'figma',
      message: 'Figma is not configured',
      dimension: ValidationDimension.figma,
    );

ScreenResult _screen(String id, List<ValidationResult> results) =>
    ScreenResult(screenId: id, report: ValidationReport(results));

String _page(List<ScreenResult> screens) => const HtmlReporter().render(
      RunResult(
        flowName: 'f',
        appId: 'a',
        device: 'd',
        startedAt: DateTime.utc(2026, 9, 18),
        duration: Duration.zero,
        steps: const [
          StepOutcome(
              description: 'launch', kind: StepKind.launchApp, status: StepStatus.ok, durationMs: 0),
        ],
        screens: screens,
      ).toJson(),
    );

String _source() {
  const relative = 'flutter_testsmith_engine/lib/src/reporting/html_reporter.dart';
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

void main() {
  group('a passing screen stays identifiable and stops being a wall', () {
    String page() => _page([
          _screen('/a', [_pass(), _pass(message: 'also present'), _pass()]),
        ]);

    test('the screen is still named', () {
      expect(page(), contains('/a'));
    });

    test('its status is still shown, from the canonical field', () {
      expect(page(), contains('<span class="verdict pass">PASS</span>'));
    });

    test('the bare pass rows are not printed', () {
      expect(page(), isNot(contains('also present')));
    });

    test('a count says how many were summarised', () {
      expect(page(), contains('3 checks passed'));
    });

    test('nothing is invented about them', () {
      // The line says how many passed and no more. No validator names,
      // no synthesised detail.
      expect(page(), isNot(contains('ui-presence')));
    });
  });

  group('a pass that carries evidence is never dropped', () {
    test('STOP-1 provenance survives on a passing screen', () {
      // The case that decided this design. The row is a PASS, and it is
      // the only thing on the page saying the data was captured
      // somewhere else.
      final html = _page([
        _screen('/profile', [
          _pass(),
          _pass(
            validatorId: 'api-to-ui',
            message: 'response.data.firstName matches',
            evidence: const [
              Evidence(
                  kind: 'sourceEndpoint',
                  reference: 'GET /api/profile/me'),
              Evidence(kind: 'sourceScreen', reference: '/'),
              Evidence(
                  kind: 'sourceCapturedAt',
                  reference: '2026-09-12T10:00:05.000Z'),
              Evidence(kind: 'sourceRequestId', reference: 'req-42'),
              Evidence(kind: 'sourceAgeSeconds', reference: '15'),
            ],
          ),
        ]),
      ]);

      expect(html, contains('GET /api/profile/me'));
      expect(html, contains('captured on'));
      expect(html, contains('req-42'));
      expect(html, contains('15s before this screen'));
    });

    test('a pass carrying measured values survives', () {
      final html = _page([
        _screen('/a', [
          _pass(),
          _pass(
              validatorId: 'api-to-ui',
              message: 'the price matches',
              expected: 'Rs 2,999',
              actual: 'Rs 2,999'),
        ]),
      ]);

      expect(html, contains('Rs 2,999'));
      expect(html, contains('the price matches'));
    });

    test('only the bare ones are counted', () {
      final html = _page([
        _screen('/a', [
          _pass(),
          _pass(expected: 'x', actual: 'x'),
        ]),
      ]);

      expect(html, contains('1 check passed'));
    });

    test('a skip on a passing screen is kept', () {
      // A screen that passed because nothing was compared must never
      // read as a screen that was checked.
      final html = _page([_screen('/a', [_pass(), _skip()])]);

      expect(html, contains('Figma is not configured'));
      expect(html, contains('<span class="verdict pass">PASS</span>'));
    });
  });

  group('a failing screen loses nothing', () {
    String page() => _page([_screen('/a', [_pass(), _fail(), _skip()])]);

    test('its status is FAIL', () {
      expect(page(), contains('<span class="verdict fail">FAIL</span>'));
    });

    test('the failure row is rendered in full', () {
      expect(page(), contains('api-to-ui'));
      expect(page(), contains('product.price'));
      expect(page(), contains('the UI shows'));
    });

    test('the measured values are rendered', () {
      expect(page(), contains('Rs 2,999'));
      expect(page(), contains('Rs 2,599'));
    });

    test('the passing rows are still rendered here', () {
      // Only a passing screen is compacted. On a failing one the passes
      // are context for what did work.
      expect(page(), contains('ui-presence'));
    });

    test('no count line appears', () {
      expect(page(), isNot(contains('checks passed')));
    });
  });

  group('an erroring screen loses nothing, and is not a failure', () {
    String page() => _page([_screen('/a', [_pass(), _error()])]);

    test('its status is ERROR', () {
      expect(page(), contains('<span class="verdict error">ERROR</span>'));
    });

    test('it is not presented as a failure', () {
      expect(page(), isNot(contains('<span class="verdict fail">FAIL</span>')));
    });

    test('the error evidence is rendered in full', () {
      expect(page(), contains('cannot photograph deterministically'));
      expect(page(), contains('visual'));
    });

    test('the passing rows are still rendered here too', () {
      expect(page(), contains('ui-presence'));
    });
  });

  group('a skipped screen invents nothing', () {
    String page() => _page([_screen('/a', [_skip()])]);

    test('its status is SKIP', () {
      expect(page(), contains('<span class="verdict skip">SKIP</span>'));
    });

    test('the skip reason is rendered', () {
      expect(page(), contains('Figma is not configured'));
    });

    test('no pass count is fabricated', () {
      expect(page(), isNot(contains('checks passed')));
    });
  });

  group('screens do not affect one another', () {
    String page() => _page([
          _screen('/a', [_pass(), _pass()]),
          _screen('/b', [_error()]),
          _screen('/c', [_fail()]),
        ]);

    test('each keeps its own status', () {
      expect(page(), contains('<span class="verdict pass">PASS</span>'));
      expect(page(), contains('<span class="verdict error">ERROR</span>'));
      expect(page(), contains('<span class="verdict fail">FAIL</span>'));
    });

    test('the passing screen is compacted and the others are not', () {
      expect(page(), contains('2 checks passed'));
      expect(page(), contains('cannot photograph deterministically'));
      expect(page(), contains('the UI shows'));
    });
  });

  group('an older artefact renders as it always did', () {
    // A screen written before schema 1.2 has no `status`, so there is
    // nothing to compact against. Re-deriving one from the rows is the
    // second answer the canonical field exists to remove.
    Map<String, Object?> legacy() => {
          'flow': 'f',
          'passed': true,
          'steps': <Object?>[],
          'screens': [
            {
              'screenId': '/a',
              'validation': {
                'passed': true,
                'counts': {'pass': 2, 'fail': 0, 'skip': 0, 'error': 0},
                'results': [
                  _pass().toJson(),
                  _pass(message: 'also present').toJson(),
                ],
              },
              'exchanges': <Object?>[],
            },
          ],
        };

    test('every row is still rendered', () {
      final html = const HtmlReporter().render(legacy());

      expect(html, contains('present'));
      expect(html, contains('also present'));
    });

    test('no status badge is fabricated for the screen', () {
      final html = const HtmlReporter().render(legacy());

      expect(html, isNot(contains('<span class="verdict pass">PASS</span>')));
    });

    test('no count line is fabricated', () {
      expect(
        const HtmlReporter().render(legacy()),
        isNot(contains('checks passed')),
      );
    });
  });

  group('the page renders, it does not decide', () {
    test('it aggregates nothing', () {
      final source = _source();

      expect(source, isNot(contains('aggregateStatus')));
      expect(source, isNot(contains('errorCount')));
      expect(source, isNot(contains('.every(')));
    });

    test('it reads the canonical screen status', () {
      expect(_source(), contains("screen['status']"));
    });

    test('it derives no screen status from the rows or the counts', () {
      final source = _source();

      expect(source, isNot(contains("counts?['pass']")));
      expect(source, isNot(contains("counts['pass']")));
    });
  });

  group('nothing sensitive is newly exposed', () {
    test('a compacted page carries no payload or credential', () {
      const seeded = 'SEEDED_ACCESS_TOKEN_8a17fc';
      final html = _page([
        _screen('/a', [_pass(), _pass()]),
        _screen('/b', [_fail()]),
      ]);

      expect(html, isNot(contains(seeded)));
      for (final forbidden in const [
        'Authorization',
        'Cookie',
        'Bearer',
        'requestBody',
        'responseBody',
      ]) {
        expect(html, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}
