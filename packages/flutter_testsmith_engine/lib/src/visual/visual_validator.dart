import 'dart:typed_data';

import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../device/surface_screenshot.dart';

import '../validation/validation_dimension.dart';
import '../validation/validation_result.dart';
import 'baseline_store.dart';
import 'visual_comparator.dart';
import 'visual_comparison.dart';
import 'visual_tolerances.dart';

/// What a screen's visual check is configured with.
class VisualCheckConfig {
  const VisualCheckConfig({
    this.tolerances = VisualTolerances.defaults,
    this.ignoreElements = const [],
    this.ignoreRegions = const [],
    this.compareElements = true,
    this.capture = CapturePath.screencap,
  });

  static const VisualCheckConfig defaults = VisualCheckConfig();

  final VisualTolerances tolerances;

  /// Semantic ids whose area is excluded - an element holding a clock,
  /// a rotating advert, a user avatar.
  final List<String> ignoreElements;

  /// Areas excluded by position, in **logical** pixels.
  ///
  /// Logical, so one configuration survives being run on a device of a
  /// different density. The conversion to image pixels uses the ratio
  /// from the same capture - see ADR-0006.
  ///
  /// A negative `y` is measured from the bottom of the image, which is
  /// the only way to write down a system navigation bar without tying
  /// the configuration to one device's height.
  final List<LogicalRect> ignoreRegions;

  /// Whether to measure each identified element separately, so a report
  /// can say which one moved.
  final bool compareElements;

  /// Which picture of the screen to take.
  ///
  /// Defaults to `screencap`, which is what every committed baseline in
  /// this repository was recorded with. Changing it invalidates those
  /// baselines by design: the store refuses to diff across paths rather
  /// than reporting a change that never happened.
  final CapturePath capture;

  /// The same configuration with [regions] also excluded.
  ///
  /// The bridge between quiescence and visual comparison. An animation
  /// the screen declared runs for ever, so its pixels differ in every
  /// frame; comparing them against a baseline would fail at random.
  ///
  /// By region rather than by element, because the declaration names an
  /// *enclosing* id - often a whole scroll body - while what actually
  /// moves may be a 33x33 badge inside it. Excluding the declaration
  /// would blank the screen to hide a badge.
  VisualCheckConfig excludingRegions(Iterable<LogicalRect> regions) {
    final combined = <LogicalRect>[...ignoreRegions];
    for (final region in regions) {
      if (!combined.contains(region)) combined.add(region);
    }
    if (combined.length == ignoreRegions.length) return this;

    return VisualCheckConfig(
      tolerances: tolerances,
      ignoreElements: ignoreElements,
      ignoreRegions: combined,
      compareElements: compareElements,
      capture: capture,
    );
  }

  /// The same configuration with [elements] also excluded.
  ///
  /// The bridge between quiescence and visual comparison. An animation
  /// the screen declared runs for ever, so its pixels differ in every
  /// frame; comparing them against a baseline would fail at random.
  /// They come out of the comparison, and the report says which and how
  /// much, because an exclusion nobody mentions is a hole in the check.
  ///
  /// Additive and idempotent: whatever the screen already ignored stays
  /// ignored, and an element named twice is excluded once.
  VisualCheckConfig excluding(Iterable<String> elements) {
    final combined = <String>[...ignoreElements];
    for (final element in elements) {
      if (!combined.contains(element)) combined.add(element);
    }
    if (combined.length == ignoreElements.length) return this;

    return VisualCheckConfig(
      tolerances: tolerances,
      ignoreElements: combined,
      ignoreRegions: ignoreRegions,
      compareElements: compareElements,
      capture: capture,
    );
  }

  static const Set<String> _ownKeys = {
    'ignoreElements',
    'ignoreRegions',
    'compareElements',
    'capture',
  };

  /// Reads a `visual:` section. A missing section means [defaults].
  ///
  /// Tolerance keys live in the same block rather than a nested one:
  /// people configuring a screen think in terms of "how strict is the
  /// visual check here", not in terms of which class holds the number.
  factory VisualCheckConfig.fromYaml(Object? node, {required String source}) {
    if (node == null) return defaults;
    if (node is! Map) {
      throw FormatException('$source: "visual" must be a mapping of settings');
    }

    final raw = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );

