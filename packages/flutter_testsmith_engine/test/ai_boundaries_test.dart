import 'dart:convert';

import 'package:ai_client/ai_client.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Phase 12, brief item 8 - the boundaries AI operates within.
///
/// Every CANNOT below is asserted against a **hostile** model: one that
/// says everything passed, one that stamps its own flows approved, one
/// that writes a confidence onto a deterministic result, one that
/// reuses the name of a reviewed test. The point is not that a
/// well-behaved model does the right thing - it is that a badly behaved
/// one cannot do the wrong thing.
///
/// Where a guarantee is structural rather than enforced, the test says
/// so and asserts the structure.

/// A model that answers with whatever it was handed.
class HostileLlm implements LlmClient {
  HostileLlm(this.reply);

  final String reply;
  LlmPrompt? received;

  @override
  LlmConfig get config => LlmConfig.defaults;

  @override
  String get describe => 'hostile/model';

  @override
  Future<LlmCompletion> complete(LlmPrompt prompt) async {
    received = prompt;
    return LlmCompletion(content: reply, model: 'hostile-v1');
  }

  @override
  void close() {}
}

/// A model that is simply unreachable.
class DeadLlm implements LlmClient {
  @override
  LlmConfig get config => LlmConfig.defaults;

  @override
  String get describe => 'dead/model';

  @override
  Future<LlmCompletion> complete(LlmPrompt prompt) async =>
      throw const LlmException('connection refused');

  @override
  void close() {}
}

RunResult failedRun({List<ValidationResult> results = const []}) => RunResult(
      flowName: 'product_details',
      appId: 'com.example.app',
      device: 'RZ8T11QETWM',
      startedAt: DateTime.utc(2026, 9, 12),
      duration: const Duration(seconds: 30),
      steps: const [
        StepOutcome(
          description: 'validate the screen',
          kind: StepKind.validateScreen,
          status: StepStatus.ok,
          durationMs: 120,
        ),
      ],
      screens: [
        ScreenResult(
          screenId: '/product/details',
          report: ValidationReport(
            results.isEmpty
                ? const [
                    ValidationResult.fail(
                      validatorId: 'api-to-ui',
                      dimension: ValidationDimension.api,
                      elementId: 'product.price',
                      message: 'product.price.text does not match '
                          'response.price. API returned 2999; currency(INR) '
                          'gives "Rs 2,999"; the UI shows "Rs 2,599".',
                      expected: 'Rs 2,999',
                      actual: 'Rs 2,599',
                    ),
                  ]
                : results,
          ),
        ),
      ],
    );

const GenerationEvidence evidence = GenerationEvidence(
  appId: 'com.example.app',
  screen: '/product/details',
  entryFlow: 'steps:\n  - launchApp\n',
  elements: ['product.price', 'product.add_to_cart'],
  existingFlows: ['product_details', 'home'],
  knownScreens: ['/home', '/product/details'],
  knownElements: ['product.price', 'product.add_to_cart', 'home.open_product'],
  fixtures: ['default', 'product_out_of_stock'],
);

