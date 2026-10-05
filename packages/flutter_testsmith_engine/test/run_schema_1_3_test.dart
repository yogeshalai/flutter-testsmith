// Run schema 1.3: `steps[].kind`.
//
// Additive, on the same terms as 1.1 and 1.2 before it - a key is added,
// nothing that existed changes meaning, and the version says so rather
// than leaving a consumer to find out. The suite schema is untouched:
// nothing about a suite changed.
//
// What the key buys is in the second half of this file. Before it, both
// reports worked out what a step was from its description, and two
// perfectly ordinary UI assertions - an `expectElement` whose expected
// text contains "to have answered", an `expectScreen` whose screen id
// does - read as API assertions and disappeared from the UI section
// without appearing in the API one. With a kind on the wire they are UI
// steps, because the step says so, and no wording can argue.
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

RunResult _run({
  List<StepOutcome> steps = const [],
  List<ApiExpectationOutcome> apiChecks = const [],
}) =>
    RunResult(
      flowName: 'checkout',
      appId: 'com.example.shop',
      device: 'pixel-7',
      startedAt: DateTime.utc(2026, 9, 18),
      duration: const Duration(seconds: 12),
      steps: steps,
      screens: const [],
      apiChecks: apiChecks,
    );

List<Map<String, Object?>> _steps(RunResult run) => [
      for (final s in run.toJson()['steps']! as List)
        (s! as Map).cast<String, Object?>(),
    ];

/// An `expectElement` whose expected text happens to contain the phrase
/// the old classifier keyed on.
const StepOutcome _elementCollision = StepOutcome(
  description: 'expect "chat.last_reply" textContains = to have answered',
  kind: StepKind.expectElement,
  status: StepStatus.ok,
  durationMs: 12,
);

/// An `expectScreen` whose screen id does.
const StepOutcome _screenCollision = StepOutcome(
  description: 'expect to be on "/faq/to have answered"',
  kind: StepKind.expectScreen,
  status: StepStatus.ok,
  durationMs: 8,
);

const StepOutcome _apiStep = StepOutcome(
  description: 'expect GET /api/cart to have answered 200',
  kind: StepKind.expectApi,
  status: StepStatus.ok,
  durationMs: 31,
);

