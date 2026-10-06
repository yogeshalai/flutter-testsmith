import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Phase 12: a system navigation bar is anchored to the foot of the
/// screen, so its ignore region has to be too.

Uint8List png(int width, int height, {required int Function(int, int) at}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final value = at(x, y);
      image.setPixelRgba(x, y, value, value, value, 255);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  const white = 255;
  const black = 0;

  final clean = png(40, 100, at: (x, y) => white);
  // Something changed only in the bottom eight rows - a navigation bar.
  final withBottomChange = png(40, 100, at: (x, y) => y >= 92 ? black : white);
  // And something changed only in the top eight rows - a status bar.
  final withTopChange = png(40, 100, at: (x, y) => y < 8 ? black : white);

  test('without an ignore region, the bottom change is measured', () async {
    final comparison = await const VisualComparator().compare(
      baseline: clean,
      current: withBottomChange,
    );

    expect(comparison.overall.differingPixels, 8 * 40);
  });

  test('a negative y ignores that many rows from the bottom', () async {
    final comparison = await const VisualComparator().compare(
      baseline: clean,
      current: withBottomChange,
      ignore: const [
        PixelRegion(label: 'navbar', x: 0, y: -8, width: 9999, height: 8),
      ],
    );

    expect(comparison.overall.differingPixels, 0);
    // And the ignored rows are not counted as compared either, so the
    // ratio is over what was actually looked at.
    expect(comparison.overall.totalPixels, 40 * 92);
  });

  test('a bottom region does not accidentally ignore the top', () async {
    // The bug this replaced: clamping a negative y to 0 would have
    // masked the status bar instead, silently disabling the check that
    // was asked for.
    final comparison = await const VisualComparator().compare(
      baseline: clean,
      current: withTopChange,
      ignore: const [
        PixelRegion(label: 'navbar', x: 0, y: -8, width: 9999, height: 8),
      ],
    );

    expect(comparison.overall.differingPixels, 8 * 40);
  });

  test('a positive y still means what it always did', () async {
    final comparison = await const VisualComparator().compare(
      baseline: clean,
      current: withTopChange,
      ignore: const [
        PixelRegion(label: 'statusbar', x: 0, y: 0, width: 9999, height: 8),
      ],
    );

    expect(comparison.overall.differingPixels, 0);
  });

  group('configuration', () {
    test('reads a negative y', () {
      final config = VisualCheckConfig.fromYaml(
        {
          'ignoreRegions': [
            {'x': 0, 'y': -32, 'width': 9999, 'height': 32},
          ],
        },
        source: 'x.yaml',
      );

      expect(config.ignoreRegions.single.y, -32);
    });

    test('refuses a negative width, which is a typo rather than an anchor',
        () {
      expect(
        () => VisualCheckConfig.fromYaml(
          {
            'ignoreRegions': [
              {'x': 0, 'y': 0, 'width': -10, 'height': 32},
            ],
          },
          source: 'x.yaml',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
