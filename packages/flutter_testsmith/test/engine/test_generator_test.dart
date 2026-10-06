import 'dart:convert';

import 'package:ai_client/ai_client.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

class _FakeLlm implements LlmClient {
  _FakeLlm({this.reply = '{"scenarios":[]}', this.error});

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

const _evidence = GenerationEvidence(
  appId: 'com.example.ecommerce_app',
  screen: '/product/details',
  entryFlow: 'product_details',
  apiSample: {
    'name': 'Nonveg-Burger',
    'price': 90,
    'discount': 0,
    'available': true,
  },
  elements: ['product.name', 'product.price', 'product.add_to_cart'],
  existingFlows: ['product_details', 'home'],
  coveredConditions: ['available == false'],
  knownScreens: ['/home', '/product/details'],
  fixtures: ['default', 'product_out_of_stock', 'api_500_server_error'],
);

String _scenario({
  String name = 'product_unavailable',
  String? status,
  String steps = '  - launchApp\n  - validateScreen',
}) =>
    jsonEncode({
      'scenarios': [
        {
          'name': name,
          'category': 'api-state',
          'rationale': 'An unavailable product must disable the CTA.',
          'precondition': 'products.json 123 with available=false',
          'confidence': 0.9,
          'flow': 'appId: com.example.ecommerce_app\n'
              'flow: $name\n'
              '${status == null ? '' : 'status: $status\n'}'
              'steps:\n$steps\n',
        },
      ],
    });

Future<GenerationOutcome> _propose(_FakeLlm llm) =>
    TestGenerator(llm).propose(evidence: _evidence);

void main() {
  group('proposing scenarios', () {
    test('parses a scenario and its flow', () async {
      final outcome = await _propose(_FakeLlm(reply: _scenario()));

      final scenario = (outcome as GenerationReady).scenarios.single;
      expect(scenario.name, 'product_unavailable');
      expect(scenario.rationale, contains('unavailable'));
      expect(scenario.precondition, contains('available=false'));
      expect(scenario.flow.appId, 'com.example.ecommerce_app');
    });

    test('stamps every generated flow as proposed', () async {
      // The guarantee the whole phase rests on. A model cannot emit a
      // runnable test, whatever it writes.
      final outcome = await _propose(_FakeLlm(reply: _scenario()));

      final scenario = (outcome as GenerationReady).scenarios.single;
      expect(scenario.flow.isProposed, isTrue);
      expect(scenario.flowYaml, contains('status: proposed'));
    });

    test('overrides a model that marks its own work approved', () async {
      // Asking politely is not a control.
      final outcome =
          await _propose(_FakeLlm(reply: _scenario(status: 'approved')));

      expect((outcome as GenerationReady).scenarios.single.flow.isProposed,
          isTrue);
    });

    test('rejects a scenario whose flow does not parse', () async {
      // A generated file that breaks the suite is worse than no file.
      final outcome = await _propose(
        _FakeLlm(reply: _scenario(steps: '  - tapp:\n      id: x')),
      );

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, isEmpty);
      expect(ready.rejected.single.reason, contains('tapp'));
      expect(ready.rejected.single.name, 'product_unavailable');
    });

    test('rejects a flow expecting a screen that does not exist', () async {
      // Observed from the real model: it wrote `product_details` where
      // the id is `/product/details`. That parses, so the syntax gate
      // waves it through, and it fails only on a device.
      final outcome = await _propose(
        _FakeLlm(
          reply: _scenario(
            steps: '  - launchApp\n  - expectScreen:\n'
                '      id: product_details',
          ),
        ),
      );

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, isEmpty);
      expect(
        ready.rejected.single.reason,
        allOf(contains('product_details'), contains('/product/details')),
      );
    });

    test('rejects a flow tapping an element that does not exist', () async {
      final outcome = await _propose(
        _FakeLlm(
          reply: _scenario(
            steps: '  - launchApp\n  - tap:\n      id: product.invented',
          ),
        ),
      );

      expect((outcome as GenerationReady).rejected.single.reason,
          contains('product.invented'));
    });

    test('accepts a flow that uses the real ids', () async {
      final outcome = await _propose(
        _FakeLlm(
          reply: _scenario(
            steps: '  - launchApp\n  - tap:\n      id: product.add_to_cart\n'
                '  - expectScreen:\n      id: /product/details',
          ),
        ),
      );

      expect((outcome as GenerationReady).scenarios, hasLength(1));
    });

    test('forces the flow name to the scenario name', () async {
      // Also observed: `flow:` came back as the path of the example
      // flow it had been shown.
      final outcome = await _propose(
        _FakeLlm(
          reply: jsonEncode({
            'scenarios': [
              {
                'name': 'zero_price',
                'rationale': 'r',
                'precondition': 'price is 0',
                'flow': 'appId: a\nflow: examples/app/tests/product.yaml\n'
                    'steps:\n  - launchApp\n',
              },
            ],
          }),
        ),
      );

      final scenario = (outcome as GenerationReady).scenarios.single;
      expect(scenario.flow.name, 'zero_price');
      expect(scenario.flowYaml, isNot(contains('.yaml')));
    });

    test('rejects a scenario that reuses an existing flow name', () async {
      // Writing over a reviewed test with an unreviewed one is the
      // worst outcome available here.
      final outcome =
          await _propose(_FakeLlm(reply: _scenario(name: 'product_details')));

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, isEmpty);
      expect(ready.rejected.single.reason, contains('already exists'));
    });