void main() {
  group('the version', () {
    // `kind` arrived at 1.3; the current version has moved on since,
    // and every schema test pins where it is now.
    test('the run schema is 1.6', () {
      expect(RunResult.schemaVersion, '1.6');
      expect(_run().toJson()['resultSchemaVersion'], '1.6');
    });

    test('the suite schema is untouched at 1.1', () {
      expect(SuiteResult.schemaVersion, '1.1');
    });
  });

  group('the serialised step', () {
    final json = _steps(_run(steps: const [
      StepOutcome(
        description: 'tap "cart.checkout"',
        kind: StepKind.tap,
        status: StepStatus.failed,
        durationMs: 90,
        detail: 'the button is covered by a modal route',
      ),
    ])).single;

    test('carries its kind', () {
      expect(json['kind'], 'tap');
    });

    test('and every field it carried at 1.2, unchanged', () {
      expect(json['description'], 'tap "cart.checkout"');
      expect(json['status'], 'failed');
      expect(json['durationMs'], 90);
      expect(json['detail'], 'the button is covered by a modal route');
    });

    test('and gains nothing else', () {
      expect(
        json.keys.toSet(),
        {'description', 'kind', 'status', 'durationMs', 'detail'},
      );
    });

    test('a step with no detail still omits the key', () {
      final bare = _steps(_run(steps: const [
        StepOutcome(
          description: 'press back',
          kind: StepKind.back,
          status: StepStatus.ok,
          durationMs: 4,
        ),
      ])).single;

      expect(bare.containsKey('detail'), isFalse);
      expect(bare['kind'], 'back');
    });
  });

  group('every kind serialises to its wire string', () {
    test('all eleven, in one run', () {
      final steps = [
        for (final kind in StepKind.values)
          StepOutcome(
            description: 'a step',
            kind: kind,
            status: StepStatus.ok,
            durationMs: 1,
          ),
      ];

      expect(
        _steps(_run(steps: steps)).map((s) => s['kind']).toList(),
        [for (final kind in StepKind.values) kind.wire],
      );
    });
  });

  group('the HTML page classifies by kind', () {
    String page(List<StepOutcome> steps) =>
        const HtmlReporter().render(_run(steps: steps).toJson());

    test('an expectApi step is not in the UI steps table', () {
      expect(page(const [_apiStep]), isNot(contains('to have answered')));
    });

    test('an expectElement keeps its place despite the wording', () {
      final html = page(const [_elementCollision]);

      expect(html, contains('chat.last_reply'));
      expect(html, contains('to have answered'));
    });

    test('an expectScreen keeps its place too', () {
      final html = page(const [_screenCollision]);

      expect(html, contains('/faq/to have answered'));
    });

    test('the three together: two UI rows and no third', () {
      final html = page(const [
        _elementCollision,
        _apiStep,
        _screenCollision,
      ]);
      final section = html.substring(html.indexOf('<h2>Steps</h2>'));

      expect(section, contains('chat.last_reply'));
      expect(section, contains('/faq/to have answered'));
      expect(
        section,
        isNot(contains('expect GET /api/cart to have answered')),
      );
    });

    test('the step detail still renders', () {
      final html = page(const [
        StepOutcome(
          description: 'tap "cart.checkout"',
          kind: StepKind.tap,
          status: StepStatus.failed,
          durationMs: 90,
          detail: 'the button is covered by a modal route',
        ),
      ]);

      expect(html, contains('the button is covered by a modal route'));
    });

    test('an observation failure still reads as one, with its detail', () {
      final html = page(const [
        StepOutcome(
          description: 'expect screen "/home"',
          kind: StepKind.expectScreen,
          status: StepStatus.observationFailed,
          durationMs: 4000,
          detail: 'the VM Service connection closed while waiting',
        ),
      ]);

      expect(html, contains('class="status s-observationFailed"'));
      expect(html, isNot(contains('class="status s-failed"')));
      expect(html, contains('the VM Service connection closed'));
    });
  });

  group('the API evidence section is unchanged', () {
    test('an assertion appears exactly once, in its own section', () {
      final html = const HtmlReporter().render(
        _run(
          steps: const [_apiStep],
          apiChecks: const [
            ApiExpectationOutcome(
              endpoint: 'GET /api/cart',
              failures: [],
              status: 200,
              screenId: '/cart',
            ),
          ],
        ).toJson(),
      );

      expect(html, contains('API assertions'));
      expect(RegExp('GET /api/cart').allMatches(html).length, 1);
      expect(html, contains('/cart'));
    });

    test('a failing assertion keeps all of its reasons', () {
      final html = const HtmlReporter().render(
        _run(
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
        ).toJson(),
      );

      expect(html, contains('data.total was 0, expected 3'));
      expect(html, contains('data.currency was absent'));
    });
  });

  group('the terminal summary classifies by the same rule', () {
    String text(List<StepOutcome> steps, {List<ApiExpectationOutcome> api =
        const []}) =>
        const E2eSummary().render(_run(steps: steps, apiChecks: api));

    test('an expectApi step is not repeated in the UI section', () {
      final rendered = text(
        const [_apiStep],
        api: const [
          ApiExpectationOutcome(
            endpoint: 'GET /api/cart',
            failures: [],
            status: 200,
          ),
        ],
      );

      expect(rendered, isNot(contains('to have answered')));
      expect(rendered, contains('GET /api/cart'));
    });

    test('an expectElement with the API wording stays a UI step', () {
      final rendered = text(const [_elementCollision]);

      expect(rendered, contains('chat.last_reply'));
      expect(rendered, contains('to have answered'));
    });

    test('an expectScreen with the API wording stays a UI step', () {
      expect(text(const [_screenCollision]),
          contains('/faq/to have answered'));
    });

    test('CLI and HTML agree about the same run', () {
      const steps = [_elementCollision, _apiStep, _screenCollision];
      final rendered = text(steps);
      final html = const HtmlReporter().render(_run(steps: steps).toJson());
      final section = html.substring(html.indexOf('<h2>Steps</h2>'));

      for (final shown in const ['chat.last_reply', '/faq/to have answered']) {
        expect(rendered, contains(shown));
        expect(section, contains(shown));
      }
      expect(rendered, isNot(contains('expect GET /api/cart')));
      expect(section, isNot(contains('expect GET /api/cart')));
    });
  });

  group('an artefact written before 1.3 is read as it always was', () {
    // No `kind` on any step. The description classifier decides, which
    // means the two collisions stay wrong here - that is the old file's
    // content, and repairing it would be a guess.
    Map<String, Object?> legacy(List<Map<String, Object?>> steps) => {
          'resultSchemaVersion': '1.2',
          'flow': 'f',
          'passed': true,
          'steps': steps,
          'screens': <Object?>[],
        };

    test('an ordinary step renders', () {
      final html = const HtmlReporter().render(legacy([
        {'description': 'tap "a"', 'status': 'ok', 'durationMs': 12},
      ]));

      expect(html, contains('tap &quot;a&quot;'));
    });

    test('an expectApi description is still filtered out', () {
      final html = const HtmlReporter().render(legacy([
        {
          'description': 'expect GET /api/cart to have answered 200',
          'status': 'ok',
          'durationMs': 12,
        },
      ]));

      expect(html, isNot(contains('to have answered')));
    });

    test('the old false positive is preserved, not repaired', () {
      final html = const HtmlReporter().render(legacy([
        {
          'description':
              'expect "chat.last_reply" textContains = to have answered',
          'status': 'ok',
          'durationMs': 12,
        },
      ]));

      expect(html, isNot(contains('chat.last_reply')));
    });

    test('no kind is fabricated for it', () {
      final html = const HtmlReporter().render(legacy([
        {'description': 'tap "a"', 'status': 'ok', 'durationMs': 12},
      ]));

      expect(html, isNot(contains('expectElement')));
      expect(html, isNot(contains('launchApp')));
    });
  });

  group('the new key carries nothing sensitive', () {
    test('a kind is a fixed vocabulary word, never run data', () {
      final html = const HtmlReporter().render(
        _run(
          steps: const [
            StepOutcome(
              description: 'type <env:LOGIN_PASSWORD> into "login.password"',
              kind: StepKind.secretInput,
              status: StepStatus.ok,
              durationMs: 20,
            ),
          ],
        ).toJson(),
      );

      const seeded = 'SEEDED_ACCESS_TOKEN_8a17fc';
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

    test('every wire string is a bare identifier', () {
      // Nothing interpolated, nothing user-supplied: a kind cannot carry
      // a value out of a run, and needs no escaping to be safe.
      for (final kind in StepKind.values) {
        expect(kind.wire, matches(RegExp(r'^[a-zA-Z]+$')), reason: kind.wire);
      }
    });

    test('the page still escapes the description beside it', () {
      final html = const HtmlReporter().render(
        _run(
          steps: const [
            StepOutcome(
              description: '<script>alert(1)</script>',
              kind: StepKind.tap,
              status: StepStatus.ok,
              durationMs: 1,
            ),
          ],
        ).toJson(),
      );

      expect(html, isNot(contains('<script>alert(1)')));
      expect(html, contains('&lt;script&gt;'));
    });
  });
}
