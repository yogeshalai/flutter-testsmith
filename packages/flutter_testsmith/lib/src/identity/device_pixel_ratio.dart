/// Chooses the device pixel ratio to report to the engine.
///
/// Getting this wrong is not cosmetic: the engine multiplies every logical
/// coordinate by it to find where to tap. A plausible-looking wrong value
/// mis-places every interaction, which is exactly what a hard-coded 1.0
/// fallback did on a 1.875 device.
///
/// A view that exists but has not been laid out reports 0, so 0 is treated
/// as "unknown" rather than as an answer. When nothing is known this
/// returns 0 deliberately: CoordinateSpace rejects it with a clear error,
/// and an obvious failure beats a silent 47% offset.
double resolveDevicePixelRatio({
  required double? implicitViewRatio,
  required List<double> viewRatios,
}) {
  if (implicitViewRatio != null && implicitViewRatio > 0) {
    return implicitViewRatio;
  }
  for (final ratio in viewRatios) {
    if (ratio > 0) return ratio;
  }
  return 0;
}
