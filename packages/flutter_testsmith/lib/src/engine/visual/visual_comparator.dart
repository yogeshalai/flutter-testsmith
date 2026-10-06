import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'visual_comparison.dart';
import 'visual_tolerances.dart';

/// Compares two screenshots deterministically.
///
/// Deterministic first, and only deterministic: this produces numbers,
/// not opinions. A vision model may later be asked to *explain* a
/// difference these metrics have already found, but it is never asked
/// whether there is one - see the governing principle in ARCHITECTURE.
///
/// Decoding and diffing run on a background isolate. A 1080x2400 PNG is
/// ~2.6M pixels, and doing that on the main isolate would stall the
/// event loop the VM Service connection lives on, which is how a runner
/// comes to look hung mid-run.
class VisualComparator {
  const VisualComparator({this.tolerances = VisualTolerances.defaults});

  final VisualTolerances tolerances;

  Future<VisualComparison> compare({
    required Uint8List baseline,
    required Uint8List current,
    List<PixelRegion> ignore = const [],
    List<PixelRegion> regions = const [],
  }) {
    final request = _CompareRequest(
      baseline: baseline,
      current: current,
      ignore: ignore,
      regions: regions,
      tolerances: tolerances,
    );

    return Isolate.run(() => _compareSync(request));
  }

  /// The comparison itself, running on the background isolate.
  static VisualComparison _compareSync(_CompareRequest request) {
    final baseline = img.decodeImage(request.baseline);
    final current = img.decodeImage(request.current);

    if (baseline == null || current == null) {
      final which = baseline == null ? 'baseline' : 'current';
      throw FormatException('the $which screenshot is not a decodable image');
    }

    if (baseline.width != current.width ||
        baseline.height != current.height) {
      final summary = 'the screenshots are different sizes: baseline is '
          '${baseline.width}x${baseline.height}, this run captured '
          '${current.width}x${current.height}. Nothing was compared.';
      return VisualComparison(
        overall: RegionComparison(
          label: 'screen',
          differingPixels: 0,
          totalPixels: 0,
          maxChannelDelta: 0,
          ssim: 0,
        ),
        passed: false,
        sizeMismatch: true,
        summary: summary,
        ignored: request.ignore,
      );
    }

    final tolerances = request.tolerances;

    // One luminance plane per image, reused by every SSIM window
    // instead of being recomputed per region.
    final width = baseline.width;
    final height = baseline.height;
    final ignored = _ignoreMask(width, height, request.ignore);

    final overall = _measure(
      label: 'screen',
      baseline: baseline,
      current: current,
      bounds: PixelRegion(
        label: 'screen',
        x: 0,
        y: 0,
        width: width,
        height: height,
      ),
      ignored: ignored,
      tolerances: tolerances,
    );

    final measured = [
      for (final region in request.regions)
        _measure(
          label: region.label,
          baseline: baseline,
          current: current,
          bounds: region,
          ignored: ignored,
          tolerances: tolerances,
        ),
    ];

    final failures = <String>[];
    if (overall.differingRatio > tolerances.maxDifferingRatio) {
      failures.add(
        '${_percent(overall.differingRatio)} of pixels differ '
        '(tolerance ${_percent(tolerances.maxDifferingRatio)})',
      );
    }
    if (overall.ssim < tolerances.minSsim) {
      failures.add(
        'structural similarity ${overall.ssim.toStringAsFixed(4)} is below '
        '${tolerances.minSsim}',
      );
    }
    // Each element is judged against its own area, not the screen's.
    for (final region in measured) {
      if (region.outsideImage) continue;
      if (region.differingRatio > tolerances.maxElementDifferingRatio) {
        failures.add(
          '"${region.label}" differs by ${_percent(region.differingRatio)} '
          'of its own area (tolerance '
          '${_percent(tolerances.maxElementDifferingRatio)})',
        );
      }
    }

    // An element wholly off-screen is NOT a failure. On a scrolling
    // page most of the content is below the fold, and failing for that
    // fails identically on every run - the definition of a false
    // positive. Whether an element ought to exist is a structural
    // question, answered by the UI and Figma checks; this one compares
    // the pixels that are in the image. Had such an element moved
    // off-screen from a position it used to occupy, the pixels it
    // vacated would change and the ratio gate would catch that.
    final offScreen = [
      for (final region in measured)
        if (region.outsideImage) region.label,
    ];

    final notCompared = offScreen.isEmpty
        ? ''
        : '; ${offScreen.length} element(s) off-screen and not compared '
            '(${offScreen.take(5).join(', ')})';

    final summary = failures.isEmpty
        ? 'matches the baseline: ${_percent(overall.differingRatio)} of '
            '${overall.totalPixels} pixels differ, ssim '
            '${overall.ssim.toStringAsFixed(4)}$notCompared'
        : '${failures.join('; ')}$notCompared';

    return VisualComparison(
      overall: overall,
      regions: measured,
      ignored: request.ignore,
      passed: failures.isEmpty,
      summary: summary,
    );
  }

