import 'package:meta/meta.dart';

/// Thresholds for screenshot comparison.
///
/// Two metrics with separate thresholds, deliberately. They fail on
/// different things: the pixel ratio catches a localised change - a
/// moved button, a wrong colour - while SSIM catches structural change
/// spread so thinly that every individual pixel stays under the channel
/// threshold, which is what a font substitution looks like.
@immutable
class VisualTolerances {
  const VisualTolerances({
    this.channelDelta = 8,
    this.maxDifferingRatio = 0.002,
    this.maxElementDifferingRatio = 0.05,
    this.minSsim = 0.98,
  });

  /// The one place the platform's visual defaults are stated.
  static const VisualTolerances defaults = VisualTolerances();

  /// How far one 8-bit channel may move before the pixel counts as
  /// changed.
  ///
  /// Not zero, and that is the single most important number here.
  /// Antialiasing, font hinting and GPU rounding move channels by a few
  /// units across a whole screen between otherwise identical runs. A
  /// zero threshold reports every screen as changed, and a check that
  /// always fails is a check that gets switched off - see risk R6.
  final int channelDelta;

  /// The fraction of compared pixels allowed to differ.
  final double maxDifferingRatio;

  /// The fraction of one element's own pixels allowed to differ.
  ///
  /// Needed because the whole-screen ratio is a poor instrument for a
  /// small element. A wrong price occupies a few hundred pixels of a
  /// million-pixel screen - around 0.1%, comfortably inside
  /// [maxDifferingRatio] - while being most of that element. Measured
  /// against its own area it is unmistakable, and the report can name
  /// what changed instead of saying the screen moved slightly.
  final double maxElementDifferingRatio;

  /// The lowest acceptable structural similarity.
  ///
  /// Deliberately loose, because mean SSIM is a coarse backstop and not
  /// the primary gate. It is an average over 8x8 windows, so what one
  /// changed area costs depends on how many windows the image has and
  /// how flat the rest of it is: a single stray pixel on a 100x100
  /// image drags the mean to 0.994, while the same pixel on a
  /// 1080x2400 screenshot costs 0.00002. A threshold tight enough to
  /// mean something on a small image fails constantly on a large one.
  ///
  /// So the pixel ratio decides localised change, and this catches the
  /// case that ratio is blind to: structural change spread so thinly
  /// that no single pixel crosses [channelDelta].
  final double minSsim;

  static const Set<String> _keys = {
    'channelDelta',
    'maxDifferingRatio',
    'maxElementDifferingRatio',
    'minSsim',
  };

  /// Reads a `visual:` section. A missing section means [defaults].
  factory VisualTolerances.fromYaml(Object? node, {required String source}) {
    if (node == null) return defaults;
    if (node is! Map) {
      throw FormatException('$source: "visual" must be a mapping of settings');
    }

    final raw = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );

    for (final key in raw.keys) {
      if (_keys.contains(key)) continue;
      throw FormatException(
        '$source: unknown visual setting "$key". Known: ${_keys.join(', ')}.',
      );
    }

    num number(String key, num fallback) {
      final value = raw[key];
      if (value == null) return fallback;
      if (value is! num) {
        throw FormatException('$source: "$key" must be a number');
      }
      if (value < 0) {
        throw FormatException('$source: "$key" cannot be negative');
      }
      return value;
    }

    return VisualTolerances(
      channelDelta: number('channelDelta', defaults.channelDelta).round(),
      maxDifferingRatio:
          number('maxDifferingRatio', defaults.maxDifferingRatio).toDouble(),
      maxElementDifferingRatio: number(
        'maxElementDifferingRatio',
        defaults.maxElementDifferingRatio,
      ).toDouble(),
      minSsim: number('minSsim', defaults.minSsim).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VisualTolerances &&
      other.channelDelta == channelDelta &&
      other.maxDifferingRatio == maxDifferingRatio &&
      other.maxElementDifferingRatio == maxElementDifferingRatio &&
      other.minSsim == minSsim;

  @override
  int get hashCode => Object.hash(
        channelDelta,
        maxDifferingRatio,
        maxElementDifferingRatio,
        minSsim,
      );

  @override
  String toString() => 'VisualTolerances(channel $channelDelta, '
      'ratio $maxDifferingRatio, ssim $minSsim)';
}
