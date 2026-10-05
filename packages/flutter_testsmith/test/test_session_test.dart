import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import 'support/fake_sdk_channel.dart';

const AppContext app = AppContext(
  appVersion: '1.2.3',
  buildMode: BuildMode.debug,
  environment: 'test',
  platform: 'android',
  devicePixelRatio: 1.875,
);

/// A session with a fixed clock and predictable ids, so assertions are exact.
({TestSession session, FakeSdkChannel channel}) makeSession({
  TestSdkConfig config = const TestSdkConfig(enabled: true),
  DateTime? now,
}) {
  final channel = FakeSdkChannel();
  var counter = 0;
  var clock = now ?? DateTime.utc(2026, 9, 10, 12);
  final session = TestSession(
    config: config,
    channel: channel,
    describeApp: () => app,
    appId: 'com.example.shop',
    sdkVersion: '0.1.0',
    generateId: () => 'id-${++counter}',
    clock: () => clock = clock.add(const Duration(milliseconds: 1)),
  );
  return (session: session, channel: channel);
}

void main() {
  _appContextIsResolvedPerUse();
  _captureIsPullBased();
  group('TestSession.emit', () {
    test('stamps the session id, generated event id and clock time', () {
      final (:session, :channel) = makeSession();

      session.emit(const HeartbeatPayload(sequence: 1));

      final event = channel.emitted.single;
      expect(event.sessionId, session.sessionId);
      expect(event.eventId, 'id-1');
      expect(event.timestamp, DateTime.utc(2026, 9, 10, 12, 0, 0, 1));
      expect(event.app, app);
    });

    test('gives every event a distinct id', () {
      final (:session, :channel) = makeSession();

      session
        ..emit(const HeartbeatPayload(sequence: 1))
        ..emit(const HeartbeatPayload(sequence: 2));

      expect(channel.emitted.map((TestEvent e) => e.eventId), ['id-1', 'id-2']);
    });

    test('records the event in the startup buffer as well as sending it', () {
      // Both paths matter: the send covers an attached engine, the buffer
      // covers one that has not attached yet.
      final (:session, :channel) = makeSession();

      session.emit(const HeartbeatPayload(sequence: 1));

      expect(channel.emitted, hasLength(1));
      expect(session.bufferedEvents, hasLength(1));
      expect(session.bufferedEvents.single.eventId, 'id-1');
    });

    test('attaches the current screen to events emitted while on it', () {
      final (:session, :channel) = makeSession();

      session
        ..enterScreen(const ScreenEnterPayload(screenId: 'ProductDetails'))
        ..emit(const HeartbeatPayload(sequence: 1));

      expect(channel.emitted.last.screenId, 'ProductDetails');
    });

    test('carries caller metadata onto the event', () {
      final (:session, :channel) = makeSession();

      session.emit(
        const HeartbeatPayload(sequence: 1),
        metadata: const {'reason': 'probe'},
      );

      expect(channel.emitted.single.metadata, {'reason': 'probe'});
    });
  });

  group('screen tracking', () {
    test('tracks the current screen across entry and exit', () {
      final (:session, :channel) = makeSession();

      expect(session.currentScreenId, isNull);

      session.enterScreen(const ScreenEnterPayload(screenId: 'Home'));
      expect(session.currentScreenId, 'Home');

      session.exitScreen(
        const ScreenExitPayload(screenId: 'Home', nextScreenId: 'Cart'),
      );
      expect(session.currentScreenId, 'Cart');
    });

    test('clears the current screen when leaving the last screen', () {
      final session = makeSession().session
        ..enterScreen(const ScreenEnterPayload(screenId: 'Home'));

      session.exitScreen(const ScreenExitPayload(screenId: 'Home'));

      expect(session.currentScreenId, isNull);
    });

    test('emits screen entry and exit as events', () {
      final (:session, :channel) = makeSession();

      session
        ..enterScreen(const ScreenEnterPayload(screenId: 'Home'))
        ..exitScreen(const ScreenExitPayload(screenId: 'Home'));

      expect(
        channel.emitted.map((TestEvent e) => e.type),
        [EventType.screenEnter, EventType.screenExit],
      );
    });
  });

  group('handshake', () {
    test('returns the buffered startup history', () {
      final session = makeSession().session
        ..emit(const HeartbeatPayload(sequence: 1))
        ..enterScreen(const ScreenEnterPayload(screenId: 'Home'));

      final response = session.handshake(
        const HandshakeRequest(engineVersion: '0.1.0'),
      );

      expect(response.sessionId, session.sessionId);
      expect(response.bufferedEvents.map((TestEvent e) => e.eventId),
          ['id-1', 'id-2']);
      expect(response.historyIsComplete, isTrue);
      expect(response.app, app);
    });

    test('advertises the configured capabilities', () {
      final session = makeSession(
        config: const TestSdkConfig(
          enabled: true,
          enableNavigationTracking: true,
          enableUiInspection: false,
          enableNetworkCapture: false,
        ),
      ).session;

      final response = session.handshake(
        const HandshakeRequest(engineVersion: '0.1.0'),
      );

      expect(response.capabilities, {'navigation'});
    });

    test('reports a truncated history when the buffer overflowed', () {
      final session = makeSession(
        config: const TestSdkConfig(enabled: true, eventBufferSize: 2),
      ).session;

      for (var i = 0; i < 5; i++) {
        session.emit(HeartbeatPayload(sequence: i));
      }

      final response = session.handshake(
        const HandshakeRequest(engineVersion: '0.1.0'),
      );

      expect(response.bufferedEvents, hasLength(2));
      expect(response.droppedEventCount, 3);
      expect(response.historyIsComplete, isFalse);
    });

    test('does not consume the buffer, so a reattach still sees history', () {
      final session = makeSession().session
        ..emit(const HeartbeatPayload(sequence: 1));

      const request = HandshakeRequest(engineVersion: '0.1.0');
      final first = session.handshake(request);
      final second = session.handshake(request);

      expect(first.bufferedEvents, hasLength(1));
      expect(second.bufferedEvents, hasLength(1));
    });
  });

  group('session lifecycle', () {
    test('emits SESSION_START when started', () {
      final (:session, :channel) = makeSession();

      session.start();

      final event = channel.emitted.single;
      expect(event.type, EventType.sessionStart);
      final payload = event.payload as SessionStartPayload;
      expect(payload.appId, 'com.example.shop');
      expect(payload.sdkVersion, '0.1.0');
      expect(payload.capabilities, containsAll(<String>['navigation']));
    });

    test('emits SESSION_END with the given reason when stopped', () async {
      final (:session, :channel) = makeSession();

      await session.stop(SessionEndReason.completed);

      final event = channel.emitted.last;
      expect(event.type, EventType.sessionEnd);
      expect(
        (event.payload as SessionEndPayload).reason,
        SessionEndReason.completed,
      );
    });

    test('closes the channel when stopped', () async {
      final (:session, :channel) = makeSession();

      await session.stop(SessionEndReason.completed);

      expect(channel.closed, isTrue);
    });

    test('registers the Phase 1 RPCs on start', () {
      final (:session, :channel) = makeSession();

      session.start();

      expect(
        channel.handlers.keys,
        containsAll(<String>[
          'ext.mytest.handshake',
          'ext.mytest.ping',
          'ext.mytest.sessionInfo',
        ]),
      );
    });

    test('answers ping', () async {
      final (:session, :channel) = makeSession();
      session.start();

      final result = await channel.invoke('ext.mytest.ping');

      expect(result['pong'], isTrue);
      expect(result['sessionId'], session.sessionId);
    });

    test('serves the handshake over the channel', () async {
      final (:session, :channel) = makeSession();
      session.start();

      final result = await channel.invoke('ext.mytest.handshake', {
        'protocolVersion': ProtocolVersion.current.value,
        'engineVersion': '0.1.0',
      });

      expect(result['sessionId'], session.sessionId);
      expect(result['bufferedEvents'], isA<List<Object?>>());
    });

    test('rejects a handshake from an incompatible engine', () async {
      final (:session, :channel) = makeSession();
      session.start();

      await expectLater(
        channel.invoke('ext.mytest.handshake', {
          'protocolVersion': '2.0',
          'engineVersion': '0.1.0',
        }),
        throwsA(isA<ProtocolVersionMismatch>()),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Regression: on the real device, TestSdk.initialize ran before the view was
// sized, so a frozen AppContext captured devicePixelRatio 1.0 on a 1.875
// device. Every logical-to-physical coordinate conversion would have been
// wrong by 47%. App context is therefore resolved per use, not once.
// ---------------------------------------------------------------------------
void _appContextIsResolvedPerUse() {
  group('app context freshness', () {
    test('resolves the app context at emit time, not at construction', () {
      final channel = FakeSdkChannel();
      var dpr = 1.0; // what an unsized view reports
      final session = TestSession(
        config: const TestSdkConfig(enabled: true),
        channel: channel,
        describeApp: () => AppContext(
          appVersion: '1.0.0',
          buildMode: BuildMode.debug,
          environment: 'test',
          platform: 'android',
          devicePixelRatio: dpr,
        ),
        appId: 'com.example.shop',
        sdkVersion: '0.1.0',
      );

      session.emit(const HeartbeatPayload(sequence: 1));
      dpr = 1.875; // the view is now laid out and reports the truth
      session.emit(const HeartbeatPayload(sequence: 2));

      expect(channel.emitted.first.app.devicePixelRatio, 1.0);
      expect(channel.emitted.last.app.devicePixelRatio, 1.875);
    });

    test('resolves the app context at handshake time', () {
      final channel = FakeSdkChannel();
      var dpr = 1.0;
      final session = TestSession(
        config: const TestSdkConfig(enabled: true),
        channel: channel,
        describeApp: () => AppContext(
          appVersion: '1.0.0',
          buildMode: BuildMode.debug,
          environment: 'test',
          platform: 'android',
          devicePixelRatio: dpr,
        ),
        appId: 'com.example.shop',
        sdkVersion: '0.1.0',
      );

      dpr = 1.875;
      final response =
          session.handshake(const HandshakeRequest(engineVersion: '0.1.0'));

      // The engine converts coordinates using this value, so it must be
      // current rather than whatever was true at startup.
      expect(response.app.devicePixelRatio, 1.875);
    });
  });
}

// ---------------------------------------------------------------------------
// Phase 2: capture is pull-based. The engine asks; the app never streams a
// tree per frame. The capture itself is injected so the session stays
// testable without a Flutter binding.
// ---------------------------------------------------------------------------
UiSnapshot _snapshot(String screenId) => UiSnapshot(
      screenId: screenId,
      capturedAt: DateTime.utc(2026, 9, 10, 12),
      devicePixelRatio: 1.875,
      root: const UiNode(
        testId: 'product.card',
        type: 'Card',
        bounds: LogicalRect(x: 0, y: 0, width: 100, height: 50),
      ),
    );

void _captureIsPullBased() {
  group('ui tree capture', () {
    test('serves the tree over an RPC', () async {
      final channel = FakeSdkChannel();
      TestSession(
        config: const TestSdkConfig(enabled: true),
        channel: channel,
        describeApp: () => app,
        appId: 'com.example.shop',
        sdkVersion: '0.1.0',
        captureUiTree: _snapshot,
      ).start();

      final result = await channel.invoke('ext.mytest.uiTree');

      final snapshot = UiSnapshot.fromJson(
        (result['snapshot']! as Map<Object?, Object?>).cast(),
      );
      expect(snapshot.find('product.card'), isNotNull);
      expect(snapshot.devicePixelRatio, 1.875);
    });

    test('also records the capture as an event, for correlation', () async {
      // The engine asks for the tree, but the session history should show
      // that a capture happened on this screen.
      final channel = FakeSdkChannel();
      final session = TestSession(
        config: const TestSdkConfig(enabled: true),
        channel: channel,
        describeApp: () => app,
        appId: 'com.example.shop',
        sdkVersion: '0.1.0',
        captureUiTree: _snapshot,
      )..start();
      session.enterScreen(const ScreenEnterPayload(screenId: 'Product'));

      await channel.invoke('ext.mytest.uiTree');

      expect(channel.emitted.last.type, EventType.widgetTree);
      expect(channel.emitted.last.screenId, 'Product');
    });

    test('captures for the current screen', () async {
      final channel = FakeSdkChannel();
      final session = TestSession(
        config: const TestSdkConfig(enabled: true),
        channel: channel,
        describeApp: () => app,
        appId: 'com.example.shop',
        sdkVersion: '0.1.0',
        captureUiTree: _snapshot,
      )..start();
      session.enterScreen(const ScreenEnterPayload(screenId: 'Cart'));

      final result = await channel.invoke('ext.mytest.uiTree');
      final snapshot = UiSnapshot.fromJson(
        (result['snapshot']! as Map<Object?, Object?>).cast(),
      );

      expect(snapshot.screenId, 'Cart');
    });

    test('reports a clear error when inspection is not configured', () async {
      // Better than returning an empty tree, which reads as "the screen
      // has nothing on it".
      final channel = FakeSdkChannel();
      TestSession(
        config: const TestSdkConfig(enabled: true, enableUiInspection: false),
        channel: channel,
        describeApp: () => app,
        appId: 'com.example.shop',
        sdkVersion: '0.1.0',
      ).start();

      await expectLater(
        channel.invoke('ext.mytest.uiTree'),
        throwsA(isA<StateError>()),
      );
    });

    test('does not advertise uiTree capability without a capture function',
        () {
      final channel = FakeSdkChannel();
      final session = TestSession(
        config: const TestSdkConfig(enabled: true, enableUiInspection: false),
        channel: channel,
        describeApp: () => app,
        appId: 'com.example.shop',
        sdkVersion: '0.1.0',
      );

      final response =
          session.handshake(const HandshakeRequest(engineVersion: '0.1.0'));

      expect(response.capabilities, isNot(contains('uiTree')));
    });
  });
}
