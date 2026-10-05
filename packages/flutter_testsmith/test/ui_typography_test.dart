import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

Future<UiSnapshot> _capture(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    ),
  );
  await tester.pumpAndSettle();

  return const UiTreeInspector().capture(
    root: tester.binding.rootElement!,
    screenId: 'TestScreen',
    devicePixelRatio: 1.875,
  );
}

void main() {
  group('text style capture', () {
    testWidgets('reports the size, weight, family and colour a text '
        'element painted with', (tester) async {
      final snapshot = await _capture(
        tester,
        const Text(
          'Nike Air Max',
          key: TestKey('product.name'),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            fontFamily: 'Inter',
            color: Color(0xFF1A1A1A),
          ),
        ),
      );

      final node = snapshot.find('product.name')!;

      expect(node.properties['fontSize'], 20.0);
      expect(node.properties['fontWeight'], 600);
      expect(node.properties['fontFamily'], 'Inter');
      expect(node.properties['color'], '#1a1a1aff');
    });

    testWidgets('reports the resolved style, not the declared one', (
      tester,
    ) async {
      // The Text declares nothing; everything comes from the ambient
      // DefaultTextStyle. A design comparison needs what was painted.
      final snapshot = await _capture(
        tester,
        const DefaultTextStyle(
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Color(0xFF112233),
          ),
          child: Text('Inherited', key: TestKey('product.name')),
        ),
      );

      final node = snapshot.find('product.name')!;

      expect(node.properties['fontSize'], 22.0);
      expect(node.properties['fontWeight'], 700);
      expect(node.properties['color'], '#112233ff');
    });

    testWidgets('carries alpha through, so a faded element is not read as '
        'a colour mismatch', (tester) async {
      final snapshot = await _capture(
        tester,
        const Text(
          'Faded',
          key: TestKey('product.note'),
          style: TextStyle(color: Color(0x801A1A1A)),
        ),
      );

      expect(snapshot.find('product.note')!.properties['color'], '#1a1a1a80');
    });

    testWidgets('adds nothing to a widget that paints no text', (
      tester,
    ) async {
      final snapshot = await _capture(
        tester,
        Container(key: const TestKey('product.spacer'), width: 10, height: 10),
      );

      expect(snapshot.find('product.spacer')!.properties, isEmpty);
    });
  });
}
