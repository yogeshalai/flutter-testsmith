/// Which source of truth a result was measured against.
///
/// "The screen is correct" is not a sentence this platform can say. It
/// can say the UI matches the API, and the UI matches the design, and
/// the steps executed - and it must say those separately, because a
/// reader told only "PASS" cannot tell which of them was checked.
///
/// Declared by the validator that produced the result, never inferred
/// from the validator's name at report time: the producing code is the
/// only code that knows what it actually compared.
enum ValidationDimension {
  /// The user-written steps, and the readability of the UI itself.
  ui('ui'),

  /// Measured against an API response.
  api('api'),

  /// Measured against a Figma design.
  figma('figma'),

  /// Measured against an accepted screenshot baseline.
  ///
  /// Already a distinct dimension of this platform before E-06: its own
  /// step flag, its own validator, its own config block, its own
  /// on-disk store and its own enablement rule.
  visual('visual');

  const ValidationDimension(this.wire);

  final String wire;
}
