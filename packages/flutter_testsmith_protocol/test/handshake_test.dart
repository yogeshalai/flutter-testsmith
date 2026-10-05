import 'package:test/test.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const AppContext testApp = AppContext(
  appVersion: '1.0.0',
  buildMode: BuildMode.debug,
  environment: 'test',
  platform: 'android',
  devicePixelRatio: 1.875,
);

TestEvent event(String id, EventPayload payload) => TestEvent(
      eventId: id,
      timestamp: DateTime.utc(2026, 9, 10, 8),
      sessionId: 'session-1',
      app: testApp,
      payload: payload,
    );

void main() {
  group('HandshakeRequest', () {
    test('round-trips through JSON', () {
      const request = HandshakeRequest(engineVersion: '0.1.0');

      final restored = HandshakeRequest.fromJson(request.toJson());

      expect(restored.engineVersion, '0.1.0');
      expect(restored.protocolVersion, ProtocolVersion.current);
    });

    test('advertises the current protocol version', () {
      expect(
        const HandshakeRequest(engineVersion: '0.1.0').toJson()['protocolVersion'],
        ProtocolVersion.current.value,
      );
    });

    test('rejects a peer speaking an incompatible major version', () {
      final json = const HandshakeRequest(engineVersion: '0.1.0').toJson()
        ..['protocolVersion'] = '2.0';

      expect(
        () => HandshakeRequest.fromJson(json),
        throwsA(isA<ProtocolVersionMismatch>()),
      );
    });
  });

  group('HandshakeResponse', () {
    test('round-trips including the drained buffered events', () {
      final response = HandshakeResponse(
        sessionId: 'session-1',
        app: testApp,
        capabilities: const {'navigation'},
        bufferedEvents: [
          event('e1', const SessionStartPayload(sdkVersion: '0.1.0', appId: 'a')),
          event('e2', const ScreenEnterPayload(screenId: 'Home')),
        ],
      );

      final restored = HandshakeResponse.fromJson(response.toJson());

      expect(restored.sessionId, 'session-1');
      expect(restored.app, testApp);
      expect(restored.capabilities, {'navigation'});
      expect(restored.bufferedEvents.map((e) => e.eventId), ['e1', 'e2']);
      expect(restored.bufferedEvents.first.type, EventType.sessionStart);
    });

    test('preserves buffered event order', () {
      final response = HandshakeResponse(
        sessionId: 's',
        app: testApp,
        bufferedEvents: [
          for (var i = 0; i < 20; i++)
            event('e$i', HeartbeatPayload(sequence: i)),
        ],
      );

      final restored = HandshakeResponse.fromJson(response.toJson());

      expect(
        restored.bufferedEvents.map((e) => e.eventId).toList(),
        [for (var i = 0; i < 20; i++) 'e$i'],
      );
    });

    test('reports no dropped events by default', () {
      final response = HandshakeResponse(sessionId: 's', app: testApp);

      expect(response.droppedEventCount, 0);
      expect(response.historyIsComplete, isTrue);
    });

    test('flags an incomplete history when the ring buffer overflowed', () {
      // The engine must be able to tell a complete history from a truncated
      // one, rather than assuming the drain returned everything.
      final response = HandshakeResponse(
        sessionId: 's',
        app: testApp,
        droppedEventCount: 12,
      );

      final restored = HandshakeResponse.fromJson(response.toJson());

      expect(restored.droppedEventCount, 12);
      expect(restored.historyIsComplete, isFalse);
    });

    test('rejects a peer speaking an incompatible major version', () {
      final json = HandshakeResponse(sessionId: 's', app: testApp).toJson()
        ..['protocolVersion'] = '3.1';

      expect(
        () => HandshakeResponse.fromJson(json),
        throwsA(
          isA<ProtocolVersionMismatch>()
              .having((e) => e.received.major, 'received.major', 3),
        ),
      );
    });
  });
}
