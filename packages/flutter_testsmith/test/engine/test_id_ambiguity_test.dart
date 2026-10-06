// Ambiguity was decided over the whole tree; resolution over the screen.
//
// `duplicateTestIds` is built by the SDK while walking the *entire*
// element tree, and Flutter keeps a covered route built. So navigating
// A -> B, where both screens carry `cta`, flagged `cta` as duplicated
// for the rest of the session - and `nodeFor` refused to tap it, though
// exactly one `cta` was on screen and exactly one could receive a touch.
//
// The protocol fact stays what it is: "this id appears on more than one
// element in the retained tree" is true, is a real defect in the
// application's ids, and is what `testsmith inspect` reports. What changes
// is the question the *action resolver* asks, which is narrower:
//
//     how many candidates could this tap actually land on?
//
// Counted among the elements on the visible route, because an element
// nobody can see is not one a reader could have meant.
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const LogicalRect _box = LogicalRect(x: 100, y: 200, width: 120, height: 40);
const LogicalRect _screen = LogicalRect(x: 0, y: 0, width: 400, height: 800);

/// [routeIndex] is deliberately [Object?] so a malformed value - a
/// string where an int belongs - can be captured as the SDK might.
UiNode _node(
  String type, {
  String? testId,
  Object? routeIndex,
  LogicalRect bounds = _box,
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: testId,
      type: type,
      visible: true,
      bounds: bounds,
      properties: {'routeIndex': ?routeIndex},
      children: children,
    );

UiSnapshot _snapshot(
  List<UiNode> children, {
  Set<String> duplicates = const {},
}) =>
    UiSnapshot(
      screenId: '/top',
      capturedAt: DateTime.utc(2026, 9, 16),
      devicePixelRatio: 2,
      viewport: _screen,
      duplicateTestIds: duplicates,
      root: _node('Scaffold', bounds: _screen, children: children),
    );

void main() {
  group('CASE 1 - the same id on the screen and on the one underneath', () {
    test('resolves to the element on the visible route', () {
      // The id is duplicated in the tree, and the SDK says so. Exactly
      // one copy can be touched.
      final snapshot = _snapshot(
        [
          _node('ElevatedButton', testId: 'cta', routeIndex: 1),
          _node('OutlinedButton', testId: 'cta', routeIndex: 2),
        ],
        duplicates: {'cta'},
      );

      expect(ElementLocator(snapshot).nodeFor('cta').type, 'OutlinedButton');
    });

    test('and is tappable, rather than refused as ambiguous', () {
      final snapshot = _snapshot(
        [
          _node('ElevatedButton', testId: 'cta', routeIndex: 1),
          _node('OutlinedButton', testId: 'cta', routeIndex: 2),
        ],
        duplicates: {'cta'},
      );

      expect(ElementLocator(snapshot).pointFor('cta'),
          const PhysicalPoint(320, 440));
    });
  });

  group('CASE 2 - the same id twice on the visible route', () {
    test('is still refused', () {
      final snapshot = _snapshot(
        [
          _node('ElevatedButton', testId: 'cta', routeIndex: 2),
          _node('OutlinedButton', testId: 'cta', routeIndex: 2),
        ],
        duplicates: {'cta'},
      );

      expect(
        () => ElementLocator(snapshot).nodeFor('cta'),
        throwsA(isA<AmbiguousElementException>()),
      );
    });

    test('the refusal counts the candidates and names the route', () {
      final snapshot = _snapshot(
        [
          _node('ElevatedButton', testId: 'cta', routeIndex: 2),
          _node('OutlinedButton', testId: 'cta', routeIndex: 2),
        ],
        duplicates: {'cta'},
      );

      try {
        ElementLocator(snapshot).nodeFor('cta');
        fail('two candidates on one screen were resolved');
      } on AmbiguousElementException catch (error) {
        expect(error.testId, 'cta');
        expect(error.candidates, 2);
        expect(error.routeIndex, 2);
        expect('$error', contains('2'));
      }
    });

    test('it is refused even when the capture flagged nothing', () {
      // The tree is the evidence. A capture that failed to flag the
      // duplicate does not make two candidates into one.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 2),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2),
      ]);

      expect(
        () => ElementLocator(snapshot).nodeFor('cta'),
        throwsA(isA<AmbiguousElementException>()),
      );
    });
  });

  group('CASE 3 - the id exists only on a covered route', () {
    test('it is not resolved as a success', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1),
        _node('AlertDialog', testId: 'dialog.ok', routeIndex: 2),
      ]);

      expect(
        () => ElementLocator(snapshot).pointFor('cta'),
        throwsA(isA<ElementNotTappableException>()),
      );
    });

    test('the diagnostic says covered, not missing and not ambiguous', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1),
        _node('AlertDialog', testId: 'dialog.ok', routeIndex: 2),
      ]);

      try {
        ElementLocator(snapshot).pointFor('cta');
        fail('a covered element was tapped');
      } on ElementNotTappableException catch (error) {
        expect(error.reason, contains('route'));
      }
    });

    test('an id nowhere in the tree is still "not found"', () {
      final snapshot = _snapshot([
        _node('AlertDialog', testId: 'dialog.ok', routeIndex: 2),
      ]);

      expect(
        () => ElementLocator(snapshot).pointFor('cta'),
        throwsA(isA<ElementNotFoundException>()),
      );
    });
  });

  group('CASE 4 - a capture that records no routes keeps legacy behaviour',
      () {
    test('an id the capture flagged as duplicated is refused', () {
      // The tree retains one copy; the SDK walked the element tree and
      // saw more. With no route information there is nothing better to
      // go on, so the protocol's own fact decides - exactly as before.
      final snapshot = _snapshot(
        [_node('ElevatedButton', testId: 'cta')],
        duplicates: {'cta'},
      );

      expect(
        () => ElementLocator(snapshot).nodeFor('cta'),
        throwsA(isA<AmbiguousElementException>()),
      );
    });

    test('an unflagged single element resolves', () {
      final snapshot = _snapshot([_node('ElevatedButton', testId: 'cta')]);
      expect(ElementLocator(snapshot).nodeFor('cta').type, 'ElevatedButton');
    });

    test('two retained copies are refused', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta'),
        _node('OutlinedButton', testId: 'cta'),
      ]);

      expect(
        () => ElementLocator(snapshot).nodeFor('cta'),
        throwsA(isA<AmbiguousElementException>()),
      );
    });
  });

  group('CASE 5 - a malformed route index is not turned into a route', () {
    test('a non-integer index reads as "no route", deterministically', () {
      // `UiNode.routeIndex` refuses to guess, so such a node is treated
      // as being outside any route - which is the existing fallback,
      // not a new invention.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 'two'),
        _node('AlertDialog', testId: 'dialog.ok', routeIndex: 2),
      ]);

      expect(snapshot.find('cta')!.routeIndex, isNull);
      expect(ElementLocator(snapshot).nodeFor('cta').type, 'ElevatedButton');
    });
  });

  group('CASE 6 - matching stays exactly what TestId matching was', () {
    test('a nested candidate on the visible route still counts', () {
      // No ancestor or sibling filtering is introduced. Two candidates
      // are two candidates, however deeply either one sits.
      final snapshot = _snapshot([
        _node('Column', routeIndex: 2, children: [
          _node('Padding', routeIndex: 2, children: [
            _node('ElevatedButton', testId: 'cta', routeIndex: 2),
          ]),
        ]),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2),
      ]);

      expect(
        () => ElementLocator(snapshot).nodeFor('cta'),
        throwsA(isA<AmbiguousElementException>()),
      );
    });
  });

  group('duplicates on covered routes do not poison the visible target', () {
    test('one on the screen, two underneath, resolves', () {
      final snapshot = _snapshot(
        [
          _node('ElevatedButton', testId: 'cta', routeIndex: 1),
          _node('TextButton', testId: 'cta', routeIndex: 1),
          _node('OutlinedButton', testId: 'cta', routeIndex: 3),
        ],
        duplicates: {'cta'},
      );

      expect(ElementLocator(snapshot).nodeFor('cta').type, 'OutlinedButton');
    });

    test('two underneath and none on screen is covered, not ambiguous', () {
      final snapshot = _snapshot(
        [
          _node('ElevatedButton', testId: 'cta', routeIndex: 1),
          _node('TextButton', testId: 'cta', routeIndex: 1),
          _node('AlertDialog', testId: 'dialog.ok', routeIndex: 2),
        ],
        duplicates: {'cta'},
      );

      expect(
        () => ElementLocator(snapshot).pointFor('cta'),
        throwsA(isA<ElementNotTappableException>()),
      );
    });
  });

  group('a "not found" offers only ids a reader can actually see', () {
    test('an id on a covered route is not suggested as an alternative', () {
      // Offering the name of something on a screen the flow has already
      // left sends a reader looking for a typo that is not there.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'home.open_cart', routeIndex: 1),
        _node('AlertDialog', testId: 'dialog.ok', routeIndex: 2),
      ]);

      try {
        ElementLocator(snapshot).nodeFor('typo');
        fail('resolved');
      } on ElementNotFoundException catch (error) {
        expect(error.available, contains('dialog.ok'));
        expect(error.available, isNot(contains('home.open_cart')));
      }
    });

    test('a capture with no routes still lists everything', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'a'),
        _node('OutlinedButton', testId: 'b'),
      ]);

      try {
        ElementLocator(snapshot).nodeFor('typo');
        fail('resolved');
      } on ElementNotFoundException catch (error) {
        expect(error.available, containsAll(<String>['a', 'b']));
      }
    });
  });

  group('the protocol fact itself is untouched', () {
    test('the capture still reports what it saw', () {
      // Nothing here rewrites the wire field. `testsmith inspect` must keep
      // reporting duplicated ids as the application defect they are.
      final snapshot = _snapshot(
        [
          _node('ElevatedButton', testId: 'cta', routeIndex: 1),
          _node('OutlinedButton', testId: 'cta', routeIndex: 2),
        ],
        duplicates: {'cta'},
      );

      expect(snapshot.duplicateTestIds, contains('cta'));
      expect(snapshot.hasAmbiguousIds, isTrue);
    });
  });
}
