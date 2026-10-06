import 'package:meta/meta.dart';

/// How design copy is compared with what the app renders.
///
/// Two modes, not three. A "warn" mode was considered and dropped: a
/// [ValidationResult] is pass, fail, skip or error, and a fail always
/// blocks the screen. Expressing "compared, but advisory" would mean
/// adding a fifth status to a model every validator and the report
/// share, which is a change this one setting does not justify.
enum TextComparisonMode {
  /// A design holds placeholder copy and the running app holds live
  /// data. Comparing the two by default would fail every screen that
  /// works, so this is off unless asked for.
  ignore('ignore'),

  /// Compared, and a difference fails. Appropriate for static copy:
  /// button labels, section headings, legal text.
  strict('strict');

  const TextComparisonMode(this.wire);

  final String wire;

  static TextComparisonMode parse(String value, {required String source}) {
    for (final mode in values) {
      if (mode.wire == value) return mode;
    }
    throw FormatException(
      '$source: unknown text comparison mode "$value". '
      'Known: ${values.map((m) => m.wire).join(', ')}.',
    );
  }
}

/// Which horizontal edge of a text element its layout actually fixes.
///
/// This cannot be inferred, and Phase 12 established that the hard way.
/// Figma's `textAlign` describes where the glyphs sit **inside** the
/// text node's box, not how that box is anchored in its parent: the
/// example application has a left-positioned total whose design node is
/// `textAlign: CENTER`, and a right-aligned total whose design node is
/// `textAlign: RIGHT`. Reading the first as centre-anchored reported a
/// pixel-perfect element as 5.7px out.
///
/// So it is declared, per screen, by the team that knows. The default
/// is [left], which is what every layout does unless told otherwise and
/// what the platform compared before this setting existed.
enum TextAnchor {
  left('left'),
  right('right'),
  centre('centre');

  const TextAnchor(this.wire);

  final String wire;

  static TextAnchor parse(String value, {required String source}) {
    for (final anchor in values) {
      if (anchor.wire == value) return anchor;
    }
    // "center" is the spelling half the world uses, and rejecting it
    // over an "re" would be pedantry with a cost.
    if (value == 'center') return TextAnchor.centre;
    throw FormatException(
      '$source: unknown text anchor "$value". '
      'Known: ${values.map((a) => a.wire).join(', ')}.',
    );
  }
}

/// Every threshold Figma structural comparison uses.
///
/// Gathered into one object on purpose. Tolerances scattered as literals
/// at their call sites cannot be tuned per screen, and a number buried
/// in a comparison is a number nobody ever revisits.
@immutable
class FigmaTolerances {
  const FigmaTolerances({
    this.positionPx = 4,
    this.sizePx = 3,
    this.fontSizePx = 1,
    this.fontWeightSteps = 0,
    this.colourChannelDelta = 8,
    this.aspectDelta = 0.05,
    this.spacingPx = 4,
    this.opacityDelta = 0.02,
    this.cornerRadiusPx = 2,
    this.designSafeAreaTop,
    this.text = TextComparisonMode.ignore,
    this.textAnchor = TextAnchor.left,
    this.checkGeometry = true,
    this.checkOrdering = true,
    this.checkTypography = true,
    this.checkColour = true,
    this.checkHierarchy = true,
    this.checkSpacing = true,
    this.checkOpacity = true,
    this.checkCornerRadius = true,

    /// Off by default: Flutter reports families as `packages/x/Inter`
    /// and a theme may legitimately substitute one, so this fails noisily
    /// on projects that are in fact correct.
    this.checkFontFamily = false,

    /// Off by default: a screen legitimately contains elements no
    /// designer drew - debug banners, platform chrome, a11y affordances.
    this.reportUnexpected = false,

    /// Off by default, and this one is not a matter of taste.
    ///
    /// A text node's box is typeset, not laid out: its width and height
    /// come from the font, and font size is compared absolutely while
    /// geometry is compared in projected space. The two cannot agree on
    /// a device whose width differs from the design's, so comparing
    /// them reports a failure no layout change can fix. The font itself
    /// is still checked, exactly, by the typography comparison.
    this.checkTextSize = false,
  });

