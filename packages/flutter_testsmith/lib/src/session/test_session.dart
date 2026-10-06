import 'package:flutter_testsmith/protocol.dart';

import '../buffer/event_ring_buffer.dart';
import '../capture/network_capture.dart';
import '../channel/sdk_channel.dart';
import '../config.dart';
import '../identity/event_id.dart';
import '../inspection/settle.dart';

/// RPC names, all namespaced so they cannot collide with Flutter's own
/// service extensions.
abstract final class TestRpc {
  static const String handshake = 'ext.mytest.handshake';
  static const String ping = 'ext.mytest.ping';
  static const String sessionInfo = 'ext.mytest.sessionInfo';
  static const String uiTree = 'ext.mytest.uiTree';
  static const String settle = 'ext.mytest.settle';
  static const String screenshot = 'ext.mytest.screenshot';
}

/// Captures the UI tree for [screenId].
///
/// Injected rather than built in, so the session has no dependency on a
/// live Flutter binding and stays unit testable.
typedef UiTreeCapture = UiSnapshot Function(String screenId);

/// Reports whether the UI has stopped changing.
///
/// Injected for the same reason as the tree capture: it needs a live
/// Flutter binding, and the session should not.
typedef SettleProbe = SettleState Function(int inFlightRequests);

/// Rasterises the Flutter surface, as the RPC's JSON reply.
///
/// Injected for the same reason as the tree capture and the settle
/// probe: it needs a live Flutter binding and a painted frame, and the
/// session should need neither to be testable.
///
/// Typed as raw JSON rather than as `SurfaceCapture` from the capture
/// library, so this file keeps its independence from Flutter.
typedef SurfaceCaptureFn = Future<Map<String, Object?>> Function();

/// Owns the lifetime of one test session inside the application.
///
/// Every event goes to two places: the channel, for an engine that is
/// already attached, and the ring buffer, for one that is not yet. See
/// ARCHITECTURE 8.1.
///
/// The clock and id generator are injected so that session behaviour is
/// deterministic under test.
class TestSession {
  TestSession({
    required this.config,
    required this._channel,
    required this._describeApp,
    required this.appId,
    required this.sdkVersion,
    String? sessionId,
    this.captureUiTree,
    this.probeSettle,
    this.captureSurface,
    String Function()? generateId,
    DateTime Function()? clock,
    MonotonicMicros? monotonicMicros,
  })  : _generateId = generateId ?? generateUuidV4,
        _clock = clock ?? DateTime.now,
        sessionId = sessionId ?? generateUuidV4(),
        _buffer = EventRingBuffer<TestEvent>(
          capacity: config.eventBufferSize,
        ) {
    // Capture emits payloads; the session turns them into events so they
    // carry the current screen and land in the buffered history like
    // everything else.
    //
    // The wall clock stamps events; durations come from the capture's own
    // monotonic source, never from the difference of two of those stamps.
    network = NetworkCapture(
      config: config,
      emit: emit,
      monotonicMicros: monotonicMicros,
    );
  }

  /// Records HTTP traffic. Also the surface an application uses to wire
  /// up a client the SDK does not intercept on its own.
  late final NetworkCapture network;

  final TestSdkConfig config;
  final String appId;
  final String sdkVersion;
  final String sessionId;

  /// Null when UI inspection is not available in this build.
  final UiTreeCapture? captureUiTree;

  /// Null when no Flutter binding is available to measure against.
  final SettleProbe? probeSettle;

  /// Null when this build cannot rasterise its own surface.
  final SurfaceCaptureFn? captureSurface;

  final SdkChannel _channel;

  /// Resolved on every use rather than captured once.
  ///
  /// On a real device `TestSdk.initialize` runs before the view is laid
  /// out, so a frozen context records devicePixelRatio 1.0 regardless of
  /// the true ratio. Every logical-to-physical coordinate conversion
  /// depends on that number being current. See ADR-0006 and risk R3.
  final AppContext Function() _describeApp;
  final String Function() _generateId;
  final DateTime Function() _clock;
  final EventRingBuffer<TestEvent> _buffer;

  String? _currentScreenId;

  /// The screen the application is on, or null before the first navigation.
  String? get currentScreenId => _currentScreenId;

  /// The application's current context, re-read on each access.
  AppContext get app => _describeApp();

  /// The retained startup history. Non-consuming.
  List<TestEvent> get bufferedEvents => _buffer.snapshot();

  /// Builds an event around [payload] and delivers it.
  void emit(
    EventPayload payload, {
    String? screenId,
    Map<String, Object?> metadata = const {},
  }) {
    final event = TestEvent(
      eventId: _generateId(),
      timestamp: _clock(),
      sessionId: sessionId,
      screenId: screenId ?? _currentScreenId,
      app: _describeApp(),
      metadata: metadata,
      payload: payload,
    );
    _buffer.add(event);
    _channel.emit(event);
  }

