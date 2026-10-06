// A tap was dispatched at a screen the user had navigated away from.
//
// Flutter keeps a covered route built, so after a dialog, a bottom sheet
// or any pushed route the tree still holds the screen underneath - same
// test ids, same bounds, `visible: true`. `snapshot.find` is a
// depth-first search over the whole tree, so `tap: {id: home.open_cart}`
// resolved the *covered* node, computed its old centre, and dispatched a
// tap there. adb exited 0 and the step reported success, while the touch
// landed on whatever the route on top happened to be painting.
//
// The engine already knew how to tell these apart. The quiescence check
// excludes animations below the top route, the visual validator excludes
// their pixels, and the property reader refuses to read text across
// routes. The action path, which is the one that actually touches the
// device, consulted none of it.
//
// This is the same distinction as the previous milestone one layer out:
// TARGET EXISTS is not TARGET IS ON THE SCREEN.
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/protocol.dart';

const LogicalRect _button = LogicalRect(x: 100, y: 200, width: 120, height: 40);
const LogicalRect _screen = LogicalRect(x: 0, y: 0, width: 400, height: 800);

UiNode _node(
  String type, {
  String? testId,
  int? routeIndex,
  bool visible = true,
  LogicalRect bounds = _button,
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: testId,
      type: type,
      visible: visible,
      bounds: bounds,
      properties: {'routeIndex': ?routeIndex},
      children: children,
    );

UiSnapshot _snapshot(List<UiNode> children) => UiSnapshot(
      screenId: '/top',
      capturedAt: DateTime.utc(2026, 9, 16),
      devicePixelRatio: 2,
      viewport: _screen,
      root: _node('Scaffold', bounds: _screen, children: children),
    );

/// The screen underneath, plus a dialog pushed over it.
UiSnapshot _withDialog() => _snapshot([
      _node('ElevatedButton', testId: 'home.open_cart', routeIndex: 1),
      _node('AlertDialog', testId: 'dialog.confirm', routeIndex: 2),
    ]);

/// Serves a frame per capture, and counts the captures.
class _Screen {
  _Screen(this._frames);

  final List<UiSnapshot> _frames;
  int reads = 0;

  Future<UiSnapshot> capture() async {
    final frame = _frames[reads < _frames.length ? reads : _frames.length - 1];
    reads++;
    return frame;
  }
}

void main() {
  group('a target on a covered route is refused, not tapped', () {
    test('the screen underneath a dialog cannot be tapped', () {
      expect(
        () => ElementLocator(_withDialog()).pointFor('home.open_cart'),
        throwsA(isA<ElementNotTappableException>()),
      );
    });

    test('the refusal names the route measured and the route on top', () {
      try {
        ElementLocator(_withDialog()).pointFor('home.open_cart');
        fail('a covered element was tapped');
      } on ElementNotTappableException catch (error) {
        expect(error.testId, 'home.open_cart');
        expect(error.reason, contains('1'));
        expect(error.reason, contains('2'));
      }
    });

    test('the refusal is not phrased as a visibility problem', () {
      // The covered node reports `visible: true` and real bounds - that
      // is exactly why this needed its own check - so borrowing the
      // visibility wording would send a reader to measure the wrong
      // thing.
      final covered = _withDialog().find('home.open_cart')!;
      expect(covered.visible, isTrue);
      expect(covered.bounds.isEmpty, isFalse);

      try {
        ElementLocator(_withDialog()).pointFor('home.open_cart');
        fail('a covered element was tapped');
      } on ElementNotTappableException catch (error) {
        expect(error.reason, isNot(contains('not visible')));
        expect(error.reason, isNot(contains('zero area')));
      }
    });
  });

  group('everything genuinely on screen is still tapped', () {
    test('the element on the topmost route is tapped', () {
      expect(
        ElementLocator(_withDialog()).pointFor('dialog.confirm'),
        const PhysicalPoint(320, 440),
      );
    });

    test('app chrome outside the navigator is tapped', () {
      // A node with no route index sits outside any route and is
      // genuinely on screen. Refusing it would make the toolbar of
      // every application unreachable.
      final snapshot = _snapshot([
        _node('IconButton', testId: 'app.menu'),
        _node('AlertDialog', testId: 'dialog.confirm', routeIndex: 2),
      ]);

      expect(ElementLocator(snapshot).pointFor('app.menu'), isNotNull);
    });

    test('a tree that records no routes at all is tapped', () {
      // The graceful fallback. An older SDK, or a Flutter that renamed
      // the private route-scope widget, reports no indices - and must
      // not make every element unreachable.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta'),
      ]);

      expect(ElementLocator(snapshot).pointFor('cta'), isNotNull);
    });

    test('before any push, the only route is tappable', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1),
      ]);

      expect(ElementLocator(snapshot).pointFor('cta'), isNotNull);
    });

    test('a descendant of the top route is tapped', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'home.open_cart', routeIndex: 1),
        _node('AlertDialog', routeIndex: 2, children: [
          _node('TestId', testId: 'dialog.ok', routeIndex: 2),
        ]),
      ]);

      expect(ElementLocator(snapshot).pointFor('dialog.ok'), isNotNull);
    });
  });

  group('the existing refusals keep their own words', () {
    test('an absent element is still "not found"', () {
      expect(
        () => ElementLocator(_withDialog()).pointFor('nope'),
        throwsA(isA<ElementNotFoundException>()),
      );
    });

    test('zero area on the top route is still reported as area', () {
      final snapshot = _snapshot([
        _node(
          'ElevatedButton',
          testId: 'collapsed',
          routeIndex: 1,
          bounds: const LogicalRect(x: 0, y: 0, width: 0, height: 0),
        ),
      ]);

      expect(
        () => ElementLocator(snapshot).pointFor('collapsed'),
        throwsA(
          isA<ElementNotTappableException>()
              .having((e) => e.reason, 'reason', contains('zero area')),
        ),
      );
    });
  });

  group('the waiter turns the gate into a bounded wait', () {
    test('a dialog that closes is waited for, then the screen is tapped',
        () async {
      // The ordinary shape: a flow taps through a confirmation and then
      // continues on the screen underneath. Without the gate the second
      // tap raced the dialog's dismissal.
      final screen = _Screen([
        _withDialog(),
        _withDialog(),
        _snapshot([
          _node('ElevatedButton', testId: 'home.open_cart', routeIndex: 1),
        ]),
      ]);

      final point = await const ElementWaiter(
        timeout: Duration(seconds: 5),
        pollInterval: Duration(milliseconds: 1),
      ).pointWhenTappable('home.open_cart', screen.capture);

      expect(point, const PhysicalPoint(320, 440));
      expect(screen.reads, 3);
    });

    test('a dialog that never closes is refused, naming why', () async {
      final screen = _Screen([_withDialog()]);

      await expectLater(
        const ElementWaiter(
          timeout: Duration(milliseconds: 40),
          pollInterval: Duration(milliseconds: 1),
        ).pointWhenTappable('home.open_cart', screen.capture),
        throwsA(
          isA<ElementNotTappableException>()
              .having((e) => e.testId, 'testId', 'home.open_cart')
              .having((e) => e.reason, 'reason', contains('route')),
        ),
      );
    });

    test('an element on the top route is tapped on the first capture',
        () async {
      final screen = _Screen([_withDialog()]);

      await const ElementWaiter(timeout: Duration(seconds: 5))
          .pointWhenTappable('dialog.confirm', screen.capture);

      expect(screen.reads, 1, reason: 'it waited when it did not need to');
    });
  });
}
