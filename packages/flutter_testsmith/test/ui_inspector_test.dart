import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// Captures the tree for whatever [child] renders, at a fixed surface size
/// so bounds assertions are exact.
Future<UiSnapshot> captureTree(
  WidgetTester tester,
  Widget child, {
  UiRetentionPolicy policy = const UiRetentionPolicy.defaults(),
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    ),
  );
  await tester.pumpAndSettle();

  return UiTreeInspector(policy: policy).capture(
    root: tester.binding.rootElement!,
    screenId: 'TestScreen',
    devicePixelRatio: 1.875,
  );
}

void main() {
  main2();
  main3();
  main4();
  group('retention', () {
    testWidgets('keeps every element carrying a test id', (tester) async {
      final snapshot = await captureTree(
        tester,
        Column(
          children: [
            const Text('a', key: TestKey('one')),
            Container(
              key: const TestKey('two'),
              width: 10,
              height: 10,
            ),
          ],
        ),
      );

      expect(snapshot.root.testIds, containsAll(<String>['one', 'two']));
    });

    testWidgets('keeps interesting widget types without a test id',
        (tester) async {
      final snapshot = await captureTree(tester, const Text('hello'));

      final types = _allTypes(snapshot.root);
      expect(types, contains('Text'));
    });

    testWidgets('drops pure layout scaffolding', (tester) async {
      // A raw element tree is mostly Padding, Align, DefaultTextStyle and
      // friends. Shipping those on every screen transition is what makes
      // the payload unusable.
      final snapshot = await captureTree(
        tester,
        const Padding(
          padding: EdgeInsets.all(8),
          child: Align(child: Text('deep', key: TestKey('deep'))),
        ),
      );

      final types = _allTypes(snapshot.root);
      expect(types, isNot(contains('Padding')));
      expect(types, isNot(contains('Align')));
      expect(snapshot.find('deep'), isNotNull);
    });

    testWidgets('re-parents the children of a dropped node', (tester) async {
      // Dropping a node must not drop its subtree.
      final snapshot = await captureTree(
        tester,
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('kept', key: TestKey('kept')),
        ),
      );

      expect(snapshot.find('kept'), isNotNull);
    });

    testWidgets('preserves sibling order', (tester) async {
      final snapshot = await captureTree(
        tester,
        const Column(
          children: [
            Text('first', key: TestKey('a')),
            Text('second', key: TestKey('b')),
            Text('third', key: TestKey('c')),
          ],
        ),
      );

      final ids = _orderedTestIds(snapshot.root);
      expect(ids, ['a', 'b', 'c']);
    });

    testWidgets('reports how many elements were walked before filtering',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('x', key: TestKey('x')),
        ),
      );

      expect(snapshot.totalElementsWalked,
          greaterThan(snapshot.retainedNodeCount));
    });

    testWidgets('a wider policy retains more', (tester) async {
      const widget = Padding(
        padding: EdgeInsets.all(8),
        child: Text('x', key: TestKey('x')),
      );

      final narrow = await captureTree(tester, widget);
      final wide = await captureTree(
        tester,
        widget,
        policy: const UiRetentionPolicy.everything(),
      );

      expect(wide.retainedNodeCount, greaterThan(narrow.retainedNodeCount));
    });
  });

  group('node content', () {
    testWidgets('captures text', (tester) async {
      final snapshot = await captureTree(
        tester,
        const Text('Nike Air Max', key: TestKey('product.name')),
      );

      expect(snapshot.find('product.name')!.text, 'Nike Air Max');
    });

    testWidgets('records the widget type from the element tree',
        (tester) async {
      // The semantics tree alone cannot supply this.
      final snapshot = await captureTree(
        tester,
        Center(
          child: FilledButton(
            key: const TestKey('cta'),
            onPressed: () {},
            child: const Text('Go'),
          ),
        ),
      );

      expect(snapshot.find('cta')!.type, 'FilledButton');
    });

    testWidgets('reports an enabled button as enabled', (tester) async {
      final snapshot = await captureTree(
        tester,
        Center(
          child: FilledButton(
            key: const TestKey('cta'),
            onPressed: () {},
            child: const Text('Go'),
          ),
        ),
      );

      expect(snapshot.find('cta')!.enabled, isTrue);
    });

    testWidgets('reports a button with no callback as disabled',
        (tester) async {
      // The motivating example: add-to-cart disabled when unavailable.
      final snapshot = await captureTree(
        tester,
        const Center(
          child: FilledButton(
            key: TestKey('cta'),
            onPressed: null,
            child: Text('Go'),
          ),
        ),
      );

      expect(snapshot.find('cta')!.enabled, isFalse);
    });

    testWidgets('leaves enabled null for a widget that has no such notion',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        const Text('plain', key: TestKey('plain')),
      );

      expect(snapshot.find('plain')!.enabled, isNull);
    });

    testWidgets('captures a text field value and enabled state',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        // A full MaterialApp: TextField needs both a Material ancestor
        // and MaterialLocalizations.
        MaterialApp(
          home: Scaffold(
            body: TextField(
              key: const TestKey('search'),
              controller: TextEditingController(text: 'Nike'),
              enabled: false,
            ),
          ),
        ),
      );

      final field = snapshot.find('search')!;
      expect(field.text, 'Nike');
      expect(field.enabled, isFalse);
    });
  });

  group('geometry', () {
    testWidgets('reports bounds in logical pixels', (tester) async {
      final snapshot = await captureTree(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 32, top: 48),
            child: Container(
              key: const TestKey('box'),
              width: 120,
              height: 40,
              color: const Color(0xFF000000),
            ),
          ),
        ),
      );

      final bounds = snapshot.find('box')!.bounds;
      expect(bounds.x, 32);
      expect(bounds.y, 48);
      expect(bounds.width, 120);
      expect(bounds.height, 40);
    });

    testWidgets('the centre of those bounds is where a tap should land',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 32, top: 48),
            child: Container(
              key: const TestKey('box'),
              width: 120,
              height: 40,
              color: const Color(0xFF000000),
            ),
          ),
        ),
      );

      final bounds = snapshot.find('box')!.bounds;
      expect(bounds.centreX, 92);
      expect(bounds.centreY, 68);
    });

    testWidgets('carries the device pixel ratio given at capture',
        (tester) async {
      final snapshot = await captureTree(tester, const Text('x'));

      expect(snapshot.devicePixelRatio, 1.875);
    });
  });

  group('duplicate ids', () {
    testWidgets('are reported rather than silently resolved to the first',
        (tester) async {
      // The realistic case is not sibling duplicates - Flutter forbids
      // those outright - but the same id reused in two subtrees, such as
      // a list where every product card marks its name 'product.name'.
      // That makes every assertion about the id ambiguous, so it is
      // reported rather than resolved by a coin toss. See ADR-0004.
      final snapshot = await captureTree(
        tester,
        const Column(
          children: [
            Card(child: Text('a', key: TestKey('dup'))),
            Card(child: Text('b', key: TestKey('dup'))),
          ],
        ),
      );

      expect(snapshot.duplicateTestIds, contains('dup'));
    });

    testWidgets('an unambiguous tree reports none', (tester) async {
      final snapshot = await captureTree(
        tester,
        const Text('a', key: TestKey('unique')),
      );

      expect(snapshot.duplicateTestIds, isEmpty);
    });
  });
}