    final toleranceKeys = {
      for (final entry in raw.entries)
        if (!_ownKeys.contains(entry.key)) entry.key: entry.value,
    };

    final regions = raw['ignoreRegions'];
    if (regions != null && regions is! List) {
      throw FormatException('$source: "ignoreRegions" must be a list');
    }

    final elements = raw['ignoreElements'];
    if (elements != null && elements is! List) {
      throw FormatException('$source: "ignoreElements" must be a list');
    }

    final compare = raw['compareElements'];
    if (compare != null && compare is! bool) {
      throw FormatException('$source: "compareElements" must be true/false');
    }

    final capture = raw['capture'];
    if (capture != null && capture is! String) {
      throw FormatException(
        '$source: "capture" must be one of '
        '${CapturePath.values.map((p) => p.wire).join(', ')}',
      );
    }

    return VisualCheckConfig(
      // Unknown keys are rejected here, by the tolerance parser.
      tolerances: VisualTolerances.fromYaml(
        toleranceKeys.isEmpty ? null : toleranceKeys,
        source: source,
      ),
      ignoreElements: [
        for (final e in (elements as List?) ?? const []) e.toString(),
      ],
      ignoreRegions: [
        for (final region in (regions as List?) ?? const [])
          _rect(region, source),
      ],
      compareElements: (compare as bool?) ?? defaults.compareElements,
      capture: capture == null
          ? defaults.capture
          : CapturePath.parse(capture as String, source: source),
    );
  }

  static LogicalRect _rect(Object? node, String source) {
    if (node is! Map) {
      throw FormatException(
        '$source: each ignoreRegions entry must be a mapping with x, y, '
        'width and height in logical pixels',
      );
    }
    final raw = node.cast<Object?, Object?>();
    double read(String key) {
      final value = raw[key];
      if (value is! num) {
        throw FormatException('$source: ignoreRegions needs a numeric "$key"');
      }
      if (value < 0 && key != 'y') {
        // Only y carries the from-the-bottom meaning. A negative width
        // is a typo, and silently clamping it to zero would disable an
        // ignore region without saying so.
        throw FormatException(
          '$source: ignoreRegions "$key" is $value; only "y" may be '
          'negative, where it means "measured from the bottom".',
        );
      }
      return value.toDouble();
    }

    return LogicalRect(
      x: read('x'),
      y: read('y'),
      width: read('width'),
      height: read('height'),
    );
  }
}

/// Compares this run's screenshot with the accepted baseline.
///
/// Not a [ScreenValidator], and the reason is mechanical rather than
/// philosophical: decoding and diffing a few million pixels happens on
/// a background isolate, so this is asynchronous, and that interface is
/// synchronous. Adding an async variant of it for a single
/// implementation would be ceremony; the runner composes this in
/// alongside the others.
class VisualValidator {
  const VisualValidator({
    this.comparator = const VisualComparator(),
  });

  static const String id = 'visual';

  final VisualComparator comparator;

  /// Compares [screenshot] with the stored baseline for [screenId].
  ///
  /// Which baseline that is, is [BaselineStore.select]'s decision and
  /// not this method's. Selection refuses where choosing would be
  /// guessing - two candidates, or one recorded on hardware this
  /// profile does not match - and the refusal is an ERROR here rather
  /// than a comparison, because a picture compared against the wrong
  /// picture produces a verdict about nothing.
  ///
  /// When no baseline exists the image is recorded and the check is
  /// reported as skipped. A first run cannot detect a regression, and
  /// saying "pass" would claim it had.
  /// Compares the screenshot, stamping the visual dimension on every
  /// result.
  ///
  /// A wrapper rather than a stamp at each `return`: the comparison has
  /// several early exits - no baseline, an ambiguous one, a size
  /// mismatch - and one of them would eventually be added without the
  /// stamp.
  Future<List<ValidationResult>> validate({
    required String screenId,
    required Uint8List screenshot,
    required ScreenshotSource source,
    required BaselineStore store,
    UiSnapshot? snapshot,
    VisualCheckConfig config = VisualCheckConfig.defaults,
    bool updateBaseline = false,
  }) async =>
      [
        for (final result in await _compare(
          screenId: screenId,
          screenshot: screenshot,
          source: source,
          store: store,
          snapshot: snapshot,
          config: config,
          updateBaseline: updateBaseline,
        ))
          result.inDimension(ValidationDimension.visual),
      ];

