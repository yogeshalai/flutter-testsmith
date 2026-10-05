// Reading a spec back off disk, when the document is not one.
//
// `<app>/figma/*.json` is a project file. `testsmith figma pull` writes
// it, but it is also hand-authored - the example application's Checkout
// spec is, and PHASE_12_ACCEPTANCE L10 records that - edited by people,
// and left behind by older versions of this tool.
//
// The CLI's `loadFigmaSpecs` already says what happens to one that will
// not read: report it through `onProblem` and skip it, because a spec
// that describes no screen conflicts with nothing. It catches
// `FormatException` to do that, which is what `jsonDecode` raises.
//
// The schema was read with `!` and `as`, which raise `TypeError` - not a
// `FormatException`, and not an `Exception` at all. So a file that was
// valid JSON but not a spec walked straight past the guard. Measured
// before this file existed, with `{"a": 1}` in `<app>/figma`:
//
//   testsmith run        Unhandled exception: Null check operator ...  255
//   testsmith suite run  Unhandled exception: Null check operator ...  255
//   testsmith preflight  Unhandled exception: Null check operator ...  255
//
// Every case below is a document a person could plausibly leave in that
// directory. None of them may be an `Error`.
import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';
import 'package:test/test.dart';

/// The smallest document `testsmith figma pull` would write.
Map<String, Object?> spec({Map<String, Object?> changes = const {}}) => {
      'screen': '/home',
      'nodeId': '1:1',
      'figmaName': 'Home',
      'width': 400.0,
      'height': 800.0,
      'totalNodesWalked': 2,
      'elements': <Object?>[element()],
      ...changes,
    };

Map<String, Object?> element({Map<String, Object?> changes = const {}}) => {
      'nodeId': '1:2',
      'figmaName': 'Title',
      'type': 'TEXT',
      'rect': {'x': 0.0, 'y': 0.0, 'width': 100.0, 'height': 20.0},
      'horizontal': {'anchor': 'start', 'sizing': 'fixed'},
      'vertical': {'anchor': 'start', 'sizing': 'fixed'},
      ...changes,
    };

/// A [FormatException] whose message names [what].
Matcher refuses(String what) => throwsA(
      isA<FormatException>().having((e) => e.message, 'message', contains(what)),
    );

