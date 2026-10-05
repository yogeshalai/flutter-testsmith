import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// A flat image, optionally with one rectangle painted over it.
Uint8List _png(
  int width,
  int height, {
  int background = 0xFFFFFF,
  int? blockColour,
  int blockX = 0,
  int blockY = 0,
  int blockWidth = 0,
  int blockHeight = 0,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: _rgb(image, background));

  if (blockColour != null) {
    img.fillRect(
      image,
      x1: blockX,
      y1: blockY,
      x2: blockX + blockWidth - 1,
      y2: blockY + blockHeight - 1,
      color: _rgb(image, blockColour),
    );
  }
  return Uint8List.fromList(img.encodePng(image));
}

img.Color _rgb(img.Image image, int hex) => img.ColorRgb8(
      (hex >> 16) & 0xFF,
      (hex >> 8) & 0xFF,
      hex & 0xFF,
    );

/// Every pixel nudged by [delta], as antialiasing or a GPU would.
Uint8List _nudged(int width, int height, int delta) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255 - delta, 255 - delta, 255 - delta));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  const comparator = VisualComparator();

  group('identical images', () {
    test('report no difference at all', () async {
      final image = _png(64, 64);

      final result = await comparator.compare(
        baseline: image,
        current: _png(64, 64),
      );

      expect(result.overall.differingPixels, 0);
      expect(result.overall.differingRatio, 0);
      expect(result.overall.ssim, 1.0);
      expect(result.passed, isTrue);
      expect(image, isNotEmpty);
    });

    test('are stable across repeated comparisons', () async {
      // The exit criterion is a false-positive rate, so determinism is
      // the property under test, not an implementation detail.
      final results = <double>[];
      for (var run = 0; run < 5; run++) {
        final result = await comparator.compare(
          baseline: _png(80, 60, blockColour: 0x3366CC, blockWidth: 20,
              blockHeight: 20, blockX: 10, blockY: 10),
          current: _png(80, 60, blockColour: 0x3366CC, blockWidth: 20,
              blockHeight: 20, blockX: 10, blockY: 10),
        );
        results.add(result.overall.differingRatio);
      }

      expect(results, everyElement(0));
    });
  });

  group('differences', () {
    test('a changed block is counted and located', () async {
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(
          100,
          100,
          blockColour: 0xFF0000,
          blockX: 10,
          blockY: 10,
          blockWidth: 20,
          blockHeight: 20,
        ),
      );

      expect(result.overall.differingPixels, 400);
      expect(result.overall.differingRatio, closeTo(0.04, 0.0001));
      expect(result.passed, isFalse);
    });

    test('one stray pixel does not fail a screen', () async {
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(
          100,
          100,
          blockColour: 0xFF0000,
          blockWidth: 1,
          blockHeight: 1,
        ),
      );

      expect(result.overall.differingPixels, 1);
      expect(result.passed, isTrue);
    });

    test('mean ssim is size-sensitive, which is why it is not the primary '
        'gate', () async {
      // The same single changed pixel, on two image sizes. On the small
      // one it costs 144x more, because the mean is over far fewer
      // windows. A threshold tuned on one would be wrong on the other.
      Future<double> ssimForOnePixelOn(int side) async {
        final result = await comparator.compare(
          baseline: _png(side, side),
          current: _png(side, side, blockColour: 0xFF0000, blockWidth: 1,
              blockHeight: 1),
        );
        return result.overall.ssim;
      }

      final small = await ssimForOnePixelOn(64);
      final large = await ssimForOnePixelOn(512);

      expect(small, lessThan(large));
      expect(1 - large, lessThan((1 - small) / 10));
    });

    test('a nudge below the channel threshold is not a difference', () async {
      // Antialiasing and GPU rounding move channels by a little
      // everywhere. Counting that as change is what makes people turn
      // visual checks off.
      final result = await comparator.compare(
        baseline: _png(64, 64),
        current: _nudged(64, 64, 4),
      );

      expect(result.overall.differingPixels, 0);
      expect(result.passed, isTrue);
    });

    test('a shift above the channel threshold is a difference', () async {
      final result = await comparator.compare(
        baseline: _png(64, 64),
        current: _nudged(64, 64, 40),
      );

      expect(result.overall.differingPixels, 64 * 64);
      expect(result.passed, isFalse);
    });

    test('the channel threshold is configurable', () async {
      const strict = VisualComparator(
        tolerances: VisualTolerances(channelDelta: 1),
      );

      final result = await strict.compare(
        baseline: _png(64, 64),
        current: _nudged(64, 64, 4),
      );

      expect(result.overall.differingPixels, 64 * 64);
    });
  });

  group('dimensions', () {
    test('a size change is reported as such, not as a pixel diff', () async {
      // Comparing a 1080-wide baseline with a 720-wide capture pixel by
      // pixel produces a meaningless number. The size change IS the
      // finding.
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(100, 120),
      );

      expect(result.passed, isFalse);
      expect(result.sizeMismatch, isTrue);
      expect(result.summary, contains('100x100'));
      expect(result.summary, contains('100x120'));
    });
  });

  group('ignore regions', () {
    test('exclude their pixels from the comparison', () async {
      // The clock in a status bar changes every minute and is not a
      // regression.
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(
          100,
          100,
          blockColour: 0xFF0000,
          blockX: 0,
          blockY: 0,
          blockWidth: 100,
          blockHeight: 24,
        ),
        ignore: const [
          PixelRegion(label: 'status bar', x: 0, y: 0, width: 100, height: 24),
        ],
      );

      expect(result.overall.differingPixels, 0);
      expect(result.passed, isTrue);
    });

    test('do not hide a difference outside them', () async {
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(
          100,
          100,
          blockColour: 0xFF0000,
          blockX: 0,
          blockY: 50,
          blockWidth: 100,
          blockHeight: 20,
        ),
        ignore: const [
          PixelRegion(label: 'status bar', x: 0, y: 0, width: 100, height: 24),
        ],
      );

      expect(result.overall.differingPixels, 2000);
      expect(result.passed, isFalse);
    });

    test('shrink the denominator, so the ratio stays honest', () async {
      // 100x100 with a 100x50 ignore region leaves 5000 comparable
      // pixels; 500 changed is 10%, not 5%.
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(
          100,
          100,
          blockColour: 0xFF0000,
          blockX: 0,
          blockY: 50,
          blockWidth: 100,
          blockHeight: 5,
        ),
        ignore: const [
          PixelRegion(label: 'top half', x: 0, y: 0, width: 100, height: 50),
        ],
      );

      expect(result.overall.totalPixels, 5000);
      expect(result.overall.differingPixels, 500);
      expect(result.overall.differingRatio, closeTo(0.10, 0.0001));
    });
  });

  group('element regions', () {
    test('name which element changed', () async {
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(
          100,
          100,
          blockColour: 0xFF0000,
          blockX: 60,
          blockY: 60,
          blockWidth: 20,
          blockHeight: 20,
        ),
        regions: const [
          PixelRegion(label: 'product.name', x: 0, y: 0, width: 40, height: 40),
          PixelRegion(
            label: 'product.price',
            x: 60,
            y: 60,
            width: 20,
            height: 20,
          ),
        ],
      );

      final byLabel = {for (final r in result.regions) r.label: r};

      expect(byLabel['product.name']!.differingPixels, 0);
      expect(byLabel['product.price']!.differingPixels, 400);
      expect(byLabel['product.price']!.differingRatio, 1.0);
    });

    test('a small element changing fails, even though the screen barely '
        'moves', () async {
      // 24x24 changed on a 1000x1000 screen is 0.058% of the image -
      // well inside the whole-screen tolerance - but it is the entire
      // element. This is why element regions are measured separately.
      final result = await comparator.compare(
        baseline: _png(1000, 1000),
        current: _png(
          1000,
          1000,
          blockColour: 0xFF0000,
          blockX: 100,
          blockY: 100,
          blockWidth: 24,
          blockHeight: 24,
        ),
        regions: const [
          PixelRegion(label: 'product.price', x: 100, y: 100, width: 24,
              height: 24),
        ],
      );

      expect(result.overall.differingRatio, lessThan(0.002));
      expect(result.passed, isFalse);
      expect(result.summary, contains('product.price'));
    });

    test('a region outside the image is reported, not silently clipped '
        'to nothing', () async {
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(100, 100),
        regions: const [
          PixelRegion(label: 'offscreen', x: 200, y: 200, width: 10,
              height: 10),
        ],
      );

      final region = result.regions.single;
      expect(region.outsideImage, isTrue);
      expect(region.totalPixels, 0);
    });

    test('an off-screen element does not fail the screen, because most '
        'of a scrolling page is below the fold', () async {
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(100, 100),
        regions: const [
          PixelRegion(label: 'product.cart_total', x: 0, y: 900, width: 40,
              height: 20),
        ],
      );

      expect(result.passed, isTrue);
      expect(result.summary, contains('off-screen'));
      expect(result.summary, contains('product.cart_total'));
    });

    test('an element partly below the fold is compared on the part that '
        'is visible', () async {
      final result = await comparator.compare(
        baseline: _png(100, 100),
        current: _png(
          100,
          100,
          blockColour: 0xFF0000,
          blockX: 0,
          blockY: 90,
          blockWidth: 100,
          blockHeight: 10,
        ),
        regions: const [
          PixelRegion(label: 'product.footer', x: 0, y: 90, width: 100,
              height: 200),
        ],
      );

      final region = result.regions.single;
      expect(region.outsideImage, isFalse);
      expect(region.totalPixels, 1000);
      expect(region.differingPixels, 1000);
    });
  });

  group('ssim', () {
    test('is 1 for identical images', () async {
      final result = await comparator.compare(
        baseline: _png(64, 64, blockColour: 0x112233, blockWidth: 30,
            blockHeight: 30),
        current: _png(64, 64, blockColour: 0x112233, blockWidth: 30,
            blockHeight: 30),
      );

      expect(result.overall.ssim, 1.0);
    });

    test('falls when structure changes', () async {
      final result = await comparator.compare(
        baseline: _png(64, 64, blockColour: 0x000000, blockWidth: 32,
            blockHeight: 64),
        current: _png(64, 64, blockColour: 0x000000, blockX: 32,
            blockWidth: 32, blockHeight: 64),
      );

      expect(result.overall.ssim, lessThan(0.9));
      expect(result.passed, isFalse);
    });
  });
}