  Future<List<ValidationResult>> _compare({
    required String screenId,
    required Uint8List screenshot,
    required ScreenshotSource source,
    required BaselineStore store,
    UiSnapshot? snapshot,
    VisualCheckConfig config = VisualCheckConfig.defaults,
    bool updateBaseline = false,
  }) async {
    final BaselineSelection selection;
    try {
      selection = await store.select(screenId);
    } on StateError catch (error) {
      return [
        ValidationResult.error(validatorId: id, message: '$error'),
      ];
    }

    if (selection is BaselineMissing || updateBaseline) {
      final size = pngDimensions(screenshot);
      if (size == null) {
        return [
          ValidationResult.error(
            validatorId: id,
            message: 'the captured screenshot is not a PNG, so it was not '
                'recorded as a baseline',
          ),
        ];
      }
      await store.write(
        screenId,
        Baseline(
          bytes: screenshot,
          source: source,
          width: size.width,
          height: size.height,
          recordedAt: DateTime.now().toUtc(),
        ),
      );
      return [
        ValidationResult.skip(
          validatorId: id,
          message: selection is BaselineMissing
              ? 'no baseline for "$screenId"; this run was recorded as one '
                  'at ${store.imageFile(screenId).path}. Review and commit '
                  'it - the next run compares against it.'
              : 'baseline for "$screenId" replaced on request',
        ),
      ];
    }

    switch (selection) {
      case BaselineMissing():
        // Handled above; `updateBaseline` is the only way here.
        throw StateError('unreachable');

      case BaselineAmbiguous(:final paths):
        // Two files could answer "what should this screen look like".
        // Picking one would make the verdict depend on directory order.
        return [
          ValidationResult.error(
            validatorId: id,
            message: 'there is more than one baseline for "$screenId", so '
                'which one this run should be compared against is not '
                'decided: ${paths.join(', ')}. Delete the one that is no '
                'longer accepted.',
          ),
        ];

      case BaselineIncompatible(:final path, :final reasons):
        return [
          ValidationResult.error(
            validatorId: id,
            message: 'the baseline $path cannot be compared against under '
                'this device profile: ${reasons.join('; ')}. Re-record it '
                'on a device the profile describes.',
          ),
        ];

      case BaselineSelected(
          baseline: final baseline,
          path: final path,
          isLegacyPath: final isLegacy
        ):
        if (baseline.source != source) {
          // Same screen, different picture: a RepaintBoundary image has
          // no status bar and a screencap does.
          return [
            ValidationResult.error(
              validatorId: id,
              message:
                  'the baseline was captured by ${baseline.source.wire} but '
                  'this run captured by ${source.wire}. These are different '
                  'pictures of the same screen and comparing them would '
                  'report a change that did not happen. Re-record the '
                  'baseline.',
            ),
          ];
        }

        final ratio = snapshot?.devicePixelRatio ?? 1.0;
        final ignore = _ignoreRegions(snapshot, config, ratio);
        final regions = config.compareElements
            ? _elementRegions(snapshot, config, ratio)
            : const <PixelRegion>[];

        final VisualComparison comparison;
        try {
          comparison = await comparator.compare(
            baseline: baseline.bytes,
            current: screenshot,
            ignore: ignore,
            regions: regions,
          );
        } on FormatException catch (error) {
          return [
            ValidationResult.error(validatorId: id, message: '$error'),
          ];
        }

        return [
          _result(
            screenId,
            comparison,
            _provenance(store, baseline, path, isLegacy),
          ),
        ];
    }
  }

