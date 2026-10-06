import 'dart:convert';

import 'package:flutter_testsmith/ai.dart';

import '../reporting/run_result.dart';
import '../validation/validation_result.dart';
import 'ai_analysis.dart';

/// Asks a model to explain failures the engine has already decided.
///
/// The ordering is the whole design. Verdicts are computed, the run's
/// pass or fail is fixed, and only then is a model shown what failed.
/// It cannot change an outcome because by the time it is asked there is
/// no outcome left to change - the guarantee is structural rather than
/// a rule someone has to remember.
class FailureAnalyst {
  const FailureAnalyst(this.client);

  final LlmClient client;

  /// The instructions, tuned against real output rather than guessed.
  ///
  /// Two rules here were added because the model broke them. Without
  /// the "decisive test", it labelled "likely due to layout changes" as
  /// `confirmed_failure` - an unproven cause wearing the word
  /// confirmed, which is the single thing this classification exists to
  /// prevent. Without the instruction to split fact from cause, it then
  /// over-corrected into restating measurements and offering no
  /// explanation at all, which is honest and useless.
  static const String _system = '''
You analyse results from a deterministic Flutter UI test platform.

Every failure listed below ALREADY HAPPENED. Exact comparisons decided
that before you were asked, and you cannot change it. Nothing you write
is a verdict, and you must never contradict one.

Your job is to explain WHY, and to be honest about how much the data
supports each explanation.

The classification describes YOUR STATEMENT, not the failure:

  "confirmed_failure" - you only restate measured facts. No causal
                        claim of any kind.
  "probable_cause"    - you assert a cause, and the supplied data
                        supports it.
  "hypothesis"        - you assert a cause the data does not establish.

Decisive test: if your explanation contains a causal claim - "because",
"due to", "caused by", "suggests", "indicates", "likely from" - then it
is NOT confirmed_failure. It is probable_cause if the data supports it
and hypothesis otherwise. Do not label a guess as confirmed.

Restating facts alone is not useful. For each distinct problem, also
add a SEPARATE finding that proposes the most likely cause, classified
probable_cause or hypothesis. Keep the two apart: one finding says what
was measured, another says what you think caused it.

Reading the data:
- An element reported as "off-screen and not compared" was NOT
  evaluated. That is not a defect and is not evidence of one.
- A percentage "of its own area" is that element's own pixels, not the
  screen's.
- A "failedSteps" entry stopped the flow, so anything after it was
  never reached and cannot be judged.
- Do not invent field names, endpoints or elements not in the data.
- If several failures share one cause, say so once; that is the most
  useful thing you can contribute.
- If the data cannot explain something, say so rather than guessing.

Reply with a JSON object only:
{
  "summary": "one or two sentences on what is most likely wrong",
  "findings": [
    {
      "validatorId": "<copied from the failure>",
      "elementId": "<copied, or omit>",
      "classification": "confirmed_failure|probable_cause|hypothesis",
      "explanation": "<why this happened>",
      "confidence": 0.0,
      "suggestedChecks": ["<what a person should look at next>"]
    }
  ]
}
''';

