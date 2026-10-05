import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'capture/http_overrides_capture.dart';
import 'capture/surface_capture.dart';
import 'capture/network_capture.dart';
import 'channel/sdk_channel.dart';
import 'identity/device_pixel_ratio.dart';
import 'inspection/animation_inspector.dart';
import 'inspection/retention_policy.dart';
import 'inspection/settle.dart';
import 'inspection/ui_tree_inspector.dart';
import 'channel/vm_service_channel.dart';
import 'config.dart';
import 'gating.dart';
import 'navigation/test_navigator_observer.dart';
import 'runtime.dart';
import 'session/test_session.dart';

/// The version of this SDK, reported in the handshake.
const String kSdkVersion = '0.1.0';

/// The application-facing entry point.
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await TestSdk.initialize(
///     appId: 'com.example.shop',
///     config: TestSdkConfig(
///       enabled: const bool.fromEnvironment('TEST_MODE'),
///     ),
///   );
///   runApp(MyApp());
/// }
/// ```
///
/// Passing a `const bool.fromEnvironment` constant is what allows the
/// tree-shaker to remove the instrumentation from a release build entirely.
/// See ARCHITECTURE 9.2.
abstract final class TestSdk {
  static TestSdkRuntime? _runtime;

  /// Whether instrumentation is active.
  static bool get isArmed => _runtime?.isArmed ?? false;

  /// Why instrumentation is or is not active.
  static ArmDecision get decision =>
      _runtime?.decision ?? ArmDecision.disabledByConfig;

  /// The live session, or null when not armed.
  static TestSession? get session => _runtime?.session;

  /// Records HTTP traffic, or null when not armed.
  ///
  /// Applications using a client the SDK does not intercept - a custom
  /// dio adapter, a native-side plugin - report through this directly:
  ///
  /// ```dart
  /// final id = TestSdk.network?.begin(method: 'GET', url: uri);
  /// TestSdk.network?.complete(id, statusCode: 200, body: body);
  /// ```
  static NetworkCapture? get network => _runtime?.session?.network;

  /// A navigator observer wired to the current session.
  ///
  /// Safe to attach unconditionally: when the SDK is not armed the observer
  /// is inert.
  static NavigatorObserver get navigatorObserver =>
      TestNavigatorObserver(session: session);

  static Future<void> initialize({
    required String appId,
    required TestSdkConfig config,
    String appVersion = 'unknown',
    Duration settleQuietPeriod = const Duration(milliseconds: 500),
    AppContext? appContext,
    SdkChannel Function()? channelFactory,
    UiRetentionPolicy retentionPolicy = const UiRetentionPolicy.defaults(),
  }) async {
    if (_runtime != null) {
      // Re-initialising would open a second session and duplicate every
      // event. Returning the existing one is safer than throwing, because
      // this can legitimately happen after a hot restart.
      debugPrint('[flutter_testsmith] already initialised; ignoring repeat call');
      return;
    }

    _runtime = TestSdkRuntime.start(
      config: config,
      describeApp: () => appContext ?? _describeApp(config, appVersion),
      appId: appId,
      sdkVersion: kSdkVersion,
      isReleaseMode: kReleaseMode,
      channelFactory: channelFactory ?? VmServiceChannel.new,
      captureUiTree: config.enableUiInspection
          ? (screenId) => _captureTree(screenId, retentionPolicy)
          : null,
      probeSettle: (inFlight) => _probeSettle(inFlight, settleQuietPeriod),
      captureSurface: config.enableScreenshots
          ? () async => (await captureSurface()).toJson()
          : null,
    );

    final capture = network;
    if (capture != null && config.enableNetworkCapture) {
      // Wraps any override the application already installed rather than
      // replacing it.
      HttpOverrides.global = CapturingHttpOverrides(
        capture,
        previous: HttpOverrides.current,
      );
    }

    if (isArmed) {
      // Every frame stamps the clock the quiet period is measured from.
      WidgetsBinding.instance.addPersistentFrameCallback((_) {
        _lastFrameAt = DateTime.now();
      });
    }

    if (isArmed && config.enableUiInspection) {
      // The inspector reads accessible labels and enabled state from the
      // semantics tree, which is only compiled while something is holding
      // a handle. Nothing else in a test run does.
      _semanticsHandle = SemanticsBinding.instance.ensureSemantics();
    }

    if (!isArmed) {
      debugPrint('[flutter_testsmith] not armed: ${decision.explanation}');
    }
  }

  static SemanticsHandle? _semanticsHandle;
  static DateTime _lastFrameAt = DateTime.now();

  static SettleState _probeSettle(int inFlight, Duration quietPeriod) {
    final binding = WidgetsBinding.instance;
    final root = binding.rootElement;

    // Which animations, not merely how many. A screen that animates for
    // ever can then declare the ones it expects instead of having the
    // settle requirement dropped wholesale. See STOP-2.
    //
    // Only attempted once there is a tree to walk; before the first
    // frame the count is the only thing there is to report.
    const inspector = AnimationInspector();
    final animations =
        root == null ? const <AnimationActivity>[] : inspector.inspect(root);

    return SettleState(
      sinceLastFrame: DateTime.now().difference(_lastFrameAt),
      inFlightRequests: inFlight,
      // Transient callbacks are Flutter's own count of running
      // animations, so this needs no bookkeeping of our own. Kept as
      // the authority: if it ever exceeds what the inventory can name,
      // the engine can see that it is being asked to reason about
      // something it cannot see.
      transientCallbacks: binding.transientCallbackCount,
      quietPeriod: quietPeriod,
      animations: animations,
      topRouteIndex: root == null ? null : inspector.topRouteIndex(root),
    );
  }

  static UiSnapshot _captureTree(String screenId, UiRetentionPolicy policy) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) {
      throw StateError(
        'No widget tree yet. Capture after runApp has produced a frame.',
      );
    }
    return UiTreeInspector(policy: policy).capture(
      root: root,
      screenId: screenId,
      devicePixelRatio: devicePixelRatio,
    );
  }

  static Future<void> shutdown([
    SessionEndReason reason = SessionEndReason.completed,
  ]) async {
    await _runtime?.stop(reason);
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
    _runtime = null;
  }

  /// The device pixel ratio as currently known, or 0 if it is not.
  ///
  /// Exposed so an application can show it on screen; a smoke run that
  /// mis-taps is otherwise very hard to diagnose.
  static double get devicePixelRatio {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    return resolveDevicePixelRatio(
      implicitViewRatio: dispatcher.implicitView?.devicePixelRatio,
      viewRatios: [for (final v in dispatcher.views) v.devicePixelRatio],
    );
  }

  static AppContext _describeApp(TestSdkConfig config, String appVersion) {
    return AppContext(
      appVersion: appVersion,
      buildMode: kReleaseMode
          ? BuildMode.release
          : kProfileMode
              ? BuildMode.profile
              : BuildMode.debug,
      environment: config.environment,
      platform: defaultTargetPlatform.name,
      // Reported here so the engine converts logical to physical pixels
      // exactly once, against a real value rather than an assumed one.
      // See ADR-0006.
      devicePixelRatio: devicePixelRatio,
    );
  }

  @visibleForTesting
  static void debugReset() => _runtime = null;
}