  /// Pixels excluded from every measurement.
  ///
  /// A flat bitmap rather than a per-pixel walk of the region list: a
  /// screenshot has millions of pixels and the list is checked for
  /// every one of them.
  ///
  /// A **negative** y is measured from the bottom of the image, which is
  /// how a system navigation bar has to be expressed: it is anchored to
  /// the foot of the screen, and writing its absolute y would tie the
  /// configuration to one device's height. Phase 12 measured the cost of
  /// not having this: the navigation bar contributed a constant 723
  /// pixels - 0.065%, a third of the default whole-screen budget - to
  /// every single comparison on the SM-M127G.
  static Uint8List _ignoreMask(
    int width,
    int height,
    List<PixelRegion> regions,
  ) {
    final mask = Uint8List(width * height);
    for (final region in regions) {
      final resolvedY = region.y < 0 ? height + region.y : region.y;
      final left = region.x.clamp(0, width);
      final top = resolvedY.clamp(0, height);
      final right = region.right.clamp(0, width);
      final bottom = (resolvedY + region.height).clamp(0, height);
      for (var y = top; y < bottom; y++) {
        mask.fillRange(y * width + left, y * width + right, 1);
      }
    }
    return mask;
  }

  static RegionComparison _measure({
    required String label,
    required img.Image baseline,
    required img.Image current,
    required PixelRegion bounds,
    required Uint8List ignored,
    required VisualTolerances tolerances,
  }) {
    final width = baseline.width;
    final height = baseline.height;

    final left = bounds.x.clamp(0, width);
    final top = bounds.y.clamp(0, height);
    final right = bounds.right.clamp(0, width);
    final bottom = bounds.bottom.clamp(0, height);

    if (left >= right || top >= bottom) {
      return RegionComparison(
        label: label,
        differingPixels: 0,
        totalPixels: 0,
        maxChannelDelta: 0,
        ssim: 0,
        outsideImage: true,
      );
    }

    var differing = 0;
    var compared = 0;
    var maxDelta = 0;

    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        if (ignored[y * width + x] == 1) continue;
        compared++;

        final a = baseline.getPixel(x, y);
        final b = current.getPixel(x, y);

        final delta = [
          (a.r - b.r).abs(),
          (a.g - b.g).abs(),
          (a.b - b.b).abs(),
          (a.a - b.a).abs(),
        ].reduce((p, q) => p > q ? p : q).round();

        if (delta > maxDelta) maxDelta = delta;
        if (delta > tolerances.channelDelta) differing++;
      }
    }

    return RegionComparison(
      label: label,
      differingPixels: differing,
      totalPixels: compared,
      maxChannelDelta: maxDelta,
      ssim: _ssim(
        baseline: baseline,
        current: current,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        ignored: ignored,
        imageWidth: width,
      ),
    );
  }

  /// Mean structural similarity over 8x8 windows.
  ///
  /// Computed on luminance, which is what SSIM is defined over and what
  /// makes it insensitive to the uniform brightness shifts that a
  /// different GPU or a different capture path introduces.
  ///
  /// A window overlapping an ignore region is dropped whole rather than
  /// partially measured: SSIM is a statistic over a neighbourhood, and
  /// a neighbourhood with holes in it is not the same statistic.
  static double _ssim({
    required img.Image baseline,
    required img.Image current,
    required int left,
    required int top,
    required int right,
    required int bottom,
    required Uint8List ignored,
    required int imageWidth,
  }) {
    const window = 8;
    // The standard stabilisers, for an 8-bit dynamic range.
    const c1 = 6.5025; // (0.01 * 255)^2
    const c2 = 58.5225; // (0.03 * 255)^2

    var total = 0.0;
    var windows = 0;

    for (var wy = top; wy + window <= bottom; wy += window) {
      for (var wx = left; wx + window <= right; wx += window) {
        var sumA = 0.0;
        var sumB = 0.0;
        var sumAA = 0.0;
        var sumBB = 0.0;
        var sumAB = 0.0;
        var count = 0;
        var skip = false;

        for (var y = wy; y < wy + window && !skip; y++) {
          for (var x = wx; x < wx + window; x++) {
            if (ignored[y * imageWidth + x] == 1) {
              skip = true;
              break;
            }
            final a = _luminance(baseline.getPixel(x, y));
            final b = _luminance(current.getPixel(x, y));
            sumA += a;
            sumB += b;
            sumAA += a * a;
            sumBB += b * b;
            sumAB += a * b;
            count++;
          }
        }
        if (skip || count == 0) continue;

        final meanA = sumA / count;
        final meanB = sumB / count;
        final varA = sumAA / count - meanA * meanA;
        final varB = sumBB / count - meanB * meanB;
        final covAB = sumAB / count - meanA * meanB;

        final numerator =
            (2 * meanA * meanB + c1) * (2 * covAB + c2);
        final denominator =
            (meanA * meanA + meanB * meanB + c1) * (varA + varB + c2);

        total += denominator == 0 ? 1.0 : numerator / denominator;
        windows++;
      }
    }

    if (windows == 0) return 1;
    // Clamped: floating point can put a perfect match a hair over 1.
    return (total / windows).clamp(0.0, 1.0);
  }

  static double _luminance(img.Pixel pixel) =>
      0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;

  static String _percent(double ratio) =>
      '${(ratio * 100).toStringAsFixed(3)}%';
}

/// Everything the isolate needs, in one sendable object.
class _CompareRequest {
  const _CompareRequest({
    required this.baseline,
    required this.current,
    required this.ignore,
    required this.regions,
    required this.tolerances,
  });

  final Uint8List baseline;
  final Uint8List current;
  final List<PixelRegion> ignore;
  final List<PixelRegion> regions;
  final VisualTolerances tolerances;
}
