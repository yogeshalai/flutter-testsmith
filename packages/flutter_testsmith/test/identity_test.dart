import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  group('TestKey', () {
    test('is a Key, so it can be given to any widget', () {
      expect(const TestKey('product.name'), isA<Key>());
    });

    test('compares equal for the same id', () {
      expect(const TestKey('product.name'), const TestKey('product.name'));
      expect(
        const TestKey('product.name').hashCode,
        const TestKey('product.name').hashCode,
      );
    });

    test('compares unequal for a different id', () {
      expect(
        const TestKey('product.name'),
        isNot(const TestKey('product.price')),
      );
    });

    test('does not collide with a plain ValueKey of the same string', () {
      // Otherwise an application's own ValueKey('product.name') would be
      // silently picked up as a test id.
      expect(
        const TestKey('product.name'),
        isNot(const ValueKey<String>('product.name')),
      );
    });

    testWidgets('can be attached to an ordinary widget', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Text('Nike Air Max', key: TestKey('product.name')),
        ),
      );

      expect(find.byKey(const TestKey('product.name')), findsOneWidget);
    });
  });

  group('resolveTestId', () {
    testWidgets('reads the id from a TestKey', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Text('x', key: TestKey('product.name'))),
      );

      final element = tester.element(find.text('x'));

      expect(resolveTestId(element), 'product.name');
    });

    testWidgets('reads the id from an enclosing TestId', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TestId(id: 'product.card', child: Text('x')),
        ),
      );

      final element = tester.element(find.byType(TestId));

      expect(resolveTestId(element), 'product.card');
    });

    testWidgets('prefers a TestKey over an enclosing TestId', (tester) async {
      // Tier 1 beats tier 2, so an element can never resolve ambiguously.
      await tester.pumpWidget(
        const MaterialApp(
          home: TestId(
            id: 'outer',
            child: Text('x', key: TestKey('inner')),
          ),
        ),
      );

      expect(resolveTestId(tester.element(find.text('x'))), 'inner');
    });

    testWidgets('falls back to a Semantics identifier', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Semantics(
            // Keyed so the finder targets this widget rather than one of
            // the many Semantics nodes MaterialApp creates internally.
            key: const ValueKey<String>('sem'),
            identifier: 'product.legacy',
            child: const Text('x'),
          ),
        ),
      );

      final element = tester.element(find.byKey(const ValueKey<String>('sem')));

      expect(resolveTestId(element), 'product.legacy');
    });

    testWidgets('returns null for an unmarked widget', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));

      expect(resolveTestId(tester.element(find.text('x'))), isNull);
    });
  });

  group('TestId', () {
    testWidgets('renders its child unchanged', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TestId(id: 'wrapper', child: Text('hello')),
        ),
      );

      expect(find.text('hello'), findsOneWidget);
    });

    test('rejects an empty id', () {
      expect(
        () => TestId(id: '', child: const SizedBox()),
        throwsAssertionError,
      );
    });
  });
}