    test('keeps the good scenarios when one is rejected', () async {
      final outcome = await _propose(
        _FakeLlm(
          reply: jsonEncode({
            'scenarios': [
              {
                'name': 'bad',
                'rationale': 'r',
                'precondition': 'anything',
                'flow': 'appId: a\nflow: bad\nsteps:\n  - nope\n',
              },
              {
                'name': 'good',
                'rationale': 'r',
                'precondition': 'anything',
                'flow': 'appId: a\nflow: good\nsteps:\n  - launchApp\n',
              },
            ],
          }),
        ),
      );

      final ready = outcome as GenerationReady;
      expect(ready.scenarios.map((s) => s.name), ['good']);
      expect(ready.rejected.map((r) => r.name), ['bad']);
    });
  });

  group('the state a scenario needs', () {
    test('accepts a flow naming a fixture that exists', () async {
      final outcome = await _propose(
        _FakeLlm(
          reply: jsonEncode({
            'scenarios': [
              {
                'name': 'out_of_stock',
                'rationale': 'r',
                'precondition': 'the product is unavailable',
                'flow': 'appId: a\nflow: out_of_stock\n'
                    'fixture: product_out_of_stock\n'
                    'steps:\n  - launchApp\n',
              },
            ],
          }),
        ),
      );

      final scenario = (outcome as GenerationReady).scenarios.single;
      expect(scenario.flow.fixture, 'product_out_of_stock');
    });

    test('rejects a flow naming a fixture that does not exist', () async {
      // The failure the first real batch made seven times over: a
      // precondition nothing could arrange, in a file that parses.
      final outcome = await _propose(
        _FakeLlm(
          reply: jsonEncode({
            'scenarios': [
              {
                'name': 'empty_highlights_list',
                'rationale': 'r',
                'precondition': 'highlights is []',
                'flow': 'appId: a\nflow: empty_highlights_list\n'
                    'fixture: product_empty_highlights\n'
                    'steps:\n  - launchApp\n',
              },
            ],
          }),
        ),
      );

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, isEmpty);
      expect(
        ready.rejected.single.reason,
        allOf(contains('does not exist'), contains('product_out_of_stock')),
      );
    });

    test('rejects a scenario that says nothing about the state it needs',
        () async {
      final outcome = await _propose(
        _FakeLlm(
          reply: jsonEncode({
            'scenarios': [
              {
                'name': 'vague',
                'rationale': 'r',
                'flow': 'appId: a\nflow: vague\nsteps:\n  - launchApp\n',
              },
            ],
          }),
        ),
      );

      final ready = outcome as GenerationReady;
      expect(ready.scenarios, isEmpty);
      expect(
        ready.rejected.single.reason,
        contains('says nothing about the API state'),
      );
    });

    test('tells the model which fixtures exist', () async {
      final llm = _FakeLlm();
      await _propose(llm);

      expect(llm.received!.user, contains('product_out_of_stock'));
      expect(llm.received!.system, contains('fixturesThatExist'));
    });
  });

  group('what the model is told', () {
    test('carries the response shape and the available elements', () async {
      final llm = _FakeLlm();
      await _propose(llm);

      final sent = llm.received!.user;
      expect(sent, contains('available'));
      expect(sent, contains('product.add_to_cart'));
    });

    test('names the flows that already exist, to avoid duplicates',
        () async {
      final llm = _FakeLlm();
      await _propose(llm);

      expect(llm.received!.user, contains('product_details'));
    });

    test('names the conditions already covered by rules', () async {
      // Proposing a scenario for something already asserted is noise.
      final llm = _FakeLlm();
      await _propose(llm);

      expect(llm.received!.user, contains('available == false'));
    });

    test('constrains the model to the steps that exist', () async {
      // Left free, a model invents `swipe:` and `assertText:` and every
      // proposal is rejected at the parse gate.
      final llm = _FakeLlm();
      await _propose(llm);

      final system = llm.received!.system;
      expect(system, contains('validateScreen'));
      expect(system, contains('expectScreen'));
      expect(system, contains('only these steps'));
    });

    test('tells the model its output is a proposal', () async {
      final llm = _FakeLlm();
      await _propose(llm);

      expect(llm.received!.system.toLowerCase(), contains('proposal'));
    });
  });

  group('when the model cannot help', () {
    test('an outage is an outcome, not an exception', () async {
      final outcome = await _propose(
        _FakeLlm(error: const LlmException('connection refused')),
      );

      expect(outcome, isA<GenerationUnavailable>());
    });

    test('an unparseable reply is an outcome too', () async {
      final outcome = await _propose(_FakeLlm(reply: 'here are some ideas'));

      expect(outcome, isA<GenerationUnavailable>());
    });

    test('no scenarios is ready-but-empty, not a failure', () async {
      final outcome = await _propose(_FakeLlm(reply: '{"scenarios":[]}'));

      expect(outcome, isA<GenerationReady>());
      expect((outcome as GenerationReady).scenarios, isEmpty);
    });
  });
}
