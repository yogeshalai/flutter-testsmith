import 'dart:convert';

import 'package:ai_client/ai_client.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// An LlmClient that answers with whatever the test sets, and records
/// what it was asked.
class _FakeLlm implements LlmClient {
  _FakeLlm({this.reply = '{"summary":"s","findings":[]}', this.error});

  String reply;
  LlmException? error;
  LlmPrompt? received;

  @override
  LlmConfig get config => LlmConfig.defaults;

  @override
  String get describe => 'fake/model';

  @override
  Future<LlmCompletion> complete(LlmPrompt prompt) async {
    received = prompt;
    final failure = error;
    if (failure != null) throw failure;
    return LlmCompletion(content: reply, model: 'fake-model-v1');
  }

  @override
  void close() {}
}

RunResult _run({required List<ValidationResult> results}) => RunResult(
      flowName: 'product_details',
      appId: 'com.example.ecommerce_app',
      device: 'TEST',
      startedAt: DateTime.utc(2026, 9, 11),
      duration: const Duration(seconds: 3),
      steps: const [],
      screens: [
        ScreenResult(
          screenId: '/product/details',
          report: ValidationReport(results),
          exchanges: const [
            ExchangeSummary(
              method: 'GET',
              path: '/products/123',
              statusCode: 200,
              durationMs: 12,
            ),
          ],
        ),
      ],
    );

const _priceFailure = ValidationResult.fail(
  validatorId: 'api-to-ui',
  dimension: ValidationDimension.api,
  elementId: 'product.price',
  message: 'product.price.text does not match response.price. API returned '
      '90; currency(INR) gives "Rs 90"; the UI shows "Rs -,310".',
  expected: 'Rs 90',
  actual: 'Rs -,310',
);

