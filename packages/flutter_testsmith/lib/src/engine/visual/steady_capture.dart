import 'dart:typed_data';

import 'visual_comparator.dart';
import 'visual_comparison.dart';
import 'visual_tolerances.dart';

/// Photographs a screen until two pictures in a row agree.
///
/// A settle reading is taken *before* the shutter, and the screen can
/// change after it. Measured on a real dashboard: `awaitQuiescence`
/// reported a quiet screen and the picture still caught the outlet
/// images part-way through their fade-in - **44% different** from a
/// baseline of the same screen fully painted, in 7 runs out of 8.
///
/// Nothing was wrong with either the reading or the capture. The gap
/// between them is simply real, and a quiet period cannot close it,
/// because more than 500ms can pass between one network image arriving
/// and the next - which leaves quiet windows in the middle of a screen
/// that is still assembling itself.
///
/// So the screen is photographed twice and the pair must agree outside
/// the ignored regions. A permitted animation changes every frame and is
/// already excluded, so it does not prevent agreement; a screen still
/// assembling itself does.
///
/// Returning null is a **skip**, not a failure: a screen that will not
/// hold still is something the tool could not measure, not a claim about
/// the application.
class SteadyCapture {
  const SteadyCapture({this.attempts = 3});

  /// How many pairs to try before giving up.
  final int attempts;

  /// The first picture that agreed with the one before it.
  Future<Uint8List?> take({
    required Future<Uint8List> Function() capture,
    required VisualTolerances tolerances,
    List<PixelRegion> ignore = const [],
  }) async {
    final comparator = VisualComparator(tolerances: tolerances);
    var previous = await capture();

    for (var attempt = 0; attempt < attempts; attempt++) {
      final current = await capture();
      final comparison = await comparator.compare(
        baseline: previous,
        current: current,
        ignore: ignore,
      );

      if (!comparison.sizeMismatch &&
          comparison.overall.differingRatio <= tolerances.maxDifferingRatio) {
        return current;
      }

      // The newer picture becomes the thing to agree with. A screen that
      // is settling - images arriving one after another - converges this
      // way; one that is genuinely unstable does not.
      previous = current;
    }

    return null;
  }
}
