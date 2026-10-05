// The terminal said what was moving on the screen. The page did not.
//
// `quiescence` has been in `result.json` since E2E reporting was
// organised by layer, and `E2eSummary` has had a QUIESCENCE section just
// as long. `HtmlReporter` had no reader for the field, so a screen
// photographed while an undeclared animation was still running rendered
// exactly like one that had settled - and a VISUAL pass on the second is
// a different claim from a VISUAL pass on the first.
//
// This renders what the evaluator already recorded, in its own words.
// Nothing is recomputed: the counts, the permitted entries and the
// reasons they were permitted were decided during the run, and a second
// description here would be a second thing to drift from the terminal.
//
// It is context, not a verdict. The screen's status still decides
// everything, and the block is deliberately not styled as a status.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

String _page(ScreenResult screen) => const HtmlReporter().render(
      RunResult(
        flowName: 'f',
        appId: 'a',
        device: 'd',
        startedAt: DateTime.utc(2026, 9, 18),
        duration: Duration.zero,
        steps: const [
          StepOutcome(
            description: 'validate the screen (automatic)',
            kind: StepKind.validateScreen,
            status: StepStatus.ok,
            durationMs: 30,
          ),
        ],
        screens: [screen],
      ).toJson(),
    );

ScreenResult _screen({
  QuiescenceSummary? quiescence,
  List<ValidationResult> results = const [
    ValidationResult.pass(
      validatorId: 'visual',
      message: 'the screenshot matches the accepted baseline',
      dimension: ValidationDimension.visual,
    ),
  ],
}) =>
    ScreenResult(
      screenId: '/dashboard',
      report: ValidationReport(results),
      quiescence: quiescence,
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
  group('a screen that had settled says so', () {
    String page() => _page(_screen(
          quiescence: const QuiescenceSummary(
            ticking: 0,
            permitted: 0,
            unexpected: 0,
            lines: ['0 animations ticking', '0 permitted', '0 unexpected'],
          ),
        ));

    test('the block is on the page', () {
      expect(page(), contains('class="quiescence"'));
      expect(page(), contains('quiescence'));
    });

    test('it states what was recorded', () {
      expect(page(), contains('0 animations ticking'));
      expect(page(), contains('0 unexpected'));
    });

    test('it is not presented as a verdict', () {
      // The screen's own status is the only thing that decides. A
      // quiescence block wearing a status pill would read as a second
      // opinion about the screen.
      final html = page();
      final block = html.substring(html.indexOf('class="quiescence"'));
      final end = block.indexOf('</div>');

      expect(block.substring(0, end), isNot(contains('verdict')));
      expect(block.substring(0, end), isNot(contains('s-pass')));
    });

    test('the screen still passes', () {
      expect(page(), contains('<span class="verdict pass">PASS</span>'));
    });
  });

  group('a screen that was still moving says what, and why it was allowed',
      () {
    String page() => _page(_screen(
          quiescence: const QuiescenceSummary(
            ticking: 3,
            permitted: 1,
            unexpected: 2,
            lines: [
              '3 animations ticking',
              '1 permitted',
              '2 unexpected',
              '  permitted: AnimationController in "home.splash_fade" '
                  'at 0,0 360x640 - declared in quiescence.yaml',
              '  unexpected: Ticker owned by MARKER_TICKER',
              '  unexpected: AnimationController in "home.promo_carousel"',
              '  1 ignored on the screen underneath',
              '  declared but not animating: "home.stale_declaration"',
            ],
          ),
        ));

    test('the counts are rendered', () {
      expect(page(), contains('3 animations ticking'));
      expect(page(), contains('2 unexpected'));
    });

    test('each unexpected animation is named', () {
      expect(page(), contains('MARKER_TICKER'));
      expect(page(), contains('home.promo_carousel'));
    });

    test('a permitted one says why it was permitted', () {
      expect(page(), contains('home.splash_fade'));
      expect(page(), contains('declared in quiescence.yaml'));
    });

    test('what was ignored and what was declared-but-idle both survive', () {
      expect(page(), contains('ignored on the screen underneath'));
      expect(page(), contains('home.stale_declaration'));
    });

    test('a settled screen and a moving one do not read alike', () {
      final settled = _page(_screen(
        quiescence: const QuiescenceSummary(
          ticking: 0,
          permitted: 0,
          unexpected: 0,
          lines: ['0 animations ticking', '0 permitted', '0 unexpected'],
        ),
      ));

      expect(settled, isNot(contains('MARKER_TICKER')));
      expect(page(), contains('MARKER_TICKER'));
    });
  });

  group('a summary recorded without the evaluator lines', () {
    test('the three counts are still shown', () {
      final html = _page(_screen(
        quiescence: const QuiescenceSummary(
          ticking: 2,
          permitted: 1,
          unexpected: 1,
        ),
      ));

      expect(html, contains('ticking 2'));
      expect(html, contains('permitted 1'));
      expect(html, contains('unexpected 1'));
    });
  });

  group('an artefact whose screen recorded no quiescence', () {
    test('no block appears, and nothing is claimed on its behalf', () {
      final html = _page(_screen());

      expect(html, isNot(contains('class="quiescence"')));
      expect(html, isNot(contains('nothing was ticking')));
    });

    test('a legacy screen map renders exactly as before', () {
      // Schema 1.2 and earlier wrote `quiescence` only when a screen had
      // one, and an older file may carry none at all.
      final html = const HtmlReporter().render({
        'flow': 'f',
        'passed': true,
        'steps': <Object?>[],
        'screens': [
          {
            'screenId': '/a',
            'validation': {
              'passed': true,
              'counts': {'pass': 1, 'fail': 0, 'skip': 0, 'error': 0},
              'results': [
                ValidationResult.pass(
                  validatorId: 'ui-presence',
                  message: 'present',
                  dimension: ValidationDimension.ui,
                ).toJson(),
              ],
            },
            'exchanges': <Object?>[],
          },
        ],
      });

      expect(html, contains('/a'));
      expect(html, contains('present'));
      expect(html, isNot(contains('class="quiescence"')));
    });

    test('a malformed quiescence value is ignored, not guessed at', () {
      final html = const HtmlReporter().render({
        'flow': 'f',
        'passed': true,
        'steps': <Object?>[],
        'screens': [
          {
            'screenId': '/a',
            'validation': {
              'passed': true,
              'counts': {'pass': 0, 'fail': 0, 'skip': 0, 'error': 0},
              'results': <Object?>[],
            },
            'exchanges': <Object?>[],
            'quiescence': 'not a map',
          },
        ],
      });

      expect(html, isNot(contains('class="quiescence"')));
      expect(html, contains('/a'));
    });
  });

  group('the block carries nothing sensitive, and escapes what it shows', () {
    test('no payload or credential reaches it', () {
      const seeded = 'SEEDED_ACCESS_TOKEN_8a17fc';
      final html = _page(_screen(
        quiescence: const QuiescenceSummary(
          ticking: 1,
          permitted: 0,
          unexpected: 1,
          lines: ['1 animations ticking', '  unexpected: Ticker in "spinner"'],
        ),
      ));

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

    test('a recorded line cannot rewrite the report it appears in', () {
      final html = _page(_screen(
        quiescence: const QuiescenceSummary(
          ticking: 1,
          permitted: 0,
          unexpected: 1,
          lines: ['  unexpected: <script>alert(1)</script> & "quoted"'],
        ),
      ));

      expect(html, isNot(contains('<script>alert(1)')));
      expect(html, contains('&lt;script&gt;'));
      expect(html, contains('&amp;'));
    });
  });

  group('the page reads, it does not decide', () {
    test('quiescence is read from the serialised field', () {
      expect(_source(), contains("screen['quiescence']"));
    });

    test('nothing about it is recomputed', () {
      final source = _source();

      expect(source, isNot(contains('aggregateStatus')));
      expect(source, isNot(contains('QuiescencePolicy')));
      expect(source, isNot(contains('.every(')));
    });
  });
}