  /// The one place the platform's default thresholds are stated.
  static const FigmaTolerances defaults = FigmaTolerances();

  /// Allowed drift of a projected position, in device logical pixels.
  final double positionPx;

  /// Allowed difference in width or height.
  final double sizePx;

  final double fontSizePx;

  /// Allowed difference in font weight, in 100-unit steps.
  final int fontWeightSteps;

  /// Allowed per-channel difference in an 8-bit colour.
  final int colourChannelDelta;

  /// How differently shaped a design and a viewport may be before
  /// vertical comparison stops being meaningful.
  final double aspectDelta;

  /// Allowed difference in a projected gap or padding, in device
  /// logical pixels.
  ///
  /// Its own setting rather than a reuse of [positionPx]: a gap is the
  /// difference of two positions, so it carries both their errors, and
  /// tying the two together would mean loosening position tolerance to
  /// quiet a spacing report.
  final double spacingPx;

  /// Allowed difference in opacity, 0..1.
  ///
  /// Small, because opacity is authored as a round number on both
  /// sides. Not zero, because Figma stores 0.2 as 0.20000000298023224.
  final double opacityDelta;

  /// Allowed difference in a corner radius, in device logical pixels.
  final double cornerRadiusPx;

  /// How much of the design frame's height the designer intended as
  /// status-bar area, when a team declares it.
  ///
  /// Figma publishes no safe-area metadata: a frame is 874pt tall and
  /// says nothing about how much of that is chrome. Null means "not
  /// declared", and then top-anchored elements are compared against the
  /// frame's own origin and the report states the device's inset so the
  /// cause of any offset is visible.
  ///
  /// There is deliberately no default. A constant here would be wrong on
  /// every device except the one it came from, and would move every
  /// top-anchored element on every screen by the error.
  final double? designSafeAreaTop;

  final TextComparisonMode text;

  /// Which horizontal edge of a text element is compared.
  ///
  /// Only consulted while text sizes are *not* compared: when they are,
  /// the two boxes are the same size and every edge agrees.
  final TextAnchor textAnchor;

  final bool checkGeometry;
  final bool checkOrdering;
  final bool checkTypography;
  final bool checkColour;

  /// Whether ancestry the design declares is asserted on the screen.
  final bool checkHierarchy;

  /// Whether gaps and padding are compared.
  final bool checkSpacing;

  final bool checkOpacity;
  final bool checkCornerRadius;
  final bool checkFontFamily;
  final bool reportUnexpected;
  final bool checkTextSize;

  static const Set<String> _keys = {
    'positionPx',
    'sizePx',
    'fontSizePx',
    'fontWeightSteps',
    'colourChannelDelta',
    'aspectDelta',
    'spacingPx',
    'opacityDelta',
    'cornerRadiusPx',
    'designSafeAreaTop',
    'text',
    'textAnchor',
    'checkGeometry',
    'checkOrdering',
    'checkTypography',
    'checkColour',
    'checkHierarchy',
    'checkSpacing',
    'checkOpacity',
    'checkCornerRadius',
    'checkFontFamily',
    'reportUnexpected',
    'checkTextSize',
  };

  /// Reads a `figma:` section. A missing section means [defaults].
  factory FigmaTolerances.fromYaml(Object? node, {required String source}) {
    if (node == null) return defaults;
    if (node is! Map) {
      throw FormatException('$source: "figma" must be a mapping of settings');
    }

    final raw = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );

    for (final key in raw.keys) {
      if (_keys.contains(key)) continue;
      throw FormatException(
        '$source: unknown figma setting "$key". '
        'Known: ${_keys.join(', ')}.',
      );
    }

    double positiveNumber(String key, double fallback) {
      final value = raw[key];
      if (value == null) return fallback;
      if (value is! num) {
        throw FormatException('$source: "$key" must be a number');
      }
      if (value < 0) {
        throw FormatException(
          '$source: "$key" is $value; a tolerance cannot be negative.',
        );
      }
      return value.toDouble();
    }

    bool flag(String key, {required bool fallback}) {
      final value = raw[key];
      if (value == null) return fallback;
      if (value is! bool) {
        throw FormatException('$source: "$key" must be true or false');
      }
      return value;
    }