void main() {
  group('a document that is not a spec is refused as a format problem', () {
    test('an object with none of the fields', () {
      // The original reproduction.
      expect(() => FigmaScreenSpec.fromJson({'a': 1}), refuses('screen'));
    });

    test('a required string that is missing', () {
      final json = spec()..remove('nodeId');

      expect(() => FigmaScreenSpec.fromJson(json), refuses('nodeId'));
    });

    test('a required string that is present as null', () {
      // `toJson` never writes a null, so a null here is a hand edit -
      // and it is the same news as the key being absent.
      expect(
        () => FigmaScreenSpec.fromJson(spec(changes: {'figmaName': null})),
        refuses('figmaName'),
      );
    });

    test('a required number written as a string', () {
      // The second reproduction: `"width": "400"`.
      expect(
        () => FigmaScreenSpec.fromJson(spec(changes: {'width': '400'})),
        refuses('width'),
      );
    });

    test('an optional number written as a string', () {
      expect(
        () => FigmaScreenSpec.fromJson(spec(changes: {'totalNodesWalked': 'x'})),
        refuses('totalNodesWalked'),
      );
    });

    test('an optional flag written as a string', () {
      expect(
        () => FigmaScreenSpec.fromJson(spec(changes: {'clipsContent': 'yes'})),
        refuses('clipsContent'),
      );
    });

    test('elements missing entirely', () {
      final json = spec()..remove('elements');

      expect(() => FigmaScreenSpec.fromJson(json), refuses('elements'));
    });

    test('elements that is not a list', () {
      expect(
        () => FigmaScreenSpec.fromJson(spec(changes: {'elements': 'none'})),
        refuses('elements'),
      );
    });

    test('unmatchedMappings that is not a list', () {
      expect(
        () => FigmaScreenSpec.fromJson(
          spec(changes: {'unmatchedMappings': '1:9'}),
        ),
        refuses('unmatchedMappings'),
      );
    });

    test('unmatchedMappings holding something that is not an id', () {
      expect(
        () => FigmaScreenSpec.fromJson(
          spec(changes: {
            'unmatchedMappings': <Object?>['1:9', 42],
          }),
        ),
        refuses('unmatchedMappings[1]'),
      );
    });
  });

  group('a malformed element says which one', () {
    test('an entry that is not an object', () {
      expect(
        () => FigmaScreenSpec.fromJson(
          spec(changes: {
            'elements': <Object?>[element(), 'Title'],
          }),
        ),
        refuses('elements[1]'),
      );
    });

    test('an entry missing a required field', () {
      final broken = element()..remove('nodeId');

      expect(
        () => FigmaScreenSpec.fromJson(
          spec(changes: {
            'elements': <Object?>[element(), broken],
          }),
        ),
        refuses('elements[1]'),
      );
    });

    test('and which field it was', () {
      final broken = element()..remove('figmaName');

      expect(
        () => FigmaScreenSpec.fromJson(
          spec(changes: {
            'elements': <Object?>[broken],
          }),
        ),
        refuses('figmaName'),
      );
    });

    test('a type that is not a string', () {
      expect(
        () => FigmaElement.fromJson(element(changes: {'type': 7})),
        refuses('type'),
      );
    });

    test('an optional string written as a number', () {
      expect(
        () => FigmaElement.fromJson(element(changes: {'semanticId': 7})),
        refuses('semanticId'),
      );
    });
  });

  group('the geometry a design element carries', () {
    test('a rect that is not an object', () {
      expect(
        () => FigmaElement.fromJson(element(changes: {'rect': 'square'})),
        refuses('rect'),
      );
    });

    test('a rect that is missing a coordinate', () {
      // The rectangle's own shape belongs to the protocol package, which
      // raises `ProtocolFormatException` - not a `FormatException`, so
      // it escaped the same guard the cast errors did.
      expect(
        () => FigmaElement.fromJson(
          element(changes: {
            'rect': {'x': 0.0, 'y': 0.0, 'width': 100.0},
          }),
        ),
        refuses('rect'),
      );
    });

    test('and says which coordinate', () {
      expect(
        () => FigmaElement.fromJson(
          element(changes: {
            'rect': {'x': 0.0, 'y': 0.0, 'width': 100.0},
          }),
        ),
        refuses('height'),
      );
    });

    test('an unclippedRect that will not read', () {
      expect(
        () => FigmaElement.fromJson(
          element(changes: {'unclippedRect': <String, Object?>{}}),
        ),
        refuses('unclippedRect'),
      );
    });

    test('an axis layout that is not an object', () {
      expect(
        () => FigmaElement.fromJson(element(changes: {'horizontal': 'start'})),
        refuses('horizontal'),
      );
    });
  });

  group('the blocks an element may carry', () {
    test('typography with a font size that is not a number', () {
      expect(
        () => FigmaElement.fromJson(
          element(changes: {
            'typography': {'fontFamily': 'Inter', 'fontSize': 'big', 'fontWeight': 400},
          }),
        ),
        refuses('fontSize'),
      );
    });

    test('typography missing a required field', () {
      expect(
        () => FigmaElement.fromJson(
          element(changes: {
            'typography': {'fontSize': 14.0, 'fontWeight': 400},
          }),
        ),
        refuses('fontFamily'),
      );
    });

    test('layout with spacing that is not a number', () {
      expect(
        () => FigmaElement.fromJson(
          element(changes: {
            'layout': {'direction': 'VERTICAL', 'itemSpacing': '8'},
          }),
        ),
        refuses('itemSpacing'),
      );
    });

    test('layout padding that is not an object', () {
      expect(
        () => FigmaElement.fromJson(
          element(changes: {
            'layout': {'direction': 'VERTICAL', 'padding': 8},
          }),
        ),
        refuses('padding'),
      );
    });

    test('padding written as strings', () {
      expect(
        () => FigmaElement.fromJson(
          element(changes: {
            'layout': {
              'direction': 'VERTICAL',
              'padding': {'left': '8'},
            },
          }),
        ),
        refuses('left'),
      );
    });

    test('coverage counts that are not numbers', () {
      expect(
        () => FigmaCoverage.fromJson({'totalNodes': 'many'}),
        refuses('totalNodes'),
      );
    });
  });

  group('a spec that is one still reads', () {
    test('the minimum a person can hand-author', () {
      final read = FigmaScreenSpec.fromJson({
        'screen': '/home',
        'nodeId': '1:1',
        'figmaName': 'Home',
        'width': 400,
        'height': 800,
        'elements': <Object?>[],
      });

      // Integers, because a hand-written file says 400 rather than
      // 400.0, and `jsonDecode` hands those back as `int`.
      expect(read.screen, '/home');
      expect(read.width, 400.0);
      expect(read.elements, isEmpty);
      expect(read.totalNodesWalked, 0);
      expect(read.clipsContent, isFalse);
      expect(read.unmatchedMappings, isEmpty);
    });

    test('and so does every field a pull writes', () {
      // The round trip that keeps the readers honest: a stricter parser
      // that rejected something `toJson` emits would be a worse defect
      // than the one this file is about.
      final original = FigmaScreenSpec(
        screen: '/home',
        nodeId: '1:1',
        figmaName: 'Home',
        width: 400,
        height: 800,
        totalNodesWalked: 9,
        clipsContent: true,
        unmatchedMappings: const ['1:99'],
        elements: [
          FigmaElement(
            nodeId: '1:2',
            figmaName: 'Title',
            parentNodeId: '1:1',
            semanticId: 'home.title',
            type: FigmaElementType.text,
            rect: const LogicalRect(x: 1, y: 2, width: 3, height: 4),
            text: 'Hello',
            typography: const FigmaTypography(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: 600,
              lineHeight: 20,
              letterSpacing: 0.5,
              textAlign: 'LEFT',
            ),
            fill: '#112233ff',
            cornerRadius: 8,
            opacity: 0.5,
            visible: false,
            layout: const FigmaLayout(
              direction: FigmaLayoutDirection.horizontal,
              itemSpacing: 12,
              padding: FigmaEdgeInsets(left: 1, top: 2, right: 3, bottom: 4),
            ),
            horizontal: const FigmaAxisLayout(
              anchor: FigmaAnchor.end,
              sizing: FigmaSizing.fill,
            ),
            vertical: const FigmaAxisLayout(
              anchor: FigmaAnchor.centre,
              sizing: FigmaSizing.hug,
            ),
            unclippedRect: const LogicalRect(x: 1, y: 2, width: 30, height: 40),
          ),
        ],
      );

      final restored = FigmaScreenSpec.fromJson(original.toJson());
      final element = restored.elements.single;

      expect(restored.clipsContent, isTrue);
      expect(restored.totalNodesWalked, 9);
      expect(restored.unmatchedMappings, ['1:99']);
      expect(element.semanticId, 'home.title');
      expect(element.type, FigmaElementType.text);
      expect(element.rect.height, 4);
      expect(element.text, 'Hello');
      expect(element.typography?.fontFamily, 'Inter');
      expect(element.typography?.letterSpacing, 0.5);
      expect(element.fill, '#112233ff');
      expect(element.cornerRadius, 8);
      expect(element.opacity, 0.5);
      expect(element.visible, isFalse);
      expect(element.layout?.direction, FigmaLayoutDirection.horizontal);
      expect(element.layout?.padding.left, 1);
      expect(element.horizontal.anchor, FigmaAnchor.end);
      expect(element.vertical.sizing, FigmaSizing.hug);
      expect(element.unclippedRect?.width, 30);
      expect(restored.toJson(), original.toJson());
    });

    test('and an unknown element type is still the fallback, not a refusal', () {
      // `fromWire` has always answered SHAPE for a type it does not know,
      // so a spec from a newer pull keeps reading. Unchanged here.
      final read = FigmaElement.fromJson(element(changes: {'type': 'FRAME'}));

      expect(read.type, FigmaElementType.shape);
    });
  });

  test('the protocol still raises its own exception for its own documents', () {
    // The translation is one-way and local to reading a design file: the
    // protocol keeps the type it documents for everything else.
    expect(
      () => LogicalRect.fromJson(const {'x': 0}),
      throwsA(isA<ProtocolFormatException>()),
    );
  });
}
