import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// The report a developer reads first.
///
/// The failure this exists for is not a wrong verdict - the verdicts
/// were already right - but an unreadable one. A run that stopped
/// because an undeclared animation blocked the photograph used to print
/// a validation error among forty step lines, and the first question
/// anyone asked was "so did the API work?".
///
/// Four sections, always in the same order, each answering one layer's
/// question. A section with nothing in it says so rather than being
/// omitted: "no API assertions were made" and "every API assertion
/// passed" are different facts.

/// A step outcome for the summary to render.
///
/// [kind] defaults to a plain UI action, and the one test that cares
/// about an API assertion passes `StepKind.expectApi` explicitly. Since
/// run schema 1.3 the kind is what decides which section a step belongs
/// in, so it is stated here rather than inferred from the wording.
StepOutcome step(
  String description, {
  StepStatus status = StepStatus.ok,
  StepKind kind = StepKind.tap,
}) =>
    StepOutcome(
      description: description,
      kind: kind,
      status: status,
      durationMs: 10,
    );

ApiExpectationOutcome apiOk(String endpoint, int status) =>
    ApiExpectationOutcome(
      endpoint: endpoint,
      failures: const [],
      status: status,
      screenId: '/home',
    );

ScreenResult screen({
  required String id,
  required List<ValidationResult> results,
  QuiescenceSummary? quiescence,
}) =>
    ScreenResult(
      screenId: id,
      report: ValidationReport(results),
      quiescence: quiescence,
    );

RunResult runOf({
  List<StepOutcome> steps = const [],
  List<ScreenResult> screens = const [],
  List<ApiExpectationOutcome> apiChecks = const [],
}) =>
    RunResult(
      flowName: 'dashboard',
      appId: 'com.example.app',
      device: 'RZ8T11QETWM',
      startedAt: DateTime.utc(2026, 9, 12),
      duration: const Duration(seconds: 30),
      steps: steps,
      screens: screens,
      apiChecks: apiChecks,
    );

String render(RunResult result) => const E2eSummary().render(result);

