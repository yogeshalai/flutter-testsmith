import 'package:test/test.dart';
import 'package:flutter_testsmith/protocol.dart';

UiNode node({
  String? testId,
  String type = 'Text',
  String? text,
  bool? enabled,
  bool visible = true,
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: testId,
      type: type,
      text: text,
      enabled: enabled,
      visible: visible,
      bounds: const LogicalRect(x: 32, y: 420, width: 300, height: 28),
      children: children,
    );

void main() {
  group('LogicalRect', () {
    test('round-trips through JSON', () {
      const rect = LogicalRect(x: 32, y: 420, width: 300, height: 28);

      expect(LogicalRect.fromJson(rect.toJson()), rect);
    });

    test('exposes its centre', () {
      const rect = LogicalRect(x: 10, y: 20, width: 100, height: 40);

      expect(rect.centreX, 60);
      expect(rect.centreY, 40);
    });

    test('a zero-area rect is not tappable', () {
      // A widget laid out to zero size is present in the tree but cannot
      // receive a tap; treating it as tappable produces a mysterious
      // no-op.
      expect(const LogicalRect(x: 0, y: 0, width: 0, height: 0).isEmpty, isTrue);
      expect(const LogicalRect(x: 0, y: 0, width: 1, height: 0).isEmpty, isTrue);
      expect(
        const LogicalRect(x: 0, y: 0, width: 1, height: 1).isEmpty,
        isFalse,
      );
    });
  });

  group('UiNode', () {
    test('round-trips through JSON with its children', () {
      final tree = node(
        testId: 'product.card',
        type: 'Card',
        children: [
          node(testId: 'product.name', text: 'Nike Air Max'),
          node(testId: 'product.price', text: 'Rs 2,999'),
        ],
      );

      final restored = UiNode.fromJson(tree.toJson());

      expect(restored.testId, 'product.card');
      expect(restored.children, hasLength(2));
      expect(restored.children.first.text, 'Nike Air Max');
      expect(restored.children.last.testId, 'product.price');
    });

    test('preserves an explicit enabled flag', () {
      // Required by the motivating example: add-to-cart disabled when the
      // product is unavailable.
      final restored = UiNode.fromJson(node(enabled: false).toJson());

      expect(restored.enabled, isFalse);
    });

    test('distinguishes unknown enabled from disabled', () {
      // A Text has no notion of enabled; reporting false would be a lie
      // that a rule could act on.
      final restored = UiNode.fromJson(node().toJson());

      expect(restored.enabled, isNull);
    });

    test('carries semantics alongside the widget type', () {
      const withSemantics = UiNode(
        type: 'ElevatedButton',
        bounds: LogicalRect(x: 0, y: 0, width: 10, height: 10),
        label: 'Add to cart',
        enabled: true,
      );

      final restored = UiNode.fromJson(withSemantics.toJson());

      expect(restored.type, 'ElevatedButton');
      expect(restored.label, 'Add to cart');
    });

    test('finds a descendant by test id', () {
      final tree = node(
        testId: 'root',
        children: [
          node(type: 'Column', children: [node(testId: 'product.price')]),
        ],
      );

      expect(tree.findByTestId('product.price'), isNotNull);
      expect(tree.findByTestId('product.price')!.testId, 'product.price');
      expect(tree.findByTestId('nope'), isNull);
    });

    test('collects every test id in the tree', () {
      final tree = node(
        testId: 'a',
        children: [
          node(testId: 'b'),
          node(children: [node(testId: 'c')]),
        ],
      );

      expect(tree.testIds, {'a', 'b', 'c'});
    });

    test('counts every node including itself', () {
      final tree = node(children: [node(), node(children: [node()])]);

      expect(tree.nodeCount, 4);
    });
  });

  group('UiSnapshot', () {
    test('round-trips through JSON', () {
      final snapshot = UiSnapshot(
        screenId: 'ProductDetails',
        capturedAt: DateTime.utc(2026, 9, 10, 12, 30, 45, 123, 456),
        devicePixelRatio: 1.875,
        root: node(testId: 'product.card'),
      );

      final restored = UiSnapshot.fromJson(snapshot.toJson());

      expect(restored.screenId, 'ProductDetails');
      expect(restored.capturedAt, snapshot.capturedAt);
      expect(restored.devicePixelRatio, 1.875);
      expect(restored.root.testId, 'product.card');
    });

    test('carries the device pixel ratio that was current at capture', () {
      // Bounds are logical pixels; converting them needs the ratio from
      // the same read, not one captured at attach. See risk R3b.
      final snapshot = UiSnapshot(
        screenId: 'Home',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 1.875,
        root: node(),
      );

      expect(snapshot.devicePixelRatio, 1.875);
    });

    test('carries the viewport, which the synthetic root does not '
        'describe', () {
      // root.bounds is the union of the retained nodes. On a screen
      // whose content does not reach the edges it is smaller than the
      // display, and on one that overflows it is larger - so it can
      // never stand in for the viewport.
      final snapshot = UiSnapshot(
        screenId: 'ProductDetails',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 1.875,
        viewport: const LogicalRect(x: 0, y: 0, width: 384, height: 853.3),
        root: node(),
      );

      final restored = UiSnapshot.fromJson(snapshot.toJson());

      expect(restored.viewport?.width, 384);
      expect(restored.viewport?.height, 853.3);
    });

    test('leaves the viewport null when the app did not report one', () {
      // An app on an older SDK genuinely cannot supply it. Null says so;
      // substituting the root bounds would look like an answer.
      final snapshot = UiSnapshot(
        screenId: 'Home',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 1.875,
        root: node(),
      );

      expect(UiSnapshot.fromJson(snapshot.toJson()).viewport, isNull);
      expect(snapshot.toJson().containsKey('viewport'), isFalse);
    });

    test('reports how much of the tree was dropped by filtering', () {
      final snapshot = UiSnapshot(
        screenId: 'Home',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 1.875,
        root: node(),
        totalElementsWalked: 1842,
      );

      final restored = UiSnapshot.fromJson(snapshot.toJson());

      expect(restored.totalElementsWalked, 1842);
      expect(restored.retainedNodeCount, 1);
    });

    test('looks up an element by test id', () {
      final snapshot = UiSnapshot(
        screenId: 'Home',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 1.875,
        root: node(testId: 'root', children: [node(testId: 'home.search')]),
      );

      expect(snapshot.find('home.search'), isNotNull);
      expect(snapshot.find('missing'), isNull);
    });
  });

  group('WidgetTreePayload', () {
    test('round-trips as an event payload', () {
      final payload = WidgetTreePayload(
        snapshot: UiSnapshot(
          screenId: 'Home',
          capturedAt: DateTime.utc(2026),
          devicePixelRatio: 1.875,
          root: node(testId: 'home.search'),
        ),
      );

      final restored = EventPayload.fromJson(payload.type, payload.toJson())
          as WidgetTreePayload;

      expect(restored.type, EventType.widgetTree);
      expect(restored.snapshot.find('home.search'), isNotNull);
    });
  });

  group('ScreenshotPayload', () {
    test('records which capture path produced the image', () {
      // RepaintBoundary and adb screencap do not produce identical
      // images; diffing across paths would be meaningless. See risk R5.
      const payload = ScreenshotPayload(
        source: ScreenshotSource.repaintBoundary,
        width: 720,
        height: 1600,
        byteLength: 40950,
      );

      final restored = EventPayload.fromJson(payload.type, payload.toJson())
          as ScreenshotPayload;

      expect(restored.source, ScreenshotSource.repaintBoundary);
      expect(restored.width, 720);
      expect(restored.byteLength, 40950);
    });

    test('distinguishes a device screencap', () {
      const payload = ScreenshotPayload(
        source: ScreenshotSource.deviceScreencap,
        width: 720,
        height: 1600,
        byteLength: 1,
      );

      expect(
        (EventPayload.fromJson(payload.type, payload.toJson())
                as ScreenshotPayload)
            .source,
        ScreenshotSource.deviceScreencap,
      );
    });
  });
}