    final rawText = raw['text'];
    final rawAnchor = raw['textAnchor'];

    return FigmaTolerances(
      positionPx: positiveNumber('positionPx', defaults.positionPx),
      sizePx: positiveNumber('sizePx', defaults.sizePx),
      fontSizePx: positiveNumber('fontSizePx', defaults.fontSizePx),
      fontWeightSteps:
          positiveNumber('fontWeightSteps', defaults.fontWeightSteps.toDouble())
              .round(),
      colourChannelDelta: positiveNumber(
        'colourChannelDelta',
        defaults.colourChannelDelta.toDouble(),
      ).round(),
      aspectDelta: positiveNumber('aspectDelta', defaults.aspectDelta),
      spacingPx: positiveNumber('spacingPx', defaults.spacingPx),
      opacityDelta: positiveNumber('opacityDelta', defaults.opacityDelta),
      cornerRadiusPx:
          positiveNumber('cornerRadiusPx', defaults.cornerRadiusPx),
      designSafeAreaTop: raw['designSafeAreaTop'] == null
          ? null
          : positiveNumber('designSafeAreaTop', 0),
      text: rawText == null
          ? defaults.text
          : TextComparisonMode.parse(rawText.toString(), source: source),
      textAnchor: rawAnchor == null
          ? defaults.textAnchor
          : TextAnchor.parse(rawAnchor.toString(), source: source),
      checkGeometry: flag('checkGeometry', fallback: defaults.checkGeometry),
      checkOrdering: flag('checkOrdering', fallback: defaults.checkOrdering),
      checkTypography:
          flag('checkTypography', fallback: defaults.checkTypography),
      checkColour: flag('checkColour', fallback: defaults.checkColour),
      checkHierarchy:
          flag('checkHierarchy', fallback: defaults.checkHierarchy),
      checkSpacing: flag('checkSpacing', fallback: defaults.checkSpacing),
      checkOpacity: flag('checkOpacity', fallback: defaults.checkOpacity),
      checkCornerRadius:
          flag('checkCornerRadius', fallback: defaults.checkCornerRadius),
      checkFontFamily:
          flag('checkFontFamily', fallback: defaults.checkFontFamily),
      reportUnexpected:
          flag('reportUnexpected', fallback: defaults.reportUnexpected),
      checkTextSize: flag('checkTextSize', fallback: defaults.checkTextSize),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FigmaTolerances &&
      other.positionPx == positionPx &&
      other.sizePx == sizePx &&
      other.fontSizePx == fontSizePx &&
      other.fontWeightSteps == fontWeightSteps &&
      other.colourChannelDelta == colourChannelDelta &&
      other.aspectDelta == aspectDelta &&
      other.spacingPx == spacingPx &&
      other.opacityDelta == opacityDelta &&
      other.cornerRadiusPx == cornerRadiusPx &&
      other.designSafeAreaTop == designSafeAreaTop &&
      other.checkHierarchy == checkHierarchy &&
      other.checkSpacing == checkSpacing &&
      other.checkOpacity == checkOpacity &&
      other.checkCornerRadius == checkCornerRadius &&
      other.text == text &&
      other.textAnchor == textAnchor &&
      other.checkGeometry == checkGeometry &&
      other.checkOrdering == checkOrdering &&
      other.checkTypography == checkTypography &&
      other.checkColour == checkColour &&
      other.checkFontFamily == checkFontFamily &&
      other.reportUnexpected == reportUnexpected &&
      other.checkTextSize == checkTextSize;

  @override
  int get hashCode => Object.hashAll([
        positionPx,
        sizePx,
        fontSizePx,
        fontWeightSteps,
        colourChannelDelta,
        aspectDelta,
        spacingPx,
        opacityDelta,
        cornerRadiusPx,
        designSafeAreaTop,
        checkHierarchy,
        checkSpacing,
        checkOpacity,
        checkCornerRadius,
        text,
        textAnchor,
        checkGeometry,
        checkOrdering,
        checkTypography,
        checkColour,
        checkFontFamily,
        reportUnexpected,
        checkTextSize,
      ]);

  @override
  String toString() => 'FigmaTolerances(position ${positionPx}px, '
      'size ${sizePx}px, text ${text.wire})';
}