Set<String> _allTypes(UiNode node) => {
      node.type,
      for (final child in node.children) ..._allTypes(child),
    };

List<String> _orderedTestIds(UiNode node) => [
      if (node.testId != null) node.testId!,
      for (final child in node.children) ..._orderedTestIds(child),
    ];

// ---------------------------------------------------------------------------
// Measured against the real device: 261 elements produced 32 retained
// nodes, but ten of those were empty Semantics wrappers with identical
// bounds, and every Text carried a duplicate RichText child. Both are
// noise that makes the tree harder to read without adding information.
// This is risk R4 in practice.
// ---------------------------------------------------------------------------
void main2() {
  group('noise suppression', () {
    testWidgets('drops a structural Semantics that carries no data',
        (tester) async {
      // RenderObject.debugSemantics reports the node an element
      // *contributed to*, often an ancestor's, so it is not evidence that
      // this element is itself interesting.
      final snapshot = await captureTree(
        tester,
        Semantics(
          child: Semantics(
            child: const Text('x', key: TestKey('x')),
          ),
        ),
      );

      expect(_allTypes(snapshot.root), isNot(contains('Semantics')));
      expect(snapshot.find('x'), isNotNull);
    });

    testWidgets('keeps a Semantics that carries an identifier',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        Semantics(
          identifier: 'legacy.thing',
          child: const SizedBox(width: 10, height: 10),
        ),
      );

      expect(snapshot.find('legacy.thing'), isNotNull);
    });

    testWidgets('keeps a Semantics that carries a label', (tester) async {
      final snapshot = await captureTree(
        tester,
        Semantics(
          label: 'Close dialog',
          child: const SizedBox(width: 10, height: 10),
        ),
      );

      final labels = _allLabels(snapshot.root);
      expect(labels, contains('Close dialog'));
    });

    testWidgets('drops inherited-widget scaffolding around content',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        Builder(
          builder: (context) => DefaultTextStyle(
            style: const TextStyle(fontSize: 12),
            child: const Text('deep', key: TestKey('deep')),
          ),
        ),
      );

      final types = _allTypes(snapshot.root);
      expect(types, isNot(contains('Builder')));
      expect(types, isNot(contains('DefaultTextStyle')));
      expect(snapshot.find('deep'), isNotNull);
    });

    testWidgets('collapses a child that merely repeats its parent',
        (tester) async {
      // Every Text builds a RichText with identical text and bounds.
      // Reporting both doubles the tree for no information.
      final snapshot = await captureTree(
        tester,
        const Text('Nike Air Max', key: TestKey('product.name')),
      );

      final node = snapshot.find('product.name')!;
      expect(node.text, 'Nike Air Max');
      expect(
        node.children.where((UiNode c) => c.type == 'RichText'),
        isEmpty,
        reason: 'RichText repeats the Text it belongs to',
      );
    });

    testWidgets('keeps a child that differs from its parent', (tester) async {
      final snapshot = await captureTree(
        tester,
        Center(
          child: FilledButton(
            key: const TestKey('cta'),
            onPressed: () {},
            child: const Text('Go'),
          ),
        ),
      );

      // The button's label text is genuinely a separate element.
      final texts = _allTexts(snapshot.root);
      expect(texts, contains('Go'));
    });

    testWidgets('a realistic screen stays within the node budget',
        (tester) async {
      // A stated budget, asserted, so the filter cannot quietly regress.
      final snapshot = await captureTree(
        tester,
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('Home')),
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Nike Air Max', key: TestKey('product.name')),
                  FilledButton(
                    key: const TestKey('cta'),
                    onPressed: () {},
                    child: const Text('View product'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(
        snapshot.retainedNodeCount,
        lessThan(20),
        reason: 'retained ${snapshot.retainedNodeCount} of '
            '${snapshot.totalElementsWalked}',
      );
      expect(snapshot.find('product.name'), isNotNull);
      expect(snapshot.find('cta'), isNotNull);
    });
  });
}

