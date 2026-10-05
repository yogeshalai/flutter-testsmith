import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// The device's own safe-area inset, reported with the capture.
///
/// A design frame includes whatever status-bar area the designer drew;
/// the device has whatever inset it actually has. Comparing the two
/// without knowing either is how a correct layout gets reported as
/// misplaced by exactly the difference between them.
///
/// The inset is read from the view, not assumed. There is no universal
/// 24px status bar: this device reports one value, a notched phone
/// another, a tablet a third.
void main() {
  testWidgets('is reported from the view, not assumed', (tester) async {
    tester.view
      ..physicalSize = const Size(720, 1600)
      ..devicePixelRatio = 2
      ..padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.expand(),
      ),
    );

    final snapshot = const UiTreeInspector().capture(
      root: tester.binding.rootElement!,
      screenId: '/x',
      devicePixelRatio: 2,
    );

    // Logical pixels, as every other measurement in the snapshot is.
    expect(snapshot.safeArea!.top, 24);
    expect(snapshot.safeArea!.bottom, 16);
  });

  testWidgets('reports zero insets as zero, not as absent', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding();
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.expand(),
      ),
    );

    final snapshot = const UiTreeInspector().capture(
      root: tester.binding.rootElement!,
      screenId: '/x',
      devicePixelRatio: 1,
    );

    expect(snapshot.safeArea, isNotNull);
    expect(snapshot.safeArea!.top, 0);
  });

  test('survives the round trip through JSON', () {
    const insets = LogicalInsets(top: 24, bottom: 16);

    expect(LogicalInsets.fromJson(insets.toJson()), insets);
  });
}
