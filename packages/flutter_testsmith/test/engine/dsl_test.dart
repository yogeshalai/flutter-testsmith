import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

const String productFlow = '''
appId: com.example.ecommerce_app
flow: product_purchase

steps:
  - launchApp
  - waitForSettle
  - tap:
      id: home.open_product
  - expectScreen:
      id: /product/details
  - waitForSettle
  - validateScreen:
      api: true
      ui: true
      rules: true
  - screenshot:
      name: product-details
''';

void main() {
  fixtureTests();
  expectElementTests();
  main2();
  main3();
  group('parsing a flow', () {
    final flow = TestFlow.parse(productFlow, source: 'product.yaml');

    test('reads the header', () {
      expect(flow.appId, 'com.example.ecommerce_app');
      expect(flow.name, 'product_purchase');
    });

    test('reads every step in order', () {
      expect(
        flow.steps.map((Step s) => s.runtimeType.toString()),
        [
          'LaunchAppStep',
          'WaitForSettleStep',
          'TapStep',
          'ExpectScreenStep',
          'WaitForSettleStep',
          'ValidateScreenStep',
          'ScreenshotStep',
        ],
      );
    });

    test('reads a step with arguments', () {
      final tap = flow.steps.whereType<TapStep>().single;
      expect(tap.elementId, 'home.open_product');
    });

    test('reads which validators a validateScreen names explicitly', () {
      final validate = flow.steps.whereType<ValidateScreenStep>().single;

      expect(validate.api, isTrue);
      expect(validate.ui, isTrue);
      expect(validate.rules, isTrue);
      // Absent, which means "decide automatically" rather than "off".
      expect(validate.figma, isNull);
      expect(validate.visual, isNull);
    });
  });

  group('validateScreen with nothing named', () {
    ValidateScreenStep parse(String step) => TestFlow.parse(
          'appId: a\nflow: f\nsteps:\n$step\n',
          source: 'f.yaml',
        ).steps.whereType<ValidateScreenStep>().single;

    test('runs everything that only reads', () {
      // The specification asks for a bare `validateScreen` that does the
      // work without a list of flags. Before this, a bare step validated
      // literally nothing and said so.
      final step = parse('  - validateScreen');

      expect(step.runsApi, isTrue);
      expect(step.runsUi, isTrue);
      expect(step.runsRules, isTrue);
      expect(step.runsFigma, isTrue);
    });

    test('leaves each validator to explain what it lacks', () {
      // Enabling everything is safe precisely because a validator with
      // no configuration skips with a reason instead of failing. The
      // report then shows every check, each either a result or a stated
      // reason it could not run.
      expect(parse('  - validateScreen').runsFigma, isTrue);
    });

    test('records a screenshot baseline only when one already exists', () {
      // Everything else only reads. Recording a baseline writes a file
      // into the repository, and that should be a decision someone
      // made, not a side effect of running the suite.
      final step = parse('  - validateScreen');

      expect(step.runsVisual(hasBaseline: true), isTrue);
      expect(step.runsVisual(hasBaseline: false), isFalse);
    });

    test('an explicit request records one even on a first run', () {
      final step = parse('  - validateScreen:\n      visual: true');

      expect(step.runsVisual(hasBaseline: false), isTrue);
    });

    test('an explicit false still turns one off', () {
      final step = parse('  - validateScreen:\n      figma: false');

      expect(step.runsFigma, isFalse);
      // The others stay automatic.
      expect(step.runsApi, isTrue);
    });

    test('describes itself as automatic', () {
      expect(parse('  - validateScreen').describe(), contains('automatic'));
    });

    test('describes what was named, and says the rest is automatic', () {
      // Naming one validator must not read as "only this one runs".
      final step = parse('  - validateScreen:\n      api: true');

      expect(step.describe(), contains('api'));
      expect(step.describe(), contains('rest automatic'));
    });

    test('marks a validator that was explicitly turned off', () {
      final step = parse('  - validateScreen:\n      visual: false');

      expect(step.describe(), contains('visual:off'));
    });

    test('a bare step needs no arguments', () {
      expect(
        TestFlow.parse(productFlow, source: 'product.yaml').steps.first,
        isA<LaunchAppStep>(),
      );
    });
  });

  group('rejecting a bad flow', () {
    test('an unknown step is an error naming the line', () {
      // A typo'd step that silently does nothing is the worst possible
      // outcome: the run reports green having tested nothing.
      expect(
        () => TestFlow.parse(
          'appId: a\nflow: f\nsteps:\n  - launchApp\n  - expectScreeen:\n'
          '      id: Home\n',
          source: 'product.yaml',
        ),
        throwsA(
          isA<FlowFormatException>()
              .having((e) => e.toString(), 'message', contains('expectScreeen'))
              .having((e) => e.toString(), 'message', contains('expectScreen'))
              .having((e) => e.toString(), 'message', contains('line 5')),
        ),
      );
    });

    test('an unknown argument to a known step is an error', () {
      expect(
        () => TestFlow.parse(
          'appId: a\nflow: f\nsteps:\n  - tap:\n      identifier: x\n',
          source: 'product.yaml',
        ),
        throwsA(
          isA<FlowFormatException>()
              .having((e) => e.toString(), 'message', contains('identifier')),
        ),
      );
    });

    test('a missing required argument is an error', () {
      expect(
        () => TestFlow.parse(
          'appId: a\nflow: f\nsteps:\n  - tap:\n      text: x\n',
          source: 'product.yaml',
        ),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('a flow without steps is an error', () {
      expect(
        () => TestFlow.parse('appId: a\nflow: f\n', source: 'product.yaml'),
        throwsA(
          isA<FlowFormatException>()
              .having((e) => e.toString(), 'message', contains('steps')),
        ),
      );
    });

    test('a flow without an appId is an error', () {
      expect(
        () => TestFlow.parse(
          'flow: f\nsteps:\n  - launchApp\n',
          source: 'product.yaml',
        ),
        throwsA(
          isA<FlowFormatException>()
              .having((e) => e.toString(), 'message', contains('appId')),
        ),
      );
    });

    test('the error names the file', () {
      expect(
        () => TestFlow.parse('nope', source: 'flows/product.yaml'),
        throwsA(
          isA<FlowFormatException>().having(
            (e) => e.toString(),
            'message',
            contains('flows/product.yaml'),
          ),
        ),
      );
    });

    // A value of the wrong *type*, as distinct from the unknown names
    // above. `optionalBool` has always said "a mistyped value must not
    // quietly become one"; `text`, `textContains` and `timeoutMs` beside
    // it were casts, so `timeoutMs: "5s"` left the parser as a
    // `TypeError` - not a FlowFormatException, which is what every
    // caller guards - and the command exited 255 with a stack trace.
    group('a value of the wrong type', () {
      void expectRejected(String yaml, String names) {
        expect(
          () => TestFlow.parse(yaml, source: 'flows/product.yaml'),
          throwsA(
            isA<FlowFormatException>()
                .having((e) => e.toString(), 'message', contains(names))
                .having((e) => e.toString(), 'source',
                    contains('flows/product.yaml')),
          ),
          reason: yaml,
        );
      }

      test('"flow" given a number', () {
        expectRejected('appId: a\nflow: 123\nsteps:\n  - launchApp\n', 'flow');
      });

      test('"timeoutMs" given text', () {
        // The natural way to get this wrong.
        expectRejected(
          'appId: a\nflow: f\nsteps:\n'
          '  - expectElement: {id: a, timeoutMs: "5s"}\n',
          'timeoutMs',
        );
      });

      test('"timeoutMs" given text on a step with no other arguments', () {
        expectRejected(
          'appId: a\nflow: f\nsteps:\n  - waitForSettle: {timeoutMs: soon}\n',
          'timeoutMs',
        );
      });

      test('"timeoutMs" given text on expectApi, parsed elsewhere', () {
        // A different function, and so outside the closures the steps
        // above share. Same field, same answer.
        expectRejected(
          'appId: a\nflow: f\nsteps:\n'
          '  - expectApi: {endpoint: GET /a, status: 200, timeoutMs: soon}\n',
          'timeoutMs',
        );
      });

      test('"text" given a number', () {
        expectRejected(
          'appId: a\nflow: f\nsteps:\n'
          '  - expectElement: {id: a, text: 12}\n',
          'text',
        );
      });

      test('"textContains" given a number', () {
        expectRejected(
          'appId: a\nflow: f\nsteps:\n'
          '  - expectElement: {id: a, textContains: 12}\n',
          'textContains',
        );
      });
    });

    group('and what a wrong type must not change', () {
      test('an absent "flow" is still unnamed', () {
        final flow = TestFlow.parse(
          'appId: a\nsteps:\n  - launchApp\n',
          source: 'test',
        );

        expect(flow.name, 'unnamed');
      });

      test('an explicit null still means "not given"', () {
        // The cast accepted these and so must the guard: tightening it
        // would refuse flows that have always been valid.
        final flow = TestFlow.parse(
          'appId: a\nflow:\nsteps:\n'
          '  - expectElement: {id: a, text: , timeoutMs: }\n',
          source: 'test',
        );

        final step = flow.steps.single as ExpectElementStep;
        expect(flow.name, 'unnamed');
        expect(step.text, isNull);
        expect(step.timeout, const Duration(milliseconds: 5000));
      });

      test('well-typed values are unchanged', () {
        final flow = TestFlow.parse(
          'appId: a\nflow: checkout\nsteps:\n'
          '  - expectElement: {id: a, text: Total, timeoutMs: 250}\n',
          source: 'test',
        );

        final step = flow.steps.single as ExpectElementStep;
        expect(flow.name, 'checkout');
        expect(step.text, 'Total');
        expect(step.timeout, const Duration(milliseconds: 250));
      });
    });
  });

  group('individual steps', () {
    TestFlow parseSteps(String steps) => TestFlow.parse(
          'appId: a\nflow: f\nsteps:\n$steps',
          source: 'test',
        );

    test('input carries an id and a value', () {
      final step = parseSteps('  - input:\n      id: search.field\n'
              '      value: Nike\n')
          .steps
          .whereType<InputStep>()
          .single;

      expect(step.elementId, 'search.field');
      expect(step.value, 'Nike');
    });

    test('back takes no arguments', () {
      expect(parseSteps('  - back\n').steps.single, isA<BackStep>());
    });

    test('waitForSettle accepts a timeout', () {
      final step = parseSteps('  - waitForSettle:\n      timeoutMs: 4000\n')
          .steps
          .whereType<WaitForSettleStep>()
          .single;

      expect(step.timeout, const Duration(milliseconds: 4000));
    });

    test('waitForSettle has a default timeout', () {
      final step =
          parseSteps('  - waitForSettle\n').steps.whereType<WaitForSettleStep>().single;

      expect(step.timeout.inSeconds, greaterThan(0));
    });

    test('every step describes itself for the report', () {
      final flow = TestFlow.parse(productFlow, source: 'test');

      for (final step in flow.steps) {
        expect(step.describe(), isNotEmpty);
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Found by running: expectScreen checked the current screen the instant
// the tap returned, before the SCREEN_ENTER event had crossed the VM
// Service, and failed saying the app was still on /home. An assertion
// that races the thing it asserts about is worthless, so the step waits.
// ---------------------------------------------------------------------------
void main2() {
  group('expectScreen waits', () {
    TestFlow parse(String steps) => TestFlow.parse(
          'appId: a\nflow: f\nsteps:\n$steps',
          source: 'test',
        );

    test('has a default timeout rather than checking instantly', () {
      final step = parse('  - expectScreen:\n      id: /home\n')
          .steps
          .whereType<ExpectScreenStep>()
          .single;

      expect(step.timeout.inMilliseconds, greaterThan(0));
    });

    test('accepts an explicit timeout', () {
      final step = parse('  - expectScreen:\n      id: /home\n'
              '      timeoutMs: 1500\n')
          .steps
          .whereType<ExpectScreenStep>()
          .single;

      expect(step.timeout, const Duration(milliseconds: 1500));
    });
  });
}

void main3() {
  group('a proposed flow', () {
    TestFlow parse(String header) => TestFlow.parse(
          '$header\nsteps:\n  - launchApp\n',
          source: 'f.yaml',
        );

    test('is marked, so it can be refused', () {
      // AI-generated scenarios are inert until a person promotes them.
      // The mark is on the flow itself rather than on its folder, so
      // pointing the runner straight at the file still refuses.
      final flow = parse('appId: a\nflow: f\nstatus: proposed');

      expect(flow.isProposed, isTrue);
    });

    test('an ordinary flow is not proposed', () {
      expect(parse('appId: a\nflow: f').isProposed, isFalse);
      expect(parse('appId: a\nflow: f\nstatus: approved').isProposed, isFalse);
    });

    test('an unknown status is rejected rather than assumed', () {
      // Assuming "approved" would run something nobody reviewed;
      // assuming "proposed" would silently drop a real test.
      expect(
        () => parse('appId: a\nflow: f\nstatus: probably-fine'),
        throwsA(
          isA<FlowFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('probably-fine'), contains('proposed')),
          ),
        ),
      );
    });
  });
}

/// Added in Phase 12. A flow that needs a particular API state says so.
void fixtureTests() {
  group('fixture', () {
    test('a flow names the API state it needs', () {
      final flow = TestFlow.parse('''
appId: com.example.app
flow: out_of_stock
fixture: product_out_of_stock
steps:
  - launchApp
''', source: 'x.yaml');

      expect(flow.fixture, 'product_out_of_stock');
    });

    test('a flow that does not care names none', () {
      final flow = TestFlow.parse('''
appId: com.example.app
flow: any
steps:
  - launchApp
''', source: 'x.yaml');

      expect(flow.fixture, isNull);
    });

    test('a non-string fixture is a parse error, not a silent default', () {
      expect(
        () => TestFlow.parse('''
appId: com.example.app
flow: x
fixture: [a, b]
steps:
  - launchApp
''', source: 'x.yaml'),
        throwsA(isA<FlowFormatException>()),
      );
    });
  });
}

/// Added in Phase 12. Until then a flow could navigate and validate and
/// nothing else, which is useless for an error state.
void expectElementTests() {
  group('expectElement', () {
    TestFlow parse(String steps) => TestFlow.parse(
          'appId: a\nflow: f\nsteps:\n$steps',
          source: 'x.yaml',
        );

    test('reads every assertion it supports', () {
      final step = parse('''  - expectElement:
      id: cart.checkout
      present: false
''').steps.single as ExpectElementStep;

      expect(step.elementId, 'cart.checkout');
      expect(step.present, isFalse);
      expect(step.expectations, {'present': false});
    });

    test('an absent assertion is not an assertion of false', () {
      final step = parse('''  - expectElement:
      id: x
      enabled: true
''').steps.single as ExpectElementStep;

      expect(step.enabled, isTrue);
      expect(step.visible, isNull);
      expect(step.present, isNull);
      expect(step.expectations.keys, ['enabled']);
    });

    test('a non-boolean where a boolean belongs is a parse error', () {
      // Not coerced. "yes" quietly becoming false would make a flow
      // assert the opposite of what it says.
      expect(
        () => parse('''  - expectElement:
      id: x
      enabled: maybe
'''),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('an unknown argument is rejected', () {
      expect(
        () => parse('''  - expectElement:
      id: x
      colour: red
'''),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('it needs an id', () {
      expect(
        () => parse('  - expectElement:\n      present: true\n'),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('describes itself for the report', () {
      final step = parse('''  - expectElement:
      id: product.add_to_cart
      enabled: false
''').steps.single;

      expect(step.describe(), 'expect "product.add_to_cart" enabled = false');
    });
  });
}
