import 'package:meta/meta.dart';

import 'redaction.dart';

/// How the in-application SDK behaves.
///
/// [enabled] defaults to false so that merely depending on this package
/// instruments nothing. The intended wiring passes a compile-time constant:
///
/// ```dart
/// await TestSdk.initialize(
///   config: TestSdkConfig(
///     enabled: const bool.fromEnvironment('TEST_MODE'),
///   ),
/// );
/// ```
///
/// Because that is a `const`, the tree-shaker can remove the instrumentation
/// from a release build entirely.
@immutable
class TestSdkConfig {
  const TestSdkConfig({
    this.enabled = false,
    this.enableNavigationTracking = true,
    this.enableNetworkCapture = true,
    this.enableUiInspection = true,
    this.enableScreenshots = true,
    this.redaction = const RedactionPolicy.strictDefaults(),
    this.maxBodyBytes = 64 * 1024,
    this.eventBufferSize = 500,
    this.allowInRelease = false,
    this.environment = 'test',
  });

  /// The master switch. Everything else is inert while this is false.
  final bool enabled;

  final bool enableNavigationTracking;
  final bool enableNetworkCapture;
  final bool enableUiInspection;

  /// Whether the application will rasterise its own surface on request.
  ///
  /// Separate from [enableUiInspection] because the cost is different:
  /// a tree capture walks elements, a surface capture rasterises a few
  /// million pixels and ships them over the VM Service. An application
  /// that only needs structural validation can leave this off and never
  /// pay for it.
  final bool enableScreenshots;

  /// Applied at capture time, in-process, before an event is emitted.
  final RedactionPolicy redaction;

  /// Request and response bodies are truncated to this size, with the
  /// truncation recorded so no report silently shows partial data.
  final int maxBodyBytes;

  /// How many events the startup ring buffer retains.
  final int eventBufferSize;

  /// Escape hatch for the release-mode guard. See [ArmDecision].
  final bool allowInRelease;

  final String environment;

  /// What this configuration actually permits, sent in the handshake so the
  /// engine never invokes an RPC the application does not serve.
  ///
  /// Empty while disabled: a disabled SDK offers nothing, whatever its
  /// feature flags say.
  Set<String> get capabilities {
    if (!enabled) return const {};
    return {
      if (enableNavigationTracking) 'navigation',
      if (enableUiInspection) 'uiTree',
      if (enableNetworkCapture) 'network',
      // Exactly when 'network' is: every duration NetworkCapture emits,
      // through the dart:io adapter or the manual API, is measured on its
      // monotonic source. An engine that sees 'network' without this is
      // talking to an older SDK, whose durations came from the wall clock.
      if (enableNetworkCapture) 'monotonicNetworkTiming',
      // 'screenshot' is added by the session rather than here: config
      // alone is not enough, because rasterising also needs a capture
      // function and a painted frame.
    };
  }

  /// Throws [ArgumentError] if the configuration cannot be honoured.
  void validate() {
    if (eventBufferSize < 1) {
      throw ArgumentError.value(
        eventBufferSize,
        'eventBufferSize',
        'Must be at least 1',
      );
    }
    if (maxBodyBytes < 0) {
      throw ArgumentError.value(
        maxBodyBytes,
        'maxBodyBytes',
        'Must not be negative',
      );
    }
  }
}
