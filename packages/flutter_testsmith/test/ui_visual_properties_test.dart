import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// Opacity, corner radius and fill, read for design comparison.
///
/// One rule governs every test here: **the property is read from the
/// render object the test id identifies, and from nowhere else.** No
/// descendant search, no widget-type special case, no inference. Where
/// the identified render object does not carry the property, none is
/// reported and the comparison that wanted it says so rather than
/// guessing.
///
/// The alternative - "find the nearest Container and read its
/// decoration" - is how a tool starts reporting a colour from a widget
/// the author never named, and there is no way to tell from the report
/// that it happened.
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
  group('opacity', () {
    testWidgets('is reported from the identified render object', (
      tester,
    ) async {
      final snapshot = await _capture(
        tester,
        const Opacity(
          opacity: 0.2,
          key: TestKey('login.background'),
          child: SizedBox(width: 100, height: 100),
        ),
      );

      expect(snapshot.find('login.background')!.properties['opacity'], 0.2);
    });

    testWidgets('is absent when the identified render object has none', (
      tester,
    ) async {
      final snapshot = await _capture(
        tester,
        const SizedBox(
          key: TestKey('plain.box'),
          width: 100,
          height: 100,
        ),
      );

      expect(
        snapshot.find('plain.box')!.properties.containsKey('opacity'),
        isFalse,
      );
    });

    testWidgets('is reported from an animated opacity', (tester) async {
      final snapshot = await _capture(
        tester,
        const AnimatedOpacity(
          key: TestKey('fading'),
          opacity: 0.5,
          duration: Duration(milliseconds: 1),
          child: SizedBox(width: 100, height: 100),
        ),
      );

      expect(snapshot.find('fading')!.properties['opacity'], 0.5);
    });

    testWidgets('is not searched for in a descendant', (tester) async {
      // The test id names the outer box; the Opacity is below it. A
      // descendant search would report 0.2 here, which would be a
      // property of a widget nobody named.
      final snapshot = await _capture(
        tester,
        const SizedBox(
          key: TestKey('outer'),
          width: 100,
          height: 100,
          child: Opacity(
            opacity: 0.2,
            child: SizedBox(width: 50, height: 50),
          ),
        ),
      );

      expect(
        snapshot.find('outer')!.properties.containsKey('opacity'),
        isFalse,
      );
    });
  });

  group('fill', () {
    testWidgets('is reported from a decorated render object', (tester) async {
      final snapshot = await _capture(
        tester,
        const DecoratedBox(
          key: TestKey('login.card'),
          decoration: BoxDecoration(color: Color(0xFFC2185B)),
          child: SizedBox(width: 100, height: 100),
        ),
      );

      expect(snapshot.find('login.card')!.properties['fill'], '#c2185bff');
    });

    testWidgets('is not reported for a sized Container, because the id '
        'resolves to its constraint box', (tester) async {
      // Measured, not assumed. `Container(width:, height:, decoration:)`
      // builds a `ConstrainedBox` *around* a `DecoratedBox`, so the
      // element the test id names has a `RenderConstrainedBox` and the
      // decoration sits one level below it.
      //
      // Reaching down for it is precisely the descendant search this
      // inspector refuses to do, so the honest answer is no fill. The
      // fix is in the application: put the test id on the `DecoratedBox`
      // or drop the explicit size.
      final snapshot = await _capture(
        tester,
        Container(
          key: const TestKey('boxed'),
          width: 100,
          height: 100,
          decoration: const BoxDecoration(color: Color(0xFFC2185B)),
        ),
      );

      expect(
        snapshot.find('boxed')!.properties.containsKey('fill'),
        isFalse,
      );
    });

    testWidgets('carries alpha in the same form the Figma normaliser emits', (
      tester,
    ) async {
      final snapshot = await _capture(
        tester,
        const DecoratedBox(
          key: TestKey('scrim'),
          decoration: BoxDecoration(color: Color(0x800B6E4F)),
          child: SizedBox(width: 100, height: 100),
        ),
      );

      expect(snapshot.find('scrim')!.properties['fill'], '#0b6e4f80');
    });

    testWidgets('is not reported for a ColoredBox, and that is deliberate', (
      tester,
    ) async {
      // `ColoredBox` builds `_RenderColoredBox`, which is private and
      // publishes no colour - not as a field, not through diagnostics.
      // Reading it would mean reaching for `element.widget` and
      // special-casing a widget type, which is exactly the inference
      // this inspector refuses to make. `Container(color:)` builds a
      // `ColoredBox` too, so this is a real gap rather than a corner
      // case: the comparison that wants a fill here says it could not
      // read one, and the fix is a `DecoratedBox` in the application.
      final snapshot = await _capture(
        tester,
        const ColoredBox(
          key: TestKey('banner'),
          color: Color(0xFF0B6E4F),
          child: SizedBox(width: 100, height: 100),
        ),
      );

      expect(
        snapshot.find('banner')!.properties.containsKey('fill'),
        isFalse,
      );
    });

    testWidgets('is absent when the identified render object paints none', (
      tester,
    ) async {
      final snapshot = await _capture(
        tester,
        const SizedBox(key: TestKey('empty'), width: 10, height: 10),
      );

      expect(
        snapshot.find('empty')!.properties.containsKey('fill'),
        isFalse,
      );
    });
  });

  group('corner radius', () {
    testWidgets('is reported when every corner is the same', (tester) async {
      final snapshot = await _capture(
        tester,
        DecoratedBox(
          key: const TestKey('login.button'),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const SizedBox(width: 100, height: 48),
        ),
      );

      expect(snapshot.find('login.button')!.properties['cornerRadius'], 12.0);
    });

    testWidgets('is absent when the corners differ', (tester) async {
      // Figma reports a single `cornerRadius` only for a uniform
      // rounding; a sheet rounded at the top alone has no one number,
      // and inventing one would compare against nothing.
      final snapshot = await _capture(
        tester,
        const DecoratedBox(
          key: TestKey('sheet'),
          decoration: BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SizedBox(width: 100, height: 48),
        ),
      );

      expect(
        snapshot.find('sheet')!.properties.containsKey('cornerRadius'),
        isFalse,
      );
    });

    testWidgets('is absent on an undecorated element', (tester) async {
      final snapshot = await _capture(
        tester,
        const SizedBox(key: TestKey('bare'), width: 10, height: 10),
      );

      expect(
        snapshot.find('bare')!.properties.containsKey('cornerRadius'),
        isFalse,
      );
    });
  });

  group('the no-heuristics rule', () {
    testWidgets('reports nothing extra for a Card, Button or Material', (
      tester,
    ) async {
      // These are exactly the widgets a heuristic would special-case.
      // The inspector has no knowledge of them: whatever render object
      // the test id resolves to is what gets read, and a Card's is a
      // plain box.
      final snapshot = await _capture(
        tester,
        const Card(
          key: TestKey('offer.card'),
          child: SizedBox(width: 100, height: 100),
        ),
      );

      final properties = snapshot.find('offer.card')!.properties;

      expect(properties.containsKey('fill'), isFalse);
      expect(properties.containsKey('cornerRadius'), isFalse);
    });
  });
}
