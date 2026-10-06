import 'package:meta/meta.dart';

/// A rectangle in **physical image pixels**.
///
/// Screenshots are physical; the UI tree is logical. Converting between
/// the two is the caller's job, using the device pixel ratio from the
/// same capture - see ADR-0006. Taking logical pixels here would invite
/// exactly the mistake that ratio exists to prevent.
@immutable
class PixelRegion {
  const PixelRegion({
    required this.label,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final String label;
  final int x;
  final int y;
  final int width;
  final int height;

  int get right => x + width;
  int get bottom => y + height;

  bool contains(int px, int py) =>
      px >= x && px < right && py >= y && py < bottom;

  Map<String, Object?> toJson() => {
        'label': label,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  @override
  String toString() => 'PixelRegion($label, $x,$y ${width}x$height)';
}

/// What one area of the image measured.
@immutable
class RegionComparison {
  const RegionComparison({
    required this.label,
    required this.differingPixels,
    required this.totalPixels,
    required this.maxChannelDelta,
    required this.ssim,
    this.outsideImage = false,
  });

  final String label;

  /// Pixels whose difference exceeded the channel tolerance.
  final int differingPixels;

  /// Pixels actually compared - ignore regions are not counted, so the
  /// ratio stays a fraction of what was really looked at.
  final int totalPixels;

  final int maxChannelDelta;

  /// Structural similarity, 1.0 for identical.
  final double ssim;

  /// The region does not overlap the image at all.
  ///
  /// Recorded, but not a failure. On a scrolling page most elements are
  /// below the fold, so failing for this would fail identically on
  /// every run. It is reported so a reader can tell "compared and
  /// matched" from "never looked at" - a distinction a bare pass would
  /// hide.
  ///
  /// A region that *partly* overlaps is not this: it is compared on the
  /// part that is visible.
  final bool outsideImage;

  double get differingRatio =>
      totalPixels == 0 ? 0 : differingPixels / totalPixels;

  Map<String, Object?> toJson() => {
        'label': label,
        'differingPixels': differingPixels,
        'totalPixels': totalPixels,
        'differingRatio': differingRatio,
        'maxChannelDelta': maxChannelDelta,
        'ssim': ssim,
        if (outsideImage) 'outsideImage': true,
      };

  @override
  String toString() => '$label: ${(differingRatio * 100).toStringAsFixed(2)}% '
      'of $totalPixels px differ, ssim ${ssim.toStringAsFixed(4)}';
}

/// The outcome of comparing two screenshots.
@immutable
class VisualComparison {
  const VisualComparison({
    required this.overall,
    required this.passed,
    required this.summary,
    this.regions = const [],
    this.ignored = const [],
    this.sizeMismatch = false,
  });

  /// The whole image, minus any ignored areas.
  final RegionComparison overall;

  /// Per-element measurements, when element regions were supplied.
  final List<RegionComparison> regions;

  final List<PixelRegion> ignored;

  /// The two images are not the same size.
  ///
  /// A distinct outcome rather than a pixel count: comparing a
  /// 1080-wide baseline with a 720-wide capture row by row produces a
  /// number that means nothing. The size change is itself the finding.
  final bool sizeMismatch;

  final bool passed;

  final String summary;

  /// Regions that differ, worst first - the useful order for a report.
  ///
  /// Off-screen regions are excluded: they were not compared at all, so
  /// listing them among the differences would put a 0.0% entry next to
  /// a real one and make the report read as noise.
  List<RegionComparison> get differingRegions {
    final differing = [
      for (final region in regions)
        if (!region.outsideImage && region.differingPixels > 0) region,
    ]..sort((a, b) => b.differingRatio.compareTo(a.differingRatio));
    return differing;
  }

  Map<String, Object?> toJson() => {
        'passed': passed,
        'summary': summary,
        if (sizeMismatch) 'sizeMismatch': true,
        'overall': overall.toJson(),
        if (regions.isNotEmpty)
          'regions': [for (final r in regions) r.toJson()],
        if (ignored.isNotEmpty)
          'ignored': [for (final r in ignored) r.toJson()],
      };

  @override
  String toString() => summary;
}