  /// Explains the failures in [result], if there are any.
  ///
  /// Never throws. A provider outage, a timeout or an unparseable reply
  /// all produce [AnalysisUnavailable]: the run's verdicts stand either
  /// way, and failing a build because a language model was down would
  /// be indefensible.
  Future<AnalysisOutcome> analyse(RunResult result) async {
    final failures = _failures(result);
    final brokenSteps = [
      for (final step in result.steps)
        if (step.status == StepStatus.failed) step,
    ];

    // A step that failed stops the flow before anything is validated,
    // so a run can fail with no screen results at all. That is the
    // commonest failure there is - a tap that did not land - and it
    // would be perverse to have nothing to say about it.
    if (failures.isEmpty && brokenSteps.isEmpty) {
      return const AnalysisSkipped(
        'nothing failed, so there was nothing to explain',
      );
    }

    final LlmCompletion completion;
    try {
      completion = await client.complete(
        LlmPrompt(
          system: _system,
          user: jsonEncode(_evidence(result, failures, brokenSteps)),
          jsonMode: true,
        ),
      );
    } on LlmException catch (error) {
      return AnalysisUnavailable('${client.describe}: ${error.message}');
    } catch (error) {
      return AnalysisUnavailable('${client.describe}: $error');
    }

    final Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(_unwrap(completion.content)) as Map)
          .cast<String, Object?>();
    } on FormatException catch (error) {
      return AnalysisUnavailable(
        '${client.describe} did not return usable JSON: ${error.message}',
      );
    } on TypeError {
      return AnalysisUnavailable(
        '${client.describe} returned JSON that was not an object',
      );
    }

    return AnalysisReady(
      AiAnalysis(
        provider: client.config.provider,
        model: completion.model,
        generatedAt: DateTime.now().toUtc(),
        summary: (decoded['summary'] ?? '').toString(),
        promptTokens: completion.promptTokens,
        completionTokens: completion.completionTokens,
        latency: completion.latency,
        findings: [
          for (final raw in (decoded['findings'] as List?) ?? const [])
            if (raw is Map)
              AiFinding.fromJson(raw.cast<String, Object?>()),
        ],
      ),
    );
  }

  /// Every result that blocks a pass, with the screen it came from.
  static List<({String screen, ValidationResult result})> _failures(
    RunResult result,
  ) =>
      [
        for (final screen in result.screens)
          for (final r in screen.report.results)
            if (r.blocksPass) (screen: screen.screenId, result: r),
      ];

  /// What the model is shown.
  ///
  /// Deliberately narrow. Request and response **bodies are never
  /// sent**, nor are headers: redaction already removed secrets at
  /// capture, but the cheapest way to keep customer data out of a third
  /// party is not to send it. Endpoints, status codes and the
  /// validators' own messages carry enough to reason about a cause.
  static Map<String, Object?> _evidence(
    RunResult result,
    List<({String screen, ValidationResult result})> failures,
    List<StepOutcome> brokenSteps,
  ) =>
      {
        'flow': result.flowName,
        // Only the steps that failed. Sending the ones that worked
        // would bury the one that matters in a transcript.
        if (brokenSteps.isNotEmpty)
          'failedSteps': [
            for (final step in brokenSteps)
              {
                'step': step.description,
                if (step.detail != null) 'detail': step.detail,
              },
          ],
        'screens': [
          for (final screen in result.screens)
            {
              'screen': screen.screenId,
              'passed': screen.report.passed,
              'api': [
                for (final exchange in screen.exchanges)
                  {
                    'method': exchange.method,
                    'path': exchange.path,
                    if (exchange.statusCode != null)
                      'status': exchange.statusCode,
                    if (exchange.error != null) 'error': exchange.error,
                  },
              ],
            },
        ],
        'failures': [
          for (final failure in failures)
            {
              'screen': failure.screen,
              'validatorId': failure.result.validatorId,
              'status': failure.result.status.wire,
              if (failure.result.elementId != null)
                'elementId': failure.result.elementId,
              'message': failure.result.message,
              if (failure.result.expected != null)
                'expected': failure.result.expected.toString(),
              if (failure.result.actual != null)
                'actual': failure.result.actual.toString(),
            },
        ],
      };

  /// Strips a markdown fence, which models add even when asked not to.
  static String _unwrap(String content) {
    final text = content.trim();
    if (!text.startsWith('```')) return text;

    final firstNewline = text.indexOf('\n');
    if (firstNewline == -1) return text;

    final withoutOpening = text.substring(firstNewline + 1);
    final closing = withoutOpening.lastIndexOf('```');
    return (closing == -1 ? withoutOpening : withoutOpening.substring(0, closing))
        .trim();
  }
}