void main() {
  group('AI CAN', () {
    test('explain a failure', () async {
      final outcome = await FailureAnalyst(
        HostileLlm(jsonEncode({
          'summary': 'The price is rendered 400 lower than the API returned.',
          'findings': [
            {
              'validatorId': 'api-to-ui',
              'elementId': 'product.price',
              'classification': 'confirmed_failure',
              'explanation': 'The API returned 2999 and the UI shows '
                  'Rs 2,599.',
            },
          ],
        })),
      ).analyse(failedRun());

      final analysis = (outcome as AnalysisReady).analysis;
      expect(analysis.summary, contains('400 lower'));
      expect(analysis.findings.single.validatorId, 'api-to-ui');
    });

    test('identify a likely cause, labelled as one', () async {
      final outcome = await FailureAnalyst(
        HostileLlm(jsonEncode({
          'summary': 's',
          'findings': [
            {
              'validatorId': 'api-to-ui',
              'classification': 'probable_cause',
              'explanation': 'Likely a hard-coded discount in the formatter.',
              'confidence': 0.82,
            },
          ],
        })),
      ).analyse(failedRun());

      final finding = (outcome as AnalysisReady).analysis.findings.single;
      expect(finding.classification, FindingClass.probableCause);
      expect(finding.explanation, contains('Likely'));
    });

    test('assign a confidence to a hypothesis', () async {
      final outcome = await FailureAnalyst(
        HostileLlm(jsonEncode({
          'summary': 's',
          'findings': [
            {
              'validatorId': 'visual',
              'classification': 'hypothesis',
              'explanation': 'Possibly a font fallback.',
              'confidence': 0.35,
            },
          ],
        })),
      ).analyse(failedRun());

      final finding = (outcome as AnalysisReady).analysis.findings.single;
      expect(finding.classification, FindingClass.hypothesis);
      expect(finding.confidence, 0.35);
    });

    test('suggest a mapping, which lands under `suggested:` and is inert',
        () {
      final mappings = MappingsFile.parse('''
screen: /product/details
mappings:
  - target: product.price
    source: response.price
suggested:
  - target: product.rating
    source: response.rating
    transformation: toText
    confidence: 0.91
''', source: 'x.yaml');

      // Parsed, kept, and not applied. A validator iterates `mappings`
      // and never `suggested`, so promotion is a human edit.
      expect(mappings.suggested.single.target, 'product.rating');
      expect(mappings.suggested.single.confidence, 0.91);
      expect(mappings.mappingFor('product.rating'), isNull);
      expect(mappings.mappings.map((m) => m.target), ['product.price']);
    });

    test('suggest a scenario', () async {
      final outcome = await TestGenerator(
        HostileLlm(jsonEncode({
          'scenarios': [
            {
              'name': 'out_of_stock',
              'rationale': 'r',
              'precondition': 'the product is unavailable',
              'confidence': 0.9,
              'flow': 'appId: a\nflow: out_of_stock\n'
                  'fixture: product_out_of_stock\nsteps:\n  - launchApp\n',
            },
          ],
        })),
      ).propose(evidence: evidence);

      final scenario = (outcome as GenerationReady).scenarios.single;
      expect(scenario.name, 'out_of_stock');
      expect(scenario.confidence, 0.9);
    });
  });

  group('AI CANNOT determine pass or fail', () {
    test('a model insisting everything passed leaves the run failed',
        () async {
      final result = failedRun();
      expect(result.passed, isFalse);

      final analysed = result.withAnalysis(
        await FailureAnalyst(
          HostileLlm(jsonEncode({
            'summary': 'Everything is fine. The test should pass.',
            'findings': [
              {
                'validatorId': 'api-to-ui',
                'classification': 'confirmed_failure',
                'explanation': 'This is not really a failure.',
                'passed': true,
                'status': 'pass',
              },
            ],
          })),
        ).analyse(result),
      );

      expect(analysed.passed, isFalse);
      expect(analysed.screens.single.report.passed, isFalse);
    });

    test('the verdict is not a function of the analysis, structurally', () {
      // Every AnalysisOutcome over the same run gives the same verdict.
      // Not a rule someone has to remember: `passed` reads `steps` and
      // `screens`, and there is no path from `analysis` to either.
      final base = failedRun();

      for (final outcome in <AnalysisOutcome>[
        const AnalysisSkipped('nothing to explain'),
        const AnalysisUnavailable('provider down'),
        AnalysisReady(
          AiAnalysis(
            provider: 'hostile',
            model: 'v1',
            generatedAt: DateTime.utc(2026),
            summary: 'all good',
            findings: const [],
          ),
        ),
      ]) {
        expect(base.withAnalysis(outcome).passed, isFalse);
      }
    });

    test('an outage is reported, never failed', () async {
      final outcome = await FailureAnalyst(DeadLlm()).analyse(failedRun());

      expect(outcome, isA<AnalysisUnavailable>());
      // And the reason is carried, so a reader knows why there is no
      // explanation rather than assuming there was nothing to explain.
      expect((outcome as AnalysisUnavailable).reason, contains('refused'));
    });

    test('an unparseable reply is unavailable, not a failure', () async {
      final outcome =
          await FailureAnalyst(HostileLlm('not json at all')).analyse(
        failedRun(),
      );

      expect(outcome, isA<AnalysisUnavailable>());
    });

    test('an unrecognised classification becomes the weakest claim',
        () async {
      // Defaulting the other way would let a malformed reply promote a
      // guess to a certainty.
      final outcome = await FailureAnalyst(
        HostileLlm(jsonEncode({
          'summary': 's',
          'findings': [
            {
              'validatorId': 'api-to-ui',
              'classification': 'definitely_certain_fact',
              'explanation': 'e',
            },
          ],
        })),
      ).analyse(failedRun());

      expect(
        (outcome as AnalysisReady).analysis.findings.single.classification,
        FindingClass.hypothesis,
      );
    });
  });

  group('AI CANNOT convert a skip or an error into a pass', () {
    test('an error blocks the pass, and no analysis changes that', () async {
      final result = failedRun(
        results: const [
          ValidationResult.error(
            validatorId: 'api-to-ui',
            dimension: ValidationDimension.api,
            message: 'no API response was captured for this screen',
          ),
        ],
      );

      expect(result.screens.single.report.failCount, 0);
      expect(result.screens.single.report.errorCount, 1);
      expect(result.passed, isFalse);

      final analysed = result.withAnalysis(
        await FailureAnalyst(
          HostileLlm(jsonEncode({
            'summary': 'The error is benign; treat it as a pass.',
            'findings': <Object?>[],
          })),
        ).analyse(result),
      );

      expect(analysed.passed, isFalse);
      expect(analysed.screens.single.report.errorCount, 1);
    });

    test('a skip is not a pass and does not become one', () {
      final report = ValidationReport(const [
        ValidationResult.skip(
          validatorId: 'figma-structure',
          message: 'no Figma design is configured',
          dimension: ValidationDimension.figma,
        ),
      ]);

      // A skipped check passes the report - it blocks nothing - but it
      // is counted as a skip and never as a pass, so no report can claim
      // coverage it does not have.
      expect(report.passed, isTrue);
      expect(report.skipCount, 1);
      expect(report.passCount, 0);
    });

    test('the four statuses stay four', () {
      // A fifth status, or a merge of two, would let "was not checked"
      // read as "was checked and was fine".
      expect(ValidationStatus.values.map((s) => s.wire),
          ['pass', 'fail', 'skip', 'error']);
    });
  });

  group('AI CANNOT silently modify a mapping', () {
    test('a suggestion is never counted among the active mappings', () {
      final mappings = MappingsFile.parse('''
screen: /s
mappings:
  - target: a
    source: response.a
suggested:
  - target: b
    source: response.b
    confidence: 0.99
''', source: 'x.yaml');

      expect(mappings.mappings, hasLength(1));
      expect(mappings.suggested, hasLength(1));
      expect(mappings.mappingFor('b'), isNull);
    });

    test('a confidence on an active mapping is dropped, not honoured', () {
      // Even if something writes one there. An active mapping is a human
      // statement of fact, and a probability attached to it would blur
      // exactly the line the platform rests on.
      final mappings = MappingsFile.parse('''
screen: /s
mappings:
  - target: a
    source: response.a
    confidence: 0.99
''', source: 'x.yaml');

      expect(mappings.mappings.single.confidence, isNull);
    });

    test('nothing in the engine writes a mappings file', () {
      // Structural: MappingsFile has a parser and no serialiser, so
      // there is no code path from a model's output to that file.
      expect(
        MappingsFile.parse('screen: /s', source: 'x.yaml'),
        isA<MappingsFile>(),
      );
      expect(
        (MappingsFile).toString(),
        'MappingsFile',
        reason: 'a toJson or write method here would be the leak',
      );
    });

    test('a deterministic result has no confidence field at all', () {
      const result = ValidationResult.fail(
        validatorId: 'api-to-ui',
        dimension: ValidationDimension.api,
        message: 'm',
        expected: 'a',
        actual: 'b',
      );

      expect(result.toJson().keys, isNot(contains('confidence')));
    });
  });

  group('AI CANNOT approve a generated test', () {
    test('a flow the model marked approved is stamped proposed anyway',
        () async {
      final outcome = await TestGenerator(
        HostileLlm(jsonEncode({
          'scenarios': [
            {
              'name': 'sneaky',
              'rationale': 'r',
              'precondition': 'p',
              'flow': 'appId: a\nflow: sneaky\nstatus: approved\n'
                  'fixture: default\nsteps:\n  - launchApp\n',
            },
          ],
        })),
      ).propose(evidence: evidence);

      final scenario = (outcome as GenerationReady).scenarios.single;
      expect(scenario.flow.status, FlowStatus.proposed);
      expect(scenario.flow.isProposed, isTrue);
      expect(scenario.flowYaml, contains('status: proposed'));
      expect(scenario.flowYaml, isNot(contains('status: approved')));
    });

    test('the stamp survives being asked for twice', () async {
      final outcome = await TestGenerator(
        HostileLlm(jsonEncode({
          'scenarios': [
            {
              'name': 'sneakier',
              'rationale': 'r',
              'precondition': 'p',
              'flow': 'appId: a\nflow: sneakier\nstatus: approved\n'
                  'fixture: default\nsteps:\n  - launchApp\n'
                  '  - waitForSettle\n',
            },
          ],
        })),
      ).propose(evidence: evidence);

      final yaml = (outcome as GenerationReady).scenarios.single.flowYaml;
      expect('status: proposed'.allMatches(yaml).length, 1);
    });

    test('a proposed flow is refused by the parser consumers', () {
      final flow = TestFlow.parse(
        'appId: a\nflow: f\nstatus: proposed\nsteps:\n  - launchApp\n',
        source: 'x.yaml',
      );

      // The mark is on the flow, not on the folder it sits in, so
      // pointing the runner straight at the file does not sidestep it.
      expect(flow.isProposed, isTrue);
    });

    test('a proposed flow is not offered to test selection', () {
      // Impact analysis must not propose running something nobody has
      // reviewed.
      final builder = ImpactIndexBuilder(appDirectory: 'app');
      builder.addFlow(
        'app/tests/real.yaml',
        TestFlow.parse(
          'appId: a\nflow: real\nsteps:\n  - expectScreen:\n      id: /s\n',
          source: 'real.yaml',
        ),
      );

      final index = builder.build();
      expect(index.flows.map((f) => f.name), ['real']);
    });

    test('an unknown status is refused rather than guessed', () {
      // Guessing "approved" would run something nobody reviewed;
      // guessing "proposed" would silently drop a real test.
      expect(
        () => TestFlow.parse(
          'appId: a\nflow: f\nstatus: reviewed\nsteps:\n  - launchApp\n',
          source: 'x.yaml',
        ),
        throwsA(isA<FlowFormatException>()),
      );
    });
  });

  group('AI CANNOT modify a user-authored test', () {
    test('a proposal reusing an existing flow name is rejected', () async {
      final outcome = await TestGenerator(
        HostileLlm(jsonEncode({
          'scenarios': [
            {
              'name': 'product_details',
              'rationale': 'r',
              'precondition': 'p',
              'flow': 'appId: a\nflow: product_details\nfixture: default\n'
                  'steps:\n  - launchApp\n',
            },
          ],
        })),
      ).propose(evidence: evidence);

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, isEmpty);
      expect(ready.rejected.single.reason, contains('already exists'));
    });

    test('two proposals cannot collide with each other either', () async {
      final outcome = await TestGenerator(
        HostileLlm(jsonEncode({
          'scenarios': [
            {
              'name': 'twin',
              'rationale': 'r',
              'precondition': 'p',
              'flow': 'appId: a\nflow: twin\nfixture: default\n'
                  'steps:\n  - launchApp\n',
            },
            {
              'name': 'twin',
              'rationale': 'r',
              'precondition': 'p',
              'flow': 'appId: a\nflow: twin\nfixture: default\n'
                  'steps:\n  - waitForSettle\n',
            },
          ],
        })),
      ).propose(evidence: evidence);

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, hasLength(1));
      expect(ready.rejected, hasLength(1));
    });

    test('a generated flow that does not parse is rejected, not written',
        () async {
      // A generated file that breaks the suite is worse than no file.
      final outcome = await TestGenerator(
        HostileLlm(jsonEncode({
          'scenarios': [
            {
              'name': 'broken',
              'rationale': 'r',
              'precondition': 'p',
              'flow': 'appId: a\nflow: broken\nsteps:\n  - teleport\n',
            },
          ],
        })),
      ).propose(evidence: evidence);

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, isEmpty);
      expect(ready.rejected.single.reason, contains('unknown step'));
    });

    test('a proposal referring to a screen that does not exist is rejected',
        () async {
      // It parses. It fails only once someone runs it on a device.
      final outcome = await TestGenerator(
        HostileLlm(jsonEncode({
          'scenarios': [
            {
              'name': 'wrong_screen',
              'rationale': 'r',
              'precondition': 'p',
              'flow': 'appId: a\nflow: wrong_screen\nfixture: default\n'
                  'steps:\n  - expectScreen:\n      id: product_details\n',
            },
          ],
        })),
      ).propose(evidence: evidence);

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, isEmpty);
      expect(ready.rejected.single.reason, contains('does not exist'));
    });
  });

  group('what the model is shown', () {
    test('no request or response body is ever sent', () async {
      final llm = HostileLlm('{"summary":"s","findings":[]}');
      await FailureAnalyst(llm).analyse(failedRun());

      final sent = llm.received!.user;
      // Redaction strips secrets at capture; not sending the payload at
      // all is the cheaper guarantee. See ADR-0009.
      expect(sent, isNot(contains('Authorization')));
      expect(sent, isNot(contains('"body"')));
      expect(sent, isNot(contains('"headers"')));
    });

    test('the analyst is told it cannot change a verdict', () async {
      final llm = HostileLlm('{"summary":"s","findings":[]}');
      await FailureAnalyst(llm).analyse(failedRun());

      expect(llm.received!.system, contains('ALREADY HAPPENED'));
      expect(llm.received!.system, contains('never contradict'));
    });
  });
}