  void enterScreen(ScreenEnterPayload payload) {
    _currentScreenId = payload.screenId;
    emit(payload, screenId: payload.screenId);
  }

  void exitScreen(ScreenExitPayload payload) {
    emit(payload, screenId: payload.screenId);
    _currentScreenId = payload.nextScreenId;
  }

  /// Whether this session can actually serve a UI tree.
  ///
  /// Config alone is not enough: inspection also needs a capture function,
  /// and advertising a capability that would then fail is worse than not
  /// advertising it.
  bool get canCaptureUiTree =>
      config.enableUiInspection && captureUiTree != null;

  /// Whether this session can rasterise its own surface.
  ///
  /// Same reasoning as [canCaptureUiTree]: advertising a capability that
  /// would then fail is worse than not advertising it.
  bool get canCaptureSurface => captureSurface != null;

  Set<String> get _capabilities => {
        for (final capability in config.capabilities)
          if (capability != 'uiTree' || canCaptureUiTree) capability,
        if (canCaptureSurface) 'screenshot',
      };

  /// Captures the current screen's UI tree.
  ///
  /// Pull-based: nothing is captured until the engine asks. The capture is
  /// also emitted as an event so it lands in the session history and can
  /// be correlated with the screen it belongs to. See ARCHITECTURE 14.
  UiSnapshot captureTree() {
    final capture = captureUiTree;
    if (capture == null) {
      throw StateError(
        'UI inspection is not available. Enable it with '
        'TestSdkConfig(enableUiInspection: true) and initialise the SDK '
        'through TestSdk.initialize so a capture function is installed.',
      );
    }

    final snapshot = capture(_currentScreenId ?? 'unknown');
    emit(WidgetTreePayload(snapshot: snapshot));
    return snapshot;
  }

  /// Answers an engine handshake, handing back the buffered startup history.
  HandshakeResponse handshake(HandshakeRequest request) {
    return HandshakeResponse(
      sessionId: sessionId,
      app: _describeApp(),
      capabilities: _capabilities,
      bufferedEvents: _buffer.snapshot(),
      droppedEventCount: _buffer.droppedCount,
    );
  }

  /// Registers the RPCs and announces the session.
  void start() {
    _registerRpcs();
    emit(
      SessionStartPayload(
        sdkVersion: sdkVersion,
        appId: appId,
        capabilities: _capabilities,
      ),
    );
  }

  Future<void> stop(SessionEndReason reason, {String? detail}) async {
    emit(SessionEndPayload(reason: reason, detail: detail));
    await _channel.close();
  }

  void _registerRpcs() {
    _channel.handle(TestRpc.handshake, (params) async {
      // Parsing here is what enforces version compatibility on every
      // attach, not merely the first.
      final request = HandshakeRequest.fromJson(params);
      return handshake(request).toJson();
    });

    _channel.handle(TestRpc.uiTree, (params) async {
      return {'snapshot': captureTree().toJson()};
    });

    _channel.handle(TestRpc.screenshot, (params) async {
      final capture = captureSurface;
      if (capture == null) {
        throw StateError(
          'Surface capture is not available in this build. Initialise '
          'through TestSdk.initialize so a capture function is installed.',
        );
      }
      final result = await capture();

      // Emitted as an event too, so the capture lands in the session
      // history and correlates with the screen it belongs to - exactly
      // as the UI tree does. Metadata only: a base64 PNG inside every
      // event would bloat the history for no benefit.
      emit(
        ScreenshotPayload(
          source: ScreenshotSource.repaintBoundary,
          width: (result['width']! as num).toInt(),
          height: (result['height']! as num).toInt(),
          byteLength: (result['byteLength']! as num).toInt(),
        ),
      );
      return result;
    });

    _channel.handle(TestRpc.settle, (params) async {
      final probe = probeSettle;
      if (probe == null) {
        throw StateError(
          'Settle detection is unavailable: the SDK was constructed '
          'without a probe. Initialise through TestSdk.initialize.',
        );
      }
      // The network capture is the only thing that knows what is still
      // outstanding, so the count comes from here rather than the probe.
      return probe(network.inFlightCount).toJson();
    });

    _channel.handle(TestRpc.ping, (params) async => {
          'pong': true,
          'sessionId': sessionId,
        });

    _channel.handle(TestRpc.sessionInfo, (params) async => {
          'sessionId': sessionId,
          'appId': appId,
          'sdkVersion': sdkVersion,
          'currentScreenId': _currentScreenId,
          'app': _describeApp().toJson(),
          'capabilities': _capabilities.toList(),
          'bufferedEventCount': _buffer.length,
          'droppedEventCount': _buffer.droppedCount,
        });
  }
}
