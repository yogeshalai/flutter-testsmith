import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/protocol.dart';

UiSnapshot snapshotWith(
  List<UiNode> children, {
  double devicePixelRatio = 1.875,
  Set<String> duplicates = const {},
}) =>
    UiSnapshot(
      screenId: 'ProductDetails',
      capturedAt: DateTime.utc(2026),
      devicePixelRatio: devicePixelRatio,
      duplicateTestIds: duplicates,
      root: UiNode(
        type: 'Root',
        bounds: const LogicalRect(x: 0, y: 0, width: 384, height: 853),
        children: children,
      ),
    );

UiNode leaf(
  String id, {
  double x = 24,
  double y = 164,
  double width = 160,
  double height = 40,
  bool visible = true,
}) =>
    UiNode(
      testId: id,
      type: 'FilledButton',
      visible: visible,
      bounds: LogicalRect(x: x, y: y, width: width, height: height),
    );

void main() {
  offScreenTests();
  group('locating an element', () {
    test('resolves a test id to the physical centre of its bounds', () {
      final snapshot = snapshotWith([leaf('product.add_to_cart')]);

      final point = ElementLocator(snapshot).pointFor('product.add_to_cart');

      // Logical centre (104, 184) at 1.875 -> (195, 345).
      expect(point, const PhysicalPoint(195, 345));
    });

    test('uses the ratio recorded in the snapshot, not an assumed one', () {
      // Bounds and ratio must come from the same read; using an
      // attach-time ratio here is exactly the R3b bug.
      final snapshot = snapshotWith(
        [leaf('cta', x: 0, y: 0, width: 100, height: 100)],
        devicePixelRatio: 3,
      );

      expect(ElementLocator(snapshot).pointFor('cta'),
          const PhysicalPoint(150, 150));
    });

    test('finds a deeply nested element', () {
      final snapshot = snapshotWith([
        UiNode(
          type: 'Card',
          bounds: const LogicalRect(x: 0, y: 0, width: 384, height: 200),
          children: [leaf('deep.button')],
        ),
      ]);

      expect(ElementLocator(snapshot).pointFor('deep.button'), isNotNull);
    });
  });

  group('failures are diagnosable', () {
    test('a missing id lists what is actually available', () {
      // "element not found" alone sends the author hunting; naming the
      // ids present usually shows the typo immediately.
      final snapshot = snapshotWith([
        leaf('product.add_to_cart'),
        leaf('product.name'),
      ]);

      expect(
        () => ElementLocator(snapshot).pointFor('product.addToCart'),
        throwsA(
          isA<ElementNotFoundException>()
              .having((e) => e.toString(), 'message',
                  contains('product.addToCart'))
              .having((e) => e.toString(), 'message',
                  contains('product.add_to_cart')),
        ),
      );
    });

    test('a zero-area element is refused rather than tapped', () {
      // Tapping a zero-sized widget silently does nothing, which is far
      // harder to diagnose than a refusal.
      final snapshot = snapshotWith([leaf('collapsed', width: 0, height: 0)]);

      expect(
        () => ElementLocator(snapshot).pointFor('collapsed'),
        throwsA(
          isA<ElementNotTappableException>()
              .having((e) => e.toString(), 'message', contains('collapsed'))
              .having((e) => e.toString(), 'message', contains('zero')),
        ),
      );
    });

    test('an invisible element is refused', () {
      final snapshot = snapshotWith([leaf('hidden', visible: false)]);

      expect(
        () => ElementLocator(snapshot).pointFor('hidden'),
        throwsA(isA<ElementNotTappableException>()),
      );
    });

    test('an ambiguous id is refused rather than guessed', () {
      final snapshot = snapshotWith(
        [leaf('product.name')],
        duplicates: {'product.name'},
      );

      expect(
        () => ElementLocator(snapshot).pointFor('product.name'),
        throwsA(
          isA<AmbiguousElementException>()
              .having((e) => e.toString(), 'message', contains('product.name')),
        ),
      );
    });

    test('an empty tree still gives a usable message', () {
      final snapshot = snapshotWith([]);

      expect(
        () => ElementLocator(snapshot).pointFor('anything'),
        throwsA(isA<ElementNotFoundException>()),
      );
    });
  });

  group('inspection helpers', () {
    test('lists the available ids in tree order', () {
      final snapshot = snapshotWith([leaf('a'), leaf('b'), leaf('c')]);

      expect(ElementLocator(snapshot).availableIds, ['a', 'b', 'c']);
    });

    test('reports whether an id exists without throwing', () {
      final snapshot = snapshotWith([leaf('a')]);
      final locator = ElementLocator(snapshot);

      expect(locator.contains('a'), isTrue);
      expect(locator.contains('b'), isFalse);
    });
  });
}

/// Added in Phase 12, after a device run tapped an element that was
/// below the fold and Android delivered the tap to nothing.
void offScreenTests() {
  UiSnapshot withViewport(LogicalRect bounds) => UiSnapshot(
        screenId: '/s',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 2,
        viewport: const LogicalRect(x: 0, y: 0, width: 384, height: 805),
        root: UiNode(
          type: 'Root',
          bounds: const LogicalRect(x: 0, y: 0, width: 384, height: 2000),
          children: [
            UiNode(testId: 'below', type: 'TextButton', bounds: bounds),
          ],
        ),
      );

  group('an element off the bottom of the screen', () {
    test('is refused, with the measurement that explains it', () {
      final locator = ElementLocator(
        withViewport(
          const LogicalRect(x: 20, y: 1100, width: 100, height: 40),
        ),
      );

      expect(
        () => locator.pointFor('below'),
        throwsA(
          isA<ElementNotTappableException>().having(
            (e) => e.reason,
            'reason',
            allOf(
              contains('off screen'),
              contains('384x805'),
              contains('1120.0'),
            ),
          ),
        ),
      );
    });

    test('one that is on screen is still tappable', () {
      final locator = ElementLocator(
        withViewport(const LogicalRect(x: 20, y: 400, width: 100, height: 40)),
      );

      expect(locator.pointFor('below'), const PhysicalPoint(140, 840));
    });

    test('an element straddling the fold is tappable if its centre is on '
        'screen', () {
      // A tap lands at the centre, so that is what has to be reachable.
      final locator = ElementLocator(
        withViewport(const LogicalRect(x: 20, y: 780, width: 100, height: 40)),
      );

      expect(locator.pointFor('below').y, 1600);
    });
  });
}