  /// What the run compared against, as evidence.
  ///
  /// A pass that does not say which file it compared against, under
  /// which profile, at what resolution and pixel ratio, is a green tick
  /// nobody can check. `compatibility: compatible` is here because
  /// selection asserted it - it is the record that the question was
  /// asked, not a restatement of the obvious.
  List<Evidence> _provenance(
    BaselineStore store,
    Baseline baseline,
    String path,
    bool isLegacy,
  ) =>
      [
        Evidence(kind: 'baseline', reference: path),
        if (store.profile case final profile?)
          Evidence(kind: 'deviceProfile', reference: profile.id),
        Evidence(
          kind: 'resolution',
          reference: '${baseline.width}x${baseline.height}',
        ),
        if (baseline.devicePixelRatio case final ratio?)
          Evidence(kind: 'devicePixelRatio', reference: '$ratio'),
        Evidence(kind: 'compatibility', reference: 'compatible'),
        if (isLegacy) const Evidence(kind: 'baselineLayout', reference: 'legacy'),
      ];

  ValidationResult _result(
    String screenId,
    VisualComparison comparison,
    List<Evidence> provenance,
  ) {
    if (comparison.passed) {
      return ValidationResult.pass(
        validatorId: id,
        message: '"$screenId" ${comparison.summary}',
        evidence: [
          ...provenance,
          Evidence(
            kind: 'ssim',
            reference: comparison.overall.ssim.toStringAsFixed(4),
          ),
        ],
      );
    }

    // Name the worst-hit elements: "3.4% of the screen differs" sends
    // someone hunting, "product.price differs" does not.
    final worst = comparison.differingRegions.take(3).toList();
    final where = worst.isEmpty
        ? ''
        : '. Worst: ${worst.map((r) => '${r.label} '
            '(${(r.differingRatio * 100).toStringAsFixed(2)}%)').join(', ')}';

    return ValidationResult.fail(
      validatorId: id,
      message: '"$screenId" ${comparison.summary}$where',
      expected: 'the accepted baseline',
      actual: comparison.overall.toString(),
      evidence: [
        ...provenance,
        for (final region in worst)
          Evidence(kind: 'region', reference: region.label),
      ],
    );
  }

  List<PixelRegion> _ignoreRegions(
    UiSnapshot? snapshot,
    VisualCheckConfig config,
    double ratio,
  ) {
    final regions = <PixelRegion>[
      for (final (index, rect) in config.ignoreRegions.indexed)
        _toPixels('ignore[$index]', rect, ratio),
    ];

    for (final id in config.ignoreElements) {
      final node = snapshot?.find(id);
      if (node == null) continue;
      regions.add(_toPixels(id, node.bounds, ratio));
    }
    return regions;
  }

  List<PixelRegion> _elementRegions(
    UiSnapshot? snapshot,
    VisualCheckConfig config,
    double ratio,
  ) {
    if (snapshot == null) return const [];
    final ignored = config.ignoreElements.toSet();

    // Only the topmost route's elements.
    //
    // D-12. Flutter keeps a covered route built, so the tree on screen B
    // still holds screen A's widgets at their old bounds. Measuring them
    // reports a region whose pixels belong to whatever is painted over
    // it - which is how `home.open_cart` came to be named among the
    // worst-differing elements of `/product/details`.
    //
    // A screen whose nodes carry no route index at all - an older SDK,
    // or a Flutter that renamed the scope widget - measures everything,
    // exactly as before.
    //
    // The rule itself lives on [UiSnapshot], because the action path
    // needs the same answer: a tap on a covered route lands on whatever
    // is painted over it, for the same reason its pixels do.
    return [
      for (final id in snapshot.root.testIds.toList()..sort())
        if (!ignored.contains(id) && !snapshot.duplicateTestIds.contains(id))
          if (snapshot.find(id) case final node?)
            if (!node.bounds.isEmpty && snapshot.isOnTopRoute(node))
              _toPixels(id, node.bounds, ratio),
    ];
  }

  /// Converts a logical rectangle to image pixels.
  ///
  /// A negative y keeps its sign through the multiplication, so the
  /// comparator can resolve it against the image height it alone knows.
  static PixelRegion _toPixels(String label, LogicalRect rect, double ratio) =>
      PixelRegion(
        label: label,
        x: (rect.x * ratio).round(),
        y: (rect.y * ratio).round(),
        width: (rect.width * ratio).round(),
        height: (rect.height * ratio).round(),
      );
}