void main() {
  group('the shape of the report', () {
    test('names the flow and carries all four sections in order', () {
      final text = render(runOf(steps: [step('tap "nav.orders"')]));

      expect(text, contains('E2E: dashboard'));
      final api = text.indexOf('API');
      final ui = text.indexOf('UI');
      final quiescence = text.indexOf('QUIESCENCE');
      final visual = text.indexOf('VISUAL');

      expect(api, greaterThan(0));
      expect(ui, greaterThan(api));
      expect(quiescence, greaterThan(ui));
      expect(visual, greaterThan(quiescence));
    });

    test('ends with the verdict', () {
      expect(
        render(runOf(steps: [step('tap x')])),
        contains('RESULT: PASS'),
      );
      expect(
        render(runOf(steps: [step('tap x', status: StepStatus.failed)])),
        contains('RESULT: FAIL'),
      );
    });

    test('a run that checked nothing reads SKIP', () {
      // The line is now the run's own `overall`, which has always
      // documented this shape as rolling up to SKIP: a PASS is a
      // positive claim and nothing was compared. It used to print PASS
      // because it was derived from the `passed` boolean, which is
      // vacuously true here and still is.
      //
      // Unreachable from a real flow - `TestFlow.parse` requires at
      // least one step - so no producible run changes verdict.
      expect(render(runOf()), contains('RESULT: SKIP'));
      expect(runOf().passed, isTrue);
    });
  });

  group('the API section', () {
    test('lists each assertion with its status', () {
      final text = render(
        runOf(apiChecks: [apiOk('GET /api/dashboard', 200)]),
      );

      expect(text, contains('GET /api/dashboard'));
      expect(text, contains('200'));
    });

    test('says so when no API assertion was made', () {
      // Not an empty section. A reader who sees no API rows cannot tell
      // "nothing was asserted" from "everything passed", and those are
      // the two readings that matter most.
      expect(render(runOf()), contains('no API assertions'));
    });

    test('a failed assertion names every reason', () {
      final text = render(
        runOf(
          apiChecks: [
            const ApiExpectationOutcome(
              endpoint: 'GET /api/dashboard',
              status: 500,
              failures: [
                'GET /api/dashboard answered 500, expected 200',
              ],
            ),
          ],
        ),
      );

      expect(text, contains('answered 500'));
      expect(text, contains('RESULT: FAIL'));
    });
  });

  group('the quiescence section', () {
    test('reports the three counts that decide whether a photograph is '
        'possible', () {
      final text = render(
        runOf(
          screens: [
            screen(
              id: '/home',
              results: const [],
              quiescence: const QuiescenceSummary(
                ticking: 2,
                permitted: 2,
                unexpected: 0,
                lines: ['  permitted: Lottie in "home.outlets_near_you"'],
              ),
            ),
          ],
        ),
      );

      expect(text, contains('ticking animations: 2'));
      expect(text, contains('permitted: 2'));
      expect(text, contains('unexpected: 0'));
    });

    test('an unexpected animation is shown with what it was', () {
      final text = render(
        runOf(
          screens: [
            screen(
              id: '/home',
              results: const [],
              quiescence: const QuiescenceSummary(
                ticking: 1,
                permitted: 0,
                unexpected: 1,
                lines: [
                  '  unexpected: Lottie at 180,420 64x64',
                ],
              ),
            ),
          ],
        ),
      );

      expect(text, contains('unexpected: 1'));
      expect(text, contains('180,420 64x64'));
    });

    test('says so when nothing was moving', () {
      final text = render(
        runOf(screens: [screen(id: '/profile', results: const [])]),
      );

      expect(text, contains('nothing was ticking'));
    });
  });

  group('the visual section', () {
    test('carries the comparison line as the validator worded it', () {
      final text = render(
        runOf(
          screens: [
            screen(
              id: '/home',
              results: const [
                ValidationResult.pass(
                  validatorId: 'visual',
                  dimension: ValidationDimension.visual,
                  message: '"/home" matches the baseline: 0.000% of 1076400 '
                      'pixels differ, ssim 1.0000',
                ),
              ],
            ),
          ],
        ),
      );

      expect(text, contains('0.000%'));
      expect(text, contains('ssim 1.0000'));
    });

    test('a blocked comparison says it was blocked, not that it failed', () {
      // The distinction the whole quiescence milestone rests on. An
      // undeclared animation means the tool could not take an honest
      // picture; it is not a claim that the screen is wrong.
      final text = render(
        runOf(
          screens: [
            screen(
              id: '/home',
              results: const [
                ValidationResult.error(
                  validatorId: 'visual',
                  dimension: ValidationDimension.visual,
                  message: 'cannot photograph "/home" deterministically: '
                      '1 unexpected animation running',
                ),
              ],
              quiescence: const QuiescenceSummary(
                ticking: 1,
                permitted: 0,
                unexpected: 1,
              ),
            ),
          ],
        ),
      );

      expect(text, contains('BLOCKED'));
      // And the headline agrees with the section. This line used to read
      // FAIL, which contradicted the name of this very test: the run had
      // not shown the screen to be wrong, it had failed to take a
      // picture of it. ERROR is what the status was all along; only the
      // renderer was inferring `passed == false` meant FAIL.
      expect(text, contains('RESULT: ERROR'));
      expect(text, isNot(contains('RESULT: FAIL')));
    });

    test('says so when no screenshot was compared', () {
      expect(render(runOf()), contains('no screenshot'));
    });
  });

  group('the UI section', () {
    test('lists the steps that acted on the application', () {
      final text = render(
        runOf(
          steps: [
            step('launch the app'),
            step('tap "nav.orders"'),
            step('expect to be on "/orders"'),
          ],
        ),
      );

      expect(text, contains('tap "nav.orders"'));
    });

    test('a failed step carries its detail', () {
      final text = render(
        runOf(
          steps: [
            StepOutcome(
              description: 'tap "nav.orders"',
              kind: StepKind.tap,
              status: StepStatus.failed,
              durationMs: 20,
              detail: 'no element with test id "nav.orders"',
            ),
          ],
        ),
      );

      expect(text, contains('no element with test id "nav.orders"'));
    });

    test('the API assertion steps are not repeated in the UI section', () {
      // They have their own section, and a line in both would make the
      // report look like twice as much happened.
      final text = render(
        runOf(
          steps: [
            step('launch the app', kind: StepKind.launchApp),
            step(
              'expect GET /api/dashboard to have answered 200',
              kind: StepKind.expectApi,
            ),
          ],
          apiChecks: [apiOk('GET /api/dashboard', 200)],
        ),
      );

      // The step's own wording does not appear at all: the API section
      // states the same fact better, with the status the application
      // actually received rather than the one that was asked for.
      expect(text, isNot(contains('to have answered 200')));
      expect(
        RegExp(r'GET /api/dashboard').allMatches(text).length,
        1,
      );
    });
  });
}
