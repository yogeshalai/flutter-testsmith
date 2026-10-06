// Which route a captured node actually belongs to.
//
// Flutter keeps a covered route built - `maintainState` defaults to true
// - so after a push the tree still holds every widget of the screen
// underneath, at its old bounds, reporting `visible: true`. The SDK
// records a one-based `routeIndex` per node so that this is detectable
// at all, and the highest index on a screen is the topmost route.
//
// Three places in the engine had already grown their own answer to
// "which route is on top": the quiescence check, the visual validator's
// element regions, and the property reader. This is that answer, in the
// one place that owns the shape of a snapshot, so the fourth caller does
// not write a fifth copy.
import 'package:test/test.dart';
import 'package:flutter_testsmith/protocol.dart';

const LogicalRect _rect = LogicalRect(x: 0, y: 0, width: 100, height: 40);

UiNode _node(
  String type, {
  String? testId,
  int? routeIndex,
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: testId,
      type: type,
      visible: true,
      bounds: _rect,
      properties: {'routeIndex': ?routeIndex},
      children: children,
    );

UiSnapshot _snapshot(List<UiNode> children) => UiSnapshot(
      screenId: '/top',
      capturedAt: DateTime.utc(2026, 9, 16),
      devicePixelRatio: 2,
      root: _node('Scaffold', children: children),
    );

void main() {
  group('a node reports the route it was captured in', () {
    test('an index recorded by the SDK is read back', () {
      expect(_node('Text', routeIndex: 2).routeIndex, 2);
    });

    test('a node outside any route has none', () {
      // App-level chrome lives outside the navigator and carries no
      // index. That is an absence, not a route zero.
      expect(_node('Text').routeIndex, isNull);
    });

    test('a non-integer index is read as none rather than guessed', () {
      const node = UiNode(
        type: 'Text',
        bounds: _rect,
        properties: {'routeIndex': 'two'},
      );
      expect(node.routeIndex, isNull);
    });
  });

  group('the topmost route is the highest index in the tree', () {
    test('a tree with no routes has no topmost route', () {
      expect(_snapshot([_node('Text', testId: 'bare')]).topRouteIndex, isNull);
    });

    test('a single route is the topmost one', () {
      expect(
        _snapshot([_node('Text', testId: 'only', routeIndex: 1)])
            .topRouteIndex,
        1,
      );
    });

    test('after a push, the pushed route is the topmost', () {
      expect(
        _snapshot([
          _node('Text', testId: 'under', routeIndex: 1),
          _node('Text', testId: 'over', routeIndex: 2),
        ]).topRouteIndex,
        2,
      );
    });

    test('the highest index wins wherever it sits in the tree', () {
      // Traversal order must not decide it: the deeper, later branch
      // here holds the higher index.
      expect(
        _snapshot([
          _node('Column', routeIndex: 3, children: [
            _node('Text', testId: 'a', routeIndex: 3),
          ]),
          _node('Column', children: [
            _node('Padding', children: [
              _node('Text', testId: 'b', routeIndex: 4),
            ]),
          ]),
        ]).topRouteIndex,
        4,
      );
    });
  });

  group('whether a node is on the route the user is looking at', () {
    test('a node on the topmost route is', () {
      final snapshot = _snapshot([
        _node('Text', testId: 'under', routeIndex: 1),
        _node('Text', testId: 'over', routeIndex: 2),
      ]);

      expect(snapshot.isOnTopRoute(snapshot.find('over')!), isTrue);
    });

    test('a node on a covered route is not', () {
      final snapshot = _snapshot([
        _node('Text', testId: 'under', routeIndex: 1),
        _node('Text', testId: 'over', routeIndex: 2),
      ]);

      expect(snapshot.isOnTopRoute(snapshot.find('under')!), isFalse);
    });

    test('a node outside any route is, because it is genuinely on screen',
        () {
      // Excluding app chrome would silently stop measuring things that
      // are plainly there.
      final snapshot = _snapshot([
        _node('Text', testId: 'chrome'),
        _node('Text', testId: 'over', routeIndex: 2),
      ]);

      expect(snapshot.isOnTopRoute(snapshot.find('chrome')!), isTrue);
    });

    test('every node is, in a tree that records no routes at all', () {
      // The graceful fallback: an older SDK, or a Flutter that renamed
      // the private scope widget, must not make everything unreachable.
      final snapshot = _snapshot([_node('Text', testId: 'bare')]);

      expect(snapshot.isOnTopRoute(snapshot.find('bare')!), isTrue);
    });
  });

  group('looking an element up on the screen the user can see', () {
    test('an id on the topmost route is found', () {
      final snapshot = _snapshot([
        _node('Text', testId: 'under', routeIndex: 1),
        _node('Text', testId: 'over', routeIndex: 2),
      ]);

      expect(snapshot.findOnTopRoute('over')?.testId, 'over');
    });

    test('an id only on a covered route is not found', () {
      final snapshot = _snapshot([
        _node('Text', testId: 'under', routeIndex: 1),
        _node('Text', testId: 'over', routeIndex: 2),
      ]);

      expect(snapshot.findOnTopRoute('under'), isNull);
      expect(snapshot.find('under'), isNotNull,
          reason: 'it is still in the tree - that is the whole problem');
    });

    test('an id on both routes resolves to the one on screen', () {
      // The case a plain depth-first search gets backwards. The covered
      // route was pushed first, so it comes first in the tree, and
      // `find` returns the copy nobody can see.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2),
      ]);

      expect(snapshot.find('cta')?.type, 'ElevatedButton');
      expect(snapshot.findOnTopRoute('cta')?.type, 'OutlinedButton');
    });

    test('an absent id is not found', () {
      expect(
        _snapshot([_node('Text', testId: 'a', routeIndex: 1)])
            .findOnTopRoute('b'),
        isNull,
      );
    });

    test('app chrome outside the navigator is found', () {
      final snapshot = _snapshot([
        _node('IconButton', testId: 'app.menu'),
        _node('Text', testId: 'over', routeIndex: 2),
      ]);

      expect(snapshot.findOnTopRoute('app.menu')?.testId, 'app.menu');
    });

    test('a tree recording no routes finds everything', () {
      final snapshot = _snapshot([_node('Text', testId: 'bare')]);
      expect(snapshot.findOnTopRoute('bare')?.testId, 'bare');
    });
  });

  group('counting the candidates a reader could have meant', () {
    test('one candidate on the visible route', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2),
      ]);

      final onTop = snapshot.nodesOnTopRoute('cta');
      expect(onTop, hasLength(1));
      expect(onTop.single.type, 'OutlinedButton');
    });

    test('two candidates on the visible route', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 2),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2),
      ]);

      expect(snapshot.nodesOnTopRoute('cta'), hasLength(2));
    });

    test('none, when the id is only on a covered route', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1),
        _node('AlertDialog', testId: 'dialog.ok', routeIndex: 2),
      ]);

      expect(snapshot.nodesOnTopRoute('cta'), isEmpty);
    });

    test('a tree recording no routes counts every match', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta'),
        _node('OutlinedButton', testId: 'cta'),
      ]);

      expect(snapshot.nodesOnTopRoute('cta'), hasLength(2));
    });

    test('findOnTopRoute is the first of the same candidates', () {
      // One rule, not two. The lookup must not be able to disagree with
      // the count about what is on screen.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2),
      ]);

      expect(
        snapshot.findOnTopRoute('cta'),
        same(snapshot.nodesOnTopRoute('cta').first),
      );
    });
  });

  group('the ids that are actually on screen', () {
    test('a covered route contributes none of its ids', () {
      final snapshot = _snapshot([
        _node('Text', testId: 'under', routeIndex: 1),
        _node('Text', testId: 'over', routeIndex: 2),
      ]);

      expect(snapshot.topRouteTestIds, contains('over'));
      expect(snapshot.topRouteTestIds, isNot(contains('under')));
    });

    test('app chrome is on screen', () {
      final snapshot = _snapshot([
        _node('IconButton', testId: 'app.menu'),
        _node('Text', testId: 'over', routeIndex: 2),
      ]);

      expect(snapshot.topRouteTestIds, containsAll(['app.menu', 'over']));
    });

    test('a tree recording no routes lists everything', () {
      final snapshot = _snapshot([
        _node('Text', testId: 'a'),
        _node('Text', testId: 'b'),
      ]);

      expect(snapshot.topRouteTestIds, containsAll(['a', 'b']));
    });
  });
}
