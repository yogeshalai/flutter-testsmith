import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// D-12: the regression test.
///
/// Flutter keeps a covered route built - `maintainState` defaults to
/// true - so the element tree on screen B still contains every widget of
/// screen A, at its old bounds, reporting `visible: true`. Measured
/// during external-application validation: capturing after a push
/// returned *both* routes' test ids.
///
/// Phase 12 saw the consequence without diagnosing it: `home.open_cart`
/// was named among the worst-differing elements of a screenshot taken on
/// `/product/details`.

Future<UiSnapshot> capture(WidgetTester tester, String screenId) async {
  await tester.pumpAndSettle();
  return const UiTreeInspector().capture(
    root: tester.binding.rootElement!,
    screenId: screenId,
    devicePixelRatio: 2,
  );
}

Future<GlobalKey<NavigatorState>> pumpTwoRoutes(WidgetTester tester) async {
  final navigator = GlobalKey<NavigatorState>();

  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      routes: {
        '/': (_) => const Scaffold(
              body: Center(child: Text('under', key: TestKey('under.label'))),
            ),
        '/top': (_) => const Scaffold(
              body: Center(child: Text('over', key: TestKey('over.label'))),
            ),
      },
    ),
  );
  await tester.pumpAndSettle();
  return navigator;
}

void main() {
  group('route attribution in the captured tree', () {
    testWidgets('a node records which route it belongs to', (tester) async {
      await pumpTwoRoutes(tester);
      final snapshot = await capture(tester, '/');

      expect(
        snapshot.find('under.label')?.properties['routeIndex'],
        isA<int>(),
        reason: 'without this the covered-route problem is undetectable',
      );
    });

    testWidgets('a covered route gets a lower index than the current one',
        (tester) async {
      final navigator = await pumpTwoRoutes(tester);
      unawaited(navigator.currentState!.pushNamed<void>('/top'));

      final snapshot = await capture(tester, '/top');

      final under = snapshot.find('under.label')!.properties['routeIndex']!;
      final over = snapshot.find('over.label')!.properties['routeIndex']!;

      expect(under as int, lessThan(over as int));
    });

    testWidgets('the covered route is still in the tree, which is why this '
        'matters', (tester) async {
      // Not a bug being fixed here - it is the fact the fix works
      // around. Asserted so that if Flutter ever stops keeping covered
      // routes built, this test says so rather than passing silently.
      final navigator = await pumpTwoRoutes(tester);
      unawaited(navigator.currentState!.pushNamed<void>('/top'));

      final snapshot = await capture(tester, '/top');

      expect(snapshot.find('under.label'), isNotNull);
      expect(snapshot.find('under.label')?.visible, isTrue);
    });
  });

  group('visual measurement is confined to the current route', () {
    testWidgets('a covered route contributes no element region',
        (tester) async {
      final navigator = await pumpTwoRoutes(tester);
      unawaited(navigator.currentState!.pushNamed<void>('/top'));

      final snapshot = await capture(tester, '/top');
      final measured = regionLabelsFor(snapshot);

      expect(measured, contains('over.label'));
      expect(
        measured,
        isNot(contains('under.label')),
        reason: 'its pixels belong to whatever is painted over it',
      );
    });

    testWidgets('before any push, the only route is measured', (tester) async {
      await pumpTwoRoutes(tester);
      final snapshot = await capture(tester, '/');

      expect(regionLabelsFor(snapshot), contains('under.label'));
    });

    testWidgets('a tree with no route indices measures everything',
        (tester) async {
      // The graceful fallback: an older SDK, or a Flutter that renamed
      // the scope widget, must not silently stop measuring.
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: Text('bare', key: TestKey('bare.label'))),
        ),
      );
      final snapshot = await capture(tester, '/bare');

      expect(snapshot.find('bare.label')?.properties['routeIndex'], isNull);
      expect(regionLabelsFor(snapshot), contains('bare.label'));
    });
  });
}

/// Which element ids the visual validator would measure.
///
/// Mirrors `VisualValidator._elementRegions` rather than calling it:
/// SDK code must not reach engine code, which is the constraint
/// `scripts/check_dependencies.dart` enforces (rule A). The engine side has its
/// own test over the same rule.
Set<String> regionLabelsFor(UiSnapshot snapshot) {
  int? topmost;
  void findTop(UiNode node) {
    final index = node.properties['routeIndex'];
    if (index is int && (topmost == null || index > topmost!)) {
      topmost = index;
    }
    node.children.forEach(findTop);
  }

  findTop(snapshot.root);

  return {
    for (final id in snapshot.root.testIds)
      if (snapshot.find(id) case final node?)
        if (!node.bounds.isEmpty)
          if (topmost == null ||
              node.properties['routeIndex'] is! int ||
              (node.properties['routeIndex']! as int) >= topmost!)
            id,
  };
}
