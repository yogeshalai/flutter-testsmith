import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Two photographs, not one taken on trust.
///
/// The failure this rule exists for was measured, not imagined: on a
/// real dashboard `awaitQuiescence` reported a quiet screen and the
/// picture still caught the outlet images part-way through their
/// fade-in - 44% different from a baseline of the same screen fully
/// painted, in 7 runs out of 8. A quiet period cannot close that gap,
/// because more than 500ms can pass between one network image arriving
/// and the next.
///
/// Proven here rather than on a device, and that is a deliberate choice
/// with a reason attached. Reproducing it on hardware now requires
/// arranging a screen that changes while *no* ticker runs and *no*
/// request is in flight - and the platform's own in-flight tracking has
/// since closed the case that used to produce it. An attempt with an
/// API fixture that delayed the outlet pictures by 1.5s to 7.5s
/// (`dashboard_late_images`) did not reproduce: `waitForSettle` waited
/// for those requests and the screen was fully painted before the
/// shutter. That is the system working, and it is also why the rule
/// itself has to be exercised here, where the captures can be dictated.

/// A flat image of one colour.
Uint8List flat(int width, int height, int hex) {
  final image = img.Image(width: width, height: height);
  img.fill(
    image,
    color: img.ColorRgb8((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF),
  );
  return Uint8List.fromList(img.encodePng(image));
}

/// A flat image with one rectangle painted over it.
Uint8List withBlock(
  int width,
  int height, {
  int background = 0xFFFFFF,
  required int colour,
  required int x,
  required int y,
  required int w,
  required int h,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(
    image,
    color: img.ColorRgb8(
      (background >> 16) & 0xFF,
      (background >> 8) & 0xFF,
      background & 0xFF,
    ),
  );
  img.fillRect(
    image,
    x1: x,
    y1: y,
    x2: x + w - 1,
    y2: y + h - 1,
    color: img.ColorRgb8(
      (colour >> 16) & 0xFF,
      (colour >> 8) & 0xFF,
      colour & 0xFF,
    ),
  );
  return Uint8List.fromList(img.encodePng(image));
}

/// Hands back a fixed sequence of pictures, one per call.
({Future<Uint8List> Function() capture, int Function() calls}) sequence(
  List<Uint8List> frames,
) {
  var index = 0;
  return (
    capture: () async => frames[index++ < frames.length ? index - 1 : frames.length - 1],
    calls: () => index,
  );
}

const VisualTolerances strict = VisualTolerances(maxDifferingRatio: 0.002);

void main() {
  group('a screen that is holding still', () {
    test('is photographed and the picture returned', () async {
      final still = flat(200, 200, 0xFFFFFF);
      final camera = sequence([still, still, still]);

      final taken = await const SteadyCapture().take(
        capture: camera.capture,
        tolerances: strict,
      );

      expect(taken, isNotNull);
      // Two photographs, not one: the second is what proves the first.
      expect(camera.calls(), 2);
    });
  });

  group('a screen that is still assembling itself', () {
    test('is photographed again until it converges', () async {
      // One image arriving, then the next - the real sequence, where the
      // screen is different each time for a while and then stops being.
      final first = flat(200, 200, 0xFFFFFF);
      final second = withBlock(200, 200,
          colour: 0x3366CC, x: 0, y: 0, w: 200, h: 60);
      final settled = withBlock(200, 200,
          colour: 0x3366CC, x: 0, y: 0, w: 200, h: 120);
      final camera = sequence([first, second, settled, settled, settled]);

      final taken = await const SteadyCapture().take(
        capture: camera.capture,
        tolerances: strict,
      );

      expect(taken, isNotNull);
      expect(taken, settled);
    });
  });

  group('a screen that never holds still', () {
    test('produces no picture at all, rather than whichever frame it '
        'caught', () async {
      // The whole point. Returning one of these would record a baseline
      // of a half-painted screen, and every later run would be compared
      // against it.
      final a = flat(200, 200, 0xFFFFFF);
      final b = flat(200, 200, 0x000000);
      final camera = sequence([a, b, a, b, a, b, a, b]);

      final taken = await const SteadyCapture().take(
        capture: camera.capture,
        tolerances: strict,
      );

      expect(taken, isNull);
    });

    test('gives up after the declared number of attempts', () async {
      final a = flat(120, 120, 0xFFFFFF);
      final b = flat(120, 120, 0x000000);
      final camera = sequence([a, b, a, b, a, b, a, b, a, b]);

      await const SteadyCapture(attempts: 3).take(
        capture: camera.capture,
        tolerances: strict,
      );

      // One to open with, then one per attempt.
      expect(camera.calls(), 4);
    });

    test('a size that changes is a disagreement, not a comparison', () async {
      // A rotation mid-capture. Comparing pixel counts across two
      // different geometries produces a number, and the number is
      // meaningless.
      final portrait = flat(120, 240, 0xFFFFFF);
      final landscape = flat(240, 120, 0xFFFFFF);
      final camera = sequence([portrait, landscape, portrait, landscape]);

      expect(
        await const SteadyCapture().take(
          capture: camera.capture,
          tolerances: strict,
        ),
        isNull,
      );
    });
  });

  group('what the rule is allowed to ignore', () {
    test('a region under an ignore rectangle does not prevent agreement',
        () async {
      // The clock in the status bar, and every permitted animation. A
      // screen must not be called unsteady for the things already
      // excused - otherwise declaring a perpetual animation would make
      // the picture impossible to take at all.
      final one = withBlock(200, 200,
          colour: 0x111111, x: 0, y: 0, w: 200, h: 40);
      final two = withBlock(200, 200,
          colour: 0xEEEEEE, x: 0, y: 0, w: 200, h: 40);
      final camera = sequence([one, two, one, two]);

      final taken = await const SteadyCapture().take(
        capture: camera.capture,
        tolerances: strict,
        ignore: const [
          PixelRegion(label: 'status bar', x: 0, y: 0, width: 200, height: 40),
        ],
      );

      expect(taken, isNotNull);
    });

    test('a change outside the ignored region still prevents agreement',
        () async {
      final one = withBlock(200, 200,
          colour: 0x111111, x: 0, y: 100, w: 200, h: 60);
      final two = withBlock(200, 200,
          colour: 0xEEEEEE, x: 0, y: 100, w: 200, h: 60);
      final camera = sequence([one, two, one, two, one, two, one, two]);

      expect(
        await const SteadyCapture().take(
          capture: camera.capture,
          tolerances: strict,
          ignore: const [
            PixelRegion(
                label: 'status bar', x: 0, y: 0, width: 200, height: 40),
          ],
        ),
        isNull,
      );
    });
  });
}
