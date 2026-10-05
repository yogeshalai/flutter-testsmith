/// Whether the SDK may instrument the application, and why not when it may
/// not.
///
/// This is the second of the three independent production-safety layers
/// described in ARCHITECTURE 9.2. The first is a compile-time constant that
/// lets the tree-shaker remove the instrumentation from release builds
/// entirely; the third is that the VM Service does not exist in release
/// builds at all. Any one layer failing still leaves two.
enum ArmDecision {
  armed(''),
  disabledByConfig(
    'TestSdkConfig.enabled is false, so no instrumentation was installed. '
    'Build with --dart-define=TEST_MODE=true to enable it.',
  ),
  blockedInRelease(
    'Refusing to instrument a release build. Test instrumentation exposes '
    'navigation, network traffic and the widget tree, none of which belong '
    'in a shipped application. Use a debug or profile build, or set '
    'allowInRelease: true if you genuinely intend this.',
  );

  const ArmDecision(this.explanation);

  /// Why instrumentation was withheld. Empty for [armed].
  final String explanation;

  bool get isArmed => this == ArmDecision.armed;
}

/// Decides whether the SDK may arm.
///
/// Kept as a pure function so the safety rule is testable without a Flutter
/// binding, a build mode, or a running application.
ArmDecision decideArming({
  required bool configEnabled,
  required bool isReleaseMode,
  required bool allowInRelease,
}) {
  // Config wins outright: an explicitly disabled SDK never arms, whatever
  // else is set.
  if (!configEnabled) return ArmDecision.disabledByConfig;
  if (isReleaseMode && !allowInRelease) return ArmDecision.blockedInRelease;
  return ArmDecision.armed;
}