void main() {
  group('FailureAnalyst', () {
    test('does not call the model when nothing failed', () async {
      final llm = _FakeLlm();
      final outcome = await FailureAnalyst(llm).analyse(
        _run(
          results: const [
            ValidationResult.pass(
              validatorId: 'api-to-ui',
              message: 'ok',
              dimension: ValidationDimension.api,
            ),
          ],
        ),
      );

      expect(outcome, isA<AnalysisSkipped>());
      expect(llm.received, isNull);
    });

    test('treats an errored result as needing explanation too', () async {
      // `error` blocks a pass just as `fail` does, so it is a failure
      // worth explaining.
      final llm = _FakeLlm();
      await FailureAnalyst(llm).analyse(
        _run(
          results: const [
            ValidationResult.error(
              validatorId: 'figma-mapping',
              dimension: ValidationDimension.figma,
              message: 'stale mapping',
            ),
          ],
        ),
      );

      expect(llm.received, isNotNull);
    });

    test('explains a failed step, even though no screen was validated',
        () async {
      // A tap that does not land is the commonest failure there is, and
      // it stops the flow before any validation runs. If the analyst
      // only looked at screen results it would have nothing to say
      // about exactly the case people most need explained.
      final llm = _FakeLlm();
      final outcome = await FailureAnalyst(llm).analyse(
        RunResult(
          flowName: 'product_details',
          appId: 'com.example.ecommerce_app',
          device: 'TEST',
          startedAt: DateTime.utc(2026, 9, 11),
          duration: const Duration(seconds: 2),
          screens: const [],
          steps: const [
            StepOutcome(
              description: 'tap "home.open_product"',
              kind: StepKind.tap,
              status: StepStatus.ok,
              durationMs: 40,
            ),
            StepOutcome(
              description: 'tap "product.add_to_cart"',
              kind: StepKind.tap,
              status: StepStatus.failed,
              durationMs: 120,
              detail: 'ElementNotTappableException: it has zero area',
            ),
          ],
        ),
      );

      expect(outcome, isA<AnalysisReady>());

      final sent = llm.received!.user;
      expect(sent, contains('product.add_to_cart'));
      expect(sent, contains('zero area'));
      // The step that worked is not noise worth sending.
      expect(sent, isNot(contains('home.open_product')));
    });

    test('parses a well-formed reply', () async {
      final llm = _FakeLlm(
        reply: jsonEncode({
          'summary': 'The app formats the price incorrectly.',
          'findings': [
            {
              'validatorId': 'api-to-ui',
              'elementId': 'product.price',
              'classification': 'probable_cause',
              'explanation': 'A currency helper subtracts before formatting.',
              'confidence': 0.82,
              'suggestedChecks': ['read formattedPrice'],
            },
          ],
        }),
      );

      final outcome = await FailureAnalyst(llm)
          .analyse(_run(results: const [_priceFailure]));

      final analysis = (outcome as AnalysisReady).analysis;
      expect(analysis.summary, contains('formats the price'));
      expect(analysis.findings.single.classification,
          FindingClass.probableCause);
      expect(analysis.findings.single.confidence, 0.82);
      expect(analysis.findings.single.suggestedChecks, ['read formattedPrice']);
    });

    test('records which model actually answered', () async {
      final outcome = await FailureAnalyst(_FakeLlm())
          .analyse(_run(results: const [_priceFailure]));

      expect((outcome as AnalysisReady).analysis.model, 'fake-model-v1');
      expect(outcome.analysis.provider, 'groq');
    });

    test('an unrecognised classification becomes a hypothesis, never a '
        'certainty', () async {
      // Defaulting the other way would let a malformed reply promote a
      // guess to a proven fact.
      final llm = _FakeLlm(
        reply: jsonEncode({
          'summary': 's',
          'findings': [
            {
              'validatorId': 'api-to-ui',
              'classification': 'definitely_broken',
              'explanation': 'e',
            },
          ],
        }),
      );

      final outcome = await FailureAnalyst(llm)
          .analyse(_run(results: const [_priceFailure]));

      expect(
        (outcome as AnalysisReady).analysis.findings.single.classification,
        FindingClass.hypothesis,
      );
    });

    test('strips a markdown fence, which models add anyway', () async {
      final llm = _FakeLlm(
        reply: '```json\n{"summary":"fenced","findings":[]}\n```',
      );

      final outcome = await FailureAnalyst(llm)
          .analyse(_run(results: const [_priceFailure]));

      expect((outcome as AnalysisReady).analysis.summary, 'fenced');
    });

    test('an unreachable model is unavailable, not a failed run', () async {
      final llm = _FakeLlm(
        error: const LlmException('connection refused', retryable: true),
      );

      final outcome = await FailureAnalyst(llm)
          .analyse(_run(results: const [_priceFailure]));

      expect(outcome, isA<AnalysisUnavailable>());
      expect((outcome as AnalysisUnavailable).reason,
          contains('connection refused'));
    });

    test('an unparseable reply is unavailable, not an exception', () async {
      final llm = _FakeLlm(reply: 'I think the price is wrong.');

      final outcome = await FailureAnalyst(llm)
          .analyse(_run(results: const [_priceFailure]));

      expect(outcome, isA<AnalysisUnavailable>());
    });

    test('clamps a confidence outside 0..1', () async {
      final llm = _FakeLlm(
        reply: jsonEncode({
          'summary': 's',
          'findings': [
            {
              'validatorId': 'v',
              'classification': 'hypothesis',
              'explanation': 'e',
              'confidence': 4.2,
            },
          ],
        }),
      );

      final outcome = await FailureAnalyst(llm)
          .analyse(_run(results: const [_priceFailure]));

      expect((outcome as AnalysisReady).analysis.findings.single.confidence, 1);
    });
  });

  group('what the model is shown', () {
    test('carries the failure, its values and the endpoint', () async {
      final llm = _FakeLlm();
      await FailureAnalyst(llm).analyse(_run(results: const [_priceFailure]));

      final sent = llm.received!.user;
      expect(sent, contains('api-to-ui'));
      expect(sent, contains('product.price'));
      expect(sent, contains('Rs -,310'));
      expect(sent, contains('/products/123'));
    });

    test('sends no request or response bodies, and no headers', () async {
      // Redaction already strips secrets at capture. Not sending the
      // payload at all is the cheaper guarantee.
      final llm = _FakeLlm();
      await FailureAnalyst(llm).analyse(_run(results: const [_priceFailure]));

      final sent = llm.received!.user.toLowerCase();
      expect(sent, isNot(contains('authorization')));
      expect(sent, isNot(contains('bearer')));
      expect(sent, isNot(contains('body')));
      expect(sent, isNot(contains('header')));
    });

    test('asks the provider for JSON', () async {
      final llm = _FakeLlm();
      await FailureAnalyst(llm).analyse(_run(results: const [_priceFailure]));

      expect(llm.received!.jsonMode, isTrue);
    });

    test('tells the model it is not deciding anything', () async {
      final llm = _FakeLlm();
      await FailureAnalyst(llm).analyse(_run(results: const [_priceFailure]));

      final system = llm.received!.system.toLowerCase();
      expect(system, contains('already happened'));
      expect(system, contains('never contradict'));
    });

    test('forbids labelling a causal claim as confirmed', () async {
      // Without this rule the model wrote "likely due to layout
      // changes" and classified it confirmed_failure, which is exactly
      // the confusion the three levels exist to prevent.
      final llm = _FakeLlm();
      await FailureAnalyst(llm).analyse(_run(results: const [_priceFailure]));

      final system = llm.received!.system.toLowerCase();
      expect(system, contains('not confirmed_failure'));
      expect(system, contains('because'));
    });

    test('asks for the cause as a separate finding from the facts',
        () async {
      // The opposite failure mode: told only to avoid unproven claims,
      // the model restated measurements and explained nothing.
      final llm = _FakeLlm();
      await FailureAnalyst(llm).analyse(_run(results: const [_priceFailure]));

      expect(llm.received!.system, contains('SEPARATE finding'));
    });

    test('tells the model that off-screen means not evaluated', () async {
      final llm = _FakeLlm();
      await FailureAnalyst(llm).analyse(_run(results: const [_priceFailure]));

      expect(llm.received!.system, contains('off-screen and not compared'));
      expect(llm.received!.system, contains('not a defect'));
    });
  });

  group('the verdict is not the model\'s to change', () {
    test('a run stays failed however the analysis reads', () async {
      // The strongest possible contradiction: the model says everything
      // is fine. The run must still be a failure.
      final llm = _FakeLlm(
        reply: jsonEncode({
          'summary': 'Everything looks correct; no real problem here.',
          'findings': [
            {
              'validatorId': 'api-to-ui',
              'classification': 'hypothesis',
              'explanation': 'This is probably a false alarm.',
              'confidence': 0.99,
            },
          ],
        }),
      );

      final result = _run(results: const [_priceFailure]);
      expect(result.passed, isFalse);

      final outcome = await FailureAnalyst(llm).analyse(result);

      expect(outcome, isA<AnalysisReady>());
      expect(result.passed, isFalse);
      expect(result.screens.single.report.failures, hasLength(1));
    });

    test('a ValidationResult still has no confidence field', () async {
      // Confidence belongs to AI suggestions only. If this ever starts
      // failing, the line between measurement and opinion has moved.
      const result = _priceFailure;
      final json = result.toJson();

      expect(json.containsKey('confidence'), isFalse);
    });
  });
}