Set<String> _allLabels(UiNode node) => {
      ?node.label,
      for (final child in node.children) ..._allLabels(child),
    };

Set<String> _allTexts(UiNode node) => {
      ?node.text,
      for (final child in node.children) ..._allTexts(child),
    };

// ---------------------------------------------------------------------------
// Measured on the device: a BackButton reported `disabled` while the
// IconButton it wraps reported `enabled`. The falsehood came from the
// debugSemantics fallback, which reads the node an element contributed to
// rather than its own state. An unknown state must be reported as unknown.
// ---------------------------------------------------------------------------
class _WrapperAroundButton extends StatelessWidget {
  const _WrapperAroundButton({super.key});

  @override
  Widget build(BuildContext context) => FilledButton(
        key: const TestKey('inner'),
        onPressed: () {},
        child: const Text('Go'),
      );
}

void main3() {
  group('enabled is never guessed', () {
    testWidgets('a wrapper with no enabled state of its own reports null',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        const Center(child: _WrapperAroundButton(key: TestKey('wrapper'))),
      );

      // Not false. A rule acting on `enabled == false` must never fire
      // because of a widget that simply has no such notion.
      expect(snapshot.find('wrapper')?.enabled, isNull);
    });

    testWidgets('the button inside it still reports its real state',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        const Center(child: _WrapperAroundButton(key: TestKey('wrapper'))),
      );

      expect(snapshot.find('inner')!.enabled, isTrue);
    });

    testWidgets('a wrapper never contradicts the button it wraps',
        (tester) async {
      final snapshot = await captureTree(
        tester,
        const Center(child: _WrapperAroundButton(key: TestKey('wrapper'))),
      );

      final wrapper = snapshot.find('wrapper')!;
      final inner = snapshot.find('inner')!;

      expect(
        wrapper.enabled == false && inner.enabled == true,
        isFalse,
        reason: 'a wrapper reported disabled around an enabled button',
      );
    });
  });
}

/// Added in Phase 12, after the UI state matrix found the gap: a
/// disabled list row reported `enabled: null` - "no such notion" - so a
/// rule asserting `enabled: false` on a correctly disabled row failed.
void main4() {
  group('enabled on a list row', () {
    testWidgets('a disabled ListTile reports false', (tester) async {
      final snapshot = await captureTree(
        tester,
        Material(
          child: ListTile(
            key: const TestKey('row'),
            enabled: false,
            onTap: () {},
            title: const Text('Sold out'),
          ),
        ),
      );

      expect(snapshot.find('row')?.enabled, isFalse);
    });

    testWidgets('an enabled ListTile reports true', (tester) async {
      final snapshot = await captureTree(
        tester,
        Material(
          child: ListTile(
            key: const TestKey('row'),
            onTap: () {},
            title: const Text('In stock'),
          ),
        ),
      );

      expect(snapshot.find('row')?.enabled, isTrue);
    });
  });
}
