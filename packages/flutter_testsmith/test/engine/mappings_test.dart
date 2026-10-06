import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

const String fullMappings = '''
screen: /product/details
api: GET /products/123

mappings:
  - target: product.name
    source: response.name

  - target: product.price
    source: response.price
    transformation: currency(INR)

  - target: product.add_to_cart
    property: enabled
    source: response.available

rules:
  - condition: "available == false"
    expectations:
      - element: product.unavailable
        property: visible
        equals: true
      - element: product.add_to_cart
        property: enabled
        equals: false

  - condition: "discount > 0"
    expectations:
      - element: product.discount_badge
        property: visible
        equals: true

suggested:
  - target: product.rating
    source: response.rating
    transformation: toText
    confidence: 0.91
''';

void main() {
  group('loading mappings', () {
    final file = MappingsFile.parse(fullMappings, source: 'test');

    test('reads the screen and endpoint', () {
      expect(file.screen, '/product/details');
      expect(file.api, 'GET /products/123');
    });

    test('reads each mapping', () {
      expect(file.mappings, hasLength(3));
      expect(file.mappings.first.target, 'product.name');
      expect(file.mappings.first.source, 'response.name');
    });

    test('defaults the compared property to the element text', () {
      expect(file.mappings.first.property, 'text');
    });

    test('reads an explicit property', () {
      final mapping = file.mappingFor('product.add_to_cart')!;
      expect(mapping.property, 'enabled');
    });

    test('reads a transformation, defaulting to identity', () {
      expect(file.mappingFor('product.price')!.transformation,
          'currency(INR)');
      expect(file.mappingFor('product.name')!.transformation, 'identity');
    });

    test('strips the response prefix from the source path', () {
      // The file says `response.price` for readability; the path applied
      // to the body is `price`.
      expect(file.mappingFor('product.price')!.responsePath, 'price');
    });
  });

  group('the suggested block is inert', () {
    final file = MappingsFile.parse(fullMappings, source: 'test');

    test('is parsed and kept', () {
      expect(file.suggested, hasLength(1));
      expect(file.suggested.first.target, 'product.rating');
      expect(file.suggested.first.confidence, 0.91);
    });

    test('does not appear among the active mappings', () {
      // AI proposals must never take effect without a human promoting
      // them. See ARCHITECTURE 10.6.
      expect(file.mappingFor('product.rating'), isNull);
      expect(
        file.mappings.map((Mapping m) => m.target),
        isNot(contains('product.rating')),
      );
    });
  });

  group('rules', () {
    final file = MappingsFile.parse(fullMappings, source: 'test');

    test('reads conditions and their expectations', () {
      expect(file.rules, hasLength(2));
      expect(file.rules.first.condition, 'available == false');
      expect(file.rules.first.expectations, hasLength(2));
    });

    test('reads an expectation', () {
      final expectation = file.rules.first.expectations.first;

      expect(expectation.element, 'product.unavailable');
      expect(expectation.property, 'visible');
      expect(expectation.equals, true);
    });
  });

  group('rejecting a bad file', () {
    test('an unknown top-level key is an error, not ignored', () {
      // A typo'd key that silently does nothing is worse than no file:
      // the test reports green while checking nothing.
      expect(
        () => MappingsFile.parse(
          'screen: x\nmapings:\n  - target: a\n    source: b\n',
          source: 'test',
        ),
        throwsA(
          isA<MappingsFormatException>()
              .having((e) => e.toString(), 'message', contains('mapings'))
              .having((e) => e.toString(), 'message', contains('mappings')),
        ),
      );
    });

    test('an unknown mapping key is an error', () {
      expect(
        () => MappingsFile.parse(
          'screen: x\nmappings:\n  - target: a\n    sauce: b\n',
          source: 'test',
        ),
        throwsA(isA<MappingsFormatException>()),
      );
    });

    test('a mapping without a target is an error', () {
      expect(
        () => MappingsFile.parse(
          'screen: x\nmappings:\n  - source: b\n',
          source: 'test',
        ),
        throwsA(
          isA<MappingsFormatException>()
              .having((e) => e.toString(), 'message', contains('target')),
        ),
      );
    });

    test('an unknown transformation is caught at load, not at run', () {
      // Better to refuse the file than to fail halfway through a run.
      expect(
        () => MappingsFile.parse(
          'screen: x\nmappings:\n'
          '  - target: a\n    source: b\n    transformation: currancy(INR)\n',
          source: 'test',
        ),
        throwsA(isA<MappingsFormatException>()),
      );
    });

    test('the error names the file it came from', () {
      expect(
        () => MappingsFile.parse('mapings: 1', source: 'product.yaml'),
        throwsA(
          isA<MappingsFormatException>()
              .having((e) => e.toString(), 'message', contains('product.yaml')),
        ),
      );
    });

    test('an empty file is valid and simply validates nothing', () {
      final file = MappingsFile.parse('screen: x', source: 'test');

      expect(file.mappings, isEmpty);
      expect(file.rules, isEmpty);
    });

    // A value of the wrong *type*, as distinct from a key of the wrong
    // name above. `screen` has always been checked and `api` was a cast,
    // so one ordinary slip in this file exited 1 and named the file
    // while the other left the parser as a `TypeError` - which is not a
    // MappingsFormatException, so it went straight through the guard
    // every call site has had since be9fca3, and the command exited 255
    // with a stack trace. Measured on `generate`, `run`, `preflight`,
    // `suite run` and `impact`, all five, against e7eeda7.
    group('a value of the wrong type', () {
      void expectRejected(String yaml, String names) {
        expect(
          () => MappingsFile.parse(yaml, source: 'test'),
          throwsA(
            isA<MappingsFormatException>()
                .having((e) => e.toString(), 'message', contains(names))
                // The file, which is what sends somebody to the right
                // place - the same provenance the key errors carry.
                .having((e) => e.toString(), 'source', contains('test')),
          ),
          reason: yaml,
        );
      }

      test('"api" given a number', () {
        expectRejected('screen: x\napi: 123\n', 'api');
      });

      test('"property" given a number', () {
        expectRejected(
          'screen: x\nmappings:\n  - {target: a, source: b, property: 5}\n',
          'property',
        );
      });

      test('"transformation" given a number', () {
        expectRejected(
          'screen: x\nmappings:\n'
          '  - {target: a, source: b, transformation: 7}\n',
          'transformation',
        );
      });

      test('"confidence" given text', () {
        // Read only where a suggested block allows it, so it is asserted
        // through the same door the parser opens for it.
        expectRejected(
          'screen: x\nsuggested:\n'
          '  - {target: a, source: b, confidence: high}\n',
          'confidence',
        );
      });
    });

    group('and what a wrong type must not change', () {
      test('an absent optional is still absent', () {
        final file = MappingsFile.parse(
          'screen: x\nmappings:\n  - {target: a, source: b}\n',
          source: 'test',
        );

        expect(file.api, isNull);
        expect(file.mappings.single.property, 'text');
        expect(file.mappings.single.transformation, 'identity');
      });

      test('an explicit null still means "not given"', () {
        // YAML `api:` with nothing after it. The cast accepted this and
        // so must the guard - tightening it would refuse files that
        // have always been valid.
        final file = MappingsFile.parse(
          'screen: x\napi:\nmappings:\n  - {target: a, source: b}\n',
          source: 'test',
        );

        expect(file.api, isNull);
      });

      test('a well-typed value is unchanged', () {
        final file = MappingsFile.parse(
          'screen: x\napi: GET /a\nmappings:\n'
          '  - {target: a, source: b, property: value}\n',
          source: 'test',
        );

        expect(file.api, 'GET /a');
        expect(file.mappings.single.property, 'value');
      });

      test('a wrong-typed "screen" keeps the message it always had', () {
        expect(
          () => MappingsFile.parse('screen: 123\n', source: 'test'),
          throwsA(
            isA<MappingsFormatException>().having(
              (e) => e.toString(),
              'message',
              contains('a "screen" is required'),
            ),
          ),
        );
      });
    });
  });

  group('conditions', () {
    Object? body(String key) => const {
          'price': 2999,
          'discount': 0,
          'available': false,
          'name': 'Nike Air Max',
          'rating': 4.5,
        }[key];

    test('compares equality', () {
      expect(Condition.parse('available == false').evaluate(body), isTrue);
      expect(Condition.parse('available == true').evaluate(body), isFalse);
    });

    test('compares inequality', () {
      expect(Condition.parse('discount != 0').evaluate(body), isFalse);
      expect(Condition.parse('price != 0').evaluate(body), isTrue);
    });

    test('compares numbers', () {
      expect(Condition.parse('discount > 0').evaluate(body), isFalse);
      expect(Condition.parse('price > 1000').evaluate(body), isTrue);
      expect(Condition.parse('price >= 2999').evaluate(body), isTrue);
      expect(Condition.parse('rating < 5').evaluate(body), isTrue);
    });

    test('compares strings', () {
      expect(
        Condition.parse('name == "Nike Air Max"').evaluate(body),
        isTrue,
      );
    });

    test('a missing field makes the condition false, not an error', () {
      // A rule about a field this response does not carry simply does
      // not apply.
      expect(Condition.parse('missing == 1').evaluate(body), isFalse);
    });

    test('rejects an unparseable condition at load', () {
      expect(
        () => Condition.parse('available =!= false'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
