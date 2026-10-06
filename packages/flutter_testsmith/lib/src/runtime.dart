import 'package:flutter_testsmith/protocol.dart';

import 'channel/sdk_channel.dart';
import 'config.dart';
import 'gating.dart';
import 'session/test_session.dart';

/// The armed-or-not state of the SDK inside one application run.
///
/// Deliberately a plain object rather than a static singleton: the gating
/// rules are the most safety-critical logic here, and they are worth being
/// able to test directly, repeatedly, with no global state to reset.
class TestSdkRuntime {
  TestSdkRuntime._({required this.decision, required this.session});

  final ArmDecision decision;

  /// Null unless [decision] is [ArmDecision.armed].
  final TestSession? session;

  bool get isArmed => session != null;

  /// Applies the gating rules and, if they permit it, opens a session.
  ///
  /// The channel is created lazily through [channelFactory] so that a
  /// refusal to arm constructs no channel at all - no service extension is
  /// registered, and nothing about the application is observable from
  /// outside the process.
  static TestSdkRuntime start({
    required TestSdkConfig config,
    required AppContext Function() describeApp,
    required String appId,
    required String sdkVersion,
    required bool isReleaseMode,
    required SdkChannel Function() channelFactory,
    UiTreeCapture? captureUiTree,
    SettleProbe? probeSettle,
    SurfaceCaptureFn? captureSurface,
  }) {
    // Validate before deciding, so a misconfiguration is reported as such
    // rather than silently presenting as "not armed".
    config.validate();

    final decision = decideArming(
      configEnabled: config.enabled,
      isReleaseMode: isReleaseMode,
      allowInRelease: config.allowInRelease,
    );

    if (!decision.isArmed) {
      return TestSdkRuntime._(decision: decision, session: null);
    }

    final session = TestSession(
      config: config,
      channel: channelFactory(),
      describeApp: describeApp,
      appId: appId,
      sdkVersion: sdkVersion,
      captureUiTree: captureUiTree,
      probeSettle: probeSettle,
      captureSurface: captureSurface,
    )..start();

    return TestSdkRuntime._(decision: decision, session: session);
  }

  Future<void> stop(
    SessionEndReason reason, {
    String? detail,
  }) async {
    await session?.stop(reason, detail: detail);
  }
}
