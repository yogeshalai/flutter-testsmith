import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// The `repaintBoundary` capture path.
///
/// Added in Phase 12. The protocol has carried
/// `ScreenshotSource.repaintBoundary` since Phase 1 and nothing had ever
/// produced one: every screenshot came from `adb exec-out screencap`.
void main() {
  Future<SurfaceCapture> capture(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(200, 400),
    double ratio = 2,
  }) async {
    tester.view.physicalSize = size * ratio;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: child)),
    );
    await tester.pumpAndSettle();

    return (await tester.runAsync(captureSurface))!;
  }

  testWidgets('produces a PNG at the surface size in physical pixels',
      (tester) async {
    final image = await capture(tester, const Text('hello'));

    expect(image.width, 400);
    expect(image.height, 800);
    expect(image.devicePixelRatio, 2);

    // A real PNG, by its signature rather than by its extension.
    final bytes = base64Decode(image.pngBase64);
    expect(bytes.sublist(0, 8),
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(image.byteLength, bytes.length);
  });

  testWidgets('follows the device pixel ratio', (tester) async {
    final image = await capture(tester, const Text('hello'), ratio: 3);

    // Geometry is exactly logical size x ratio, with no OS scaling in
    // between - which is the property that makes this path worth having.
    expect(image.width, 600);
    expect(image.height, 1200);
    expect(image.devicePixelRatio, 3);
  });

  testWidgets('two captures of an unchanged screen are byte-identical',
      (tester) async {
    // The claim visual regression rests on. If this were not true, every
    // comparison would be measuring the capture path rather than the
    // application.
    final first = await capture(tester, const Text('stable'));
    final second = await (tester.runAsync(captureSurface));

    expect(second!.pngBase64, first.pngBase64);
  });

  testWidgets('a changed screen produces different bytes', (tester) async {
    final before = await capture(tester, const Text('before'));

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('after'))),
    );
    await tester.pumpAndSettle();
    final after = await tester.runAsync(captureSurface);

    expect(after!.pngBase64, isNot(before.pngBase64));
  });

  testWidgets('the JSON reply names the path that produced it',
      (tester) async {
    final image = await capture(tester, const Text('hello'));
    final json = image.toJson();

    // The engine refuses to diff a repaintBoundary image against a
    // screencap, and that refusal depends on this field being right.
    expect(json['source'], 'repaintBoundary');
    expect(json['width'], 400);
    expect(json['devicePixelRatio'], 2);
  });
}
