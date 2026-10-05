import 'dart:convert';
import 'dart:io';

import 'package:ecommerce_app/screens/checkout_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'harness.dart';

/// Prints the geometry of a screen at the design frame's width.
///
/// Not an assertion - a tool. Run it when authoring a design spec, so
/// the numbers in the spec come from a measurement rather than a guess.
void main() {
  testWidgets('dump checkout geometry', (tester) async {
    final snapshot = await screenTree(tester);

    final rows = <Map<String, Object?>>[];
    void walk(UiNode node) {
      if (node.testId != null) {
        rows.add({
          'id': node.testId,
          'type': node.type,
          'text': node.text,
          'x': node.bounds.x,
          'y': node.bounds.y,
          'w': node.bounds.width,
          'h': node.bounds.height,
          ...node.properties,
        });
      }
      node.children.forEach(walk);
    }

    walk(snapshot.root);
    rows.sort((a, b) => (a['y']! as double).compareTo(b['y']! as double));

    File('../../out/checkout-geometry.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'viewport': snapshot.viewport?.toJson(),
          'elements': rows,
        }),
      );
    // Not a vacuous test: the spec's frame width is 402, and a dump
    // taken at any other width would produce numbers nobody should
    // paste into a design file.
    expect(snapshot.viewport?.width, 402.0);
    expect(rows, isNotEmpty);
  });
}

Future<UiSnapshot> screenTree(WidgetTester tester) => pumpAndCaptureWith(
      tester,
      const CheckoutScreen(),
      screenId: '/checkout',
    );
