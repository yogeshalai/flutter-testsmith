import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:test/test.dart';

/// The real `Product Details` frame, fetched from Figma.
///
/// A real file rather than an invented one, deliberately. An invented
/// fixture would have had layers named `product.price`; this one has
/// `Frame 42980` and `Rectangle 91`, which is what actually turns up and
/// is the whole reason the mapping layer exists.
///
/// Geometry, typography, colour and structure are as Figma returned
/// them. Client-identifying names and text, node ids, component keys,
/// image refs and file metadata were replaced with synthetic values, and
/// `thumbnailUrl` - a presigned S3 link carrying AWS credential
/// material - with an `example.invalid` URL; nothing reads it.
Map<String, Object?> loadFixture() => jsonDecode(
      File('test/fixtures/product_details_node.json').readAsStringSync(),
    ) as Map<String, Object?>;

FigmaScreenSpec normalise({FigmaNodeMapping? mapping}) =>
    const FigmaNormaliser().normalise(
      loadFixture(),
      nodeId: '913:1',
      screen: '/product/details',
      mapping: mapping,
    );

void main() {
  group('the frame itself', () {
    final spec = normalise();

    test('reads the frame name and size', () {
      expect(spec.figmaName, 'Product Details');
      expect(spec.width, 402);
      expect(spec.height, 1198);
    });

    test('records which node it came from', () {
      expect(spec.nodeId, '913:1');
      expect(spec.screen, '/product/details');
    });
  });

  group('coordinates', () {
    final spec = normalise();

    test('are frame-relative, not canvas-absolute', () {
      // The real frame sits at x=-118574 on the canvas. Reporting that
      // would make every geometry comparison meaningless.
      for (final element in spec.elements) {
        expect(element.rect.x, greaterThan(-1000));
        expect(element.rect.y, greaterThan(-1000));
      }
    });

    test('put the frame origin at zero', () {
      final image = spec.byFigmaName('image 9')!;

      expect(image.rect.x, 20);
      expect(image.rect.y, 137);
      expect(image.rect.width, 362);
      expect(image.rect.height, 362);
    });
  });

  group('text', () {
    final spec = normalise();

    test('captures the rendered characters', () {
      final texts = spec.elements.where((e) => e.type == FigmaElementType.text);

      expect(
        texts.map((e) => e.text),
        containsAll(<String>['Nonveg-Burger', '₹90/Unit', 'Highlights']),
      );
    });

    test('captures typography', () {
      final price = spec.elements.firstWhere((e) => e.text == '₹90/Unit');

      expect(price.typography, isNotNull);
      expect(price.typography!.fontFamily, 'Inter');
      expect(price.typography!.fontSize, 12);
      expect(price.typography!.fontWeight, 500);
      expect(price.typography!.lineHeight, 15);
    });

    test('captures the text colour as hex', () {
      // Figma gives 0..1 floats; a hex string is what a person reading a
      // report can actually check against a value in the code.
      final price = spec.elements.firstWhere((e) => e.text == '₹90/Unit');

      expect(price.fill, matches(RegExp(r'^#[0-9a-f]{8}$')));
      expect(price.fill, '#353535ff');
    });
  });

  group('shapes', () {
    final spec = normalise();

    test('captures a corner radius', () {
      final chip = spec.elements.firstWhere(
        (e) => e.figmaName == 'Rectangle 9',
      );

      expect(chip.cornerRadius, 4);
    });

    test('folds fill opacity into the alpha channel', () {
      // The chip's fill is the same grey as the text at 5% opacity.
      // Reporting the colour without the opacity would be wrong.
      final chip = spec.elements.firstWhere(
        (e) => e.figmaName == 'Rectangle 9',
      );

      expect(chip.fill, startsWith('#353535'));
      expect(chip.fill, isNot(endsWith('ff')));
    });
  });

  group('filtering', () {
    final spec = normalise();

    test('keeps far fewer elements than the raw tree has nodes', () {
      // The raw frame is mostly vector paths inside icon groups.
      expect(spec.elements.length, lessThan(spec.totalNodesWalked));
      expect(spec.totalNodesWalked, greaterThan(40));
    });

    test('drops the vector paths that make up icons', () {
      expect(
        spec.elements.map((e) => e.type),
        isNot(contains(FigmaElementType.vector)),
      );
    });

    test('keeps every text node', () {
      final texts =
          spec.elements.where((e) => e.type == FigmaElementType.text).length;

      expect(texts, 16);
    });

    test('keeps a zero-size element out of the spec', () {
      for (final element in spec.elements) {
        expect(element.rect.width, greaterThan(0));
        expect(element.rect.height, greaterThan(0));
      }
    });
  });

  group('semantic ids come from a mapping, not from layer names', () {
    test('a node with no mapping has no semantic id', () {
      // Real layer names are "Frame 42980" and "Rectangle 91". Treating
      // them as semantic ids would be worse than having none.
      final spec = normalise();

      expect(spec.elements.every((e) => e.semanticId == null), isTrue);
    });

    test('a mapping assigns semantic ids by node id', () {
      final price = normalise().elements.firstWhere(
            (e) => e.text == '₹90/Unit',
          );

      final mapped = normalise(
        mapping: FigmaNodeMapping({price.nodeId: 'product.price'}),
      );

      expect(mapped.bySemanticId('product.price'), isNotNull);
      expect(mapped.bySemanticId('product.price')!.text, '₹90/Unit');
    });

    test('reports mappings that match no node in the frame', () {
      // A stale mapping pointing at a deleted layer must be visible,
      // not silently ignored.
      final spec = normalise(
        mapping: FigmaNodeMapping({'9999:9999': 'product.ghost'}),
      );

      expect(spec.unmatchedMappings, contains('9999:9999'));
    });

    test('a mapping file is parsed from YAML', () {
      final mapping = FigmaNodeMapping.parse('''
screen: /product/details
nodes:
  "1410:2500": product.name
  "1410:2501": product.price
''', source: 'test');

      expect(mapping.semanticIdFor('1410:2501'), 'product.price');
      expect(mapping.screen, '/product/details');
    });

    test('a mapping file rejects a duplicate semantic id', () {
      // Two Figma nodes claiming the same element makes any comparison
      // about it ambiguous.
      expect(
        () => FigmaNodeMapping.parse('''
screen: s
nodes:
  "1:1": product.price
  "2:2": product.price
''', source: 'test'),
        throwsA(isA<FormatException>()),
      );
    });

    // A value of the wrong *type*, as distinct from the unknown keys and
    // duplicate ids above. Every other field in this file is checked and
    // raises a `FormatException` naming the source; `screen` was a cast,
    // so an ordinary slip left the parser as a `_TypeError` - which is
    // not a `FormatException`, and not an `Exception` at all, so it
    // walked past both callers' guards and past `bin/testsmith.dart`.
    // Measured against 957fcfa on each form below: exit 255, an
    // unhandled exception, four frames and a leaked source path.
    group('a "screen" that is not a name', () {
      for (final value in const ['123', '[a, b]', '{a: 1}', 'true', '1.5']) {
        test('$value is refused, naming the file and the field', () {
          expect(
            () => FigmaNodeMapping.parse(
              'screen: $value\nnodes:\n  "1:2": product.name\n',
              source: 'figma/product_details.mapping.yaml',
            ),
            throwsA(
              isA<FormatException>()
                  .having((e) => e.message, 'message', contains('screen'))
                  .having((e) => e.message, 'source',
                      contains('figma/product_details.mapping.yaml')),
            ),
            reason: 'screen: $value',
          );
        });
      }
    });

    group('and what refusing it must not change', () {
      test('a valid screen is still read', () {
        final mapping = FigmaNodeMapping.parse('''
screen: /product/details
nodes:
  "1410:2500": product.name
''', source: 'test');

        expect(mapping.screen, '/product/details');
        expect(mapping.semanticIdFor('1410:2500'), 'product.name');
      });

      test('an absent screen is still no screen', () {
        // Valid today, and the template does not force one.
        final mapping = FigmaNodeMapping.parse(
          'nodes:\n  "1:2": product.name\n',
          source: 'test',
        );

        expect(mapping.screen, isNull);
        expect(mapping.semanticIdFor('1:2'), 'product.name');
      });

      test('an explicit null screen is still no screen', () {
        // YAML `screen:` with nothing after it. The cast accepted this,
        // and so must the guard - tightening it would refuse files that
        // have always been valid.
        final mapping = FigmaNodeMapping.parse(
          'screen:\nnodes:\n  "1:2": product.name\n',
          source: 'test',
        );

        expect(mapping.screen, isNull);
      });
    });
  });

  group('a response that is not a usable design', () {
    // These four refusals are right; what they raised was not. A
    // `FormatException` here escaped `resolveFigmaSources` and
    // `figma pull`, which both catch `FigmaException` - the type this
    // package uses for everything that goes wrong talking to Figma - and
    // the process ended at 255 instead of the screen being reported.
    //
    // Reproduced end to end before this group existed, with a cached
    // response holding `{"a": 1}`: `run`, `suite run` and `figma pull`
    // each exited 255, the suite immediately after printing "nothing
    // blocking".
    FigmaScreenSpec read(Map<String, Object?> response) =>
        const FigmaNormaliser().normalise(
          response,
          nodeId: '1:1',
          screen: '/home',
        );

    test('with no nodes at all', () {
      expect(() => read({'error': 'blocked'}), throwsA(isA<FigmaException>()));
    });

    test('with nodes that do not include the one asked for', () {
      expect(
        () => read({'nodes': <String, Object?>{}}),
        throwsA(isA<FigmaException>()),
      );
    });

    test('with a node that carries no document', () {
      expect(
        () => read({
          'nodes': {'1:1': <String, Object?>{}},
        }),
        throwsA(isA<FigmaException>()),
      );
    });

    test('with a document that is not an object', () {
      // Not one of the four refusals: an unchecked cast between two of
      // them, which raised a TypeError rather than reaching either.
      expect(
        () => read({
          'nodes': {
            '1:1': {'document': 'a frame, apparently'},
          },
        }),
        throwsA(isA<FigmaException>()),
      );
    });

    test('with a frame that has no bounding box', () {
      expect(
        () => read({
          'nodes': {
            '1:1': {
              'document': {'id': '1:1', 'name': 'Home', 'type': 'FRAME'},
            },
          },
        }),
        throwsA(isA<FigmaException>()),
      );
    });

    test('and the message says which part was missing', () {
      expect(
        () => read({'error': 'blocked'}),
        throwsA(
          isA<FigmaException>()
              .having((e) => e.message, 'message', contains('nodes')),
        ),
      );
    });
  });

  group('the spec serialises', () {
    test('round-trips through JSON', () {
      final spec = normalise();

      final restored = FigmaScreenSpec.fromJson(spec.toJson());

      expect(restored.figmaName, spec.figmaName);
      expect(restored.elements.length, spec.elements.length);
      expect(restored.elements.first.rect.x, spec.elements.first.rect.x);
    });

    test('is stable, so a committed spec diffs cleanly', () {
      // Order must not depend on map iteration or timing, or every
      // refresh would show spurious changes.
      expect(
        jsonEncode(normalise().toJson()),
        jsonEncode(normalise().toJson()),
      );
    });
  });
}
