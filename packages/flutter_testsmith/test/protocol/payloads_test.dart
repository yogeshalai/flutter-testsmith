import 'package:test/test.dart';
import 'package:flutter_testsmith/protocol.dart';

/// Round-trips a payload through the wire form the envelope would use.
EventPayload roundTrip(EventPayload payload) =>
    EventPayload.fromJson(payload.type, payload.toJson());

void main() {
  group('SessionStartPayload', () {
    test('round-trips through JSON', () {
      const payload = SessionStartPayload(
        sdkVersion: '0.1.0',
        appId: 'com.example.shop',
        capabilities: {'navigation', 'uiTree'},
      );

      expect(roundTrip(payload), payload);
    });

    test('reports its event type', () {
      expect(
        const SessionStartPayload(sdkVersion: '0.1.0', appId: 'a').type,
        EventType.sessionStart,
      );
    });

    test('defaults to no capabilities', () {
      const payload = SessionStartPayload(sdkVersion: '0.1.0', appId: 'a');
      expect(payload.capabilities, isEmpty);
    });
  });

  group('SessionEndPayload', () {
    test('round-trips a normal completion', () {
      const payload = SessionEndPayload(reason: SessionEndReason.completed);
      expect(roundTrip(payload), payload);
    });

    test('round-trips an error with its detail preserved', () {
      const payload = SessionEndPayload(
        reason: SessionEndReason.error,
        detail: 'transport closed unexpectedly',
      );

      final restored = roundTrip(payload) as SessionEndPayload;
      expect(restored.reason, SessionEndReason.error);
      expect(restored.detail, 'transport closed unexpectedly');
    });
  });

  group('ScreenExitPayload', () {
    test('round-trips through JSON', () {
      const payload = ScreenExitPayload(
        screenId: 'ProductDetails',
        nextScreenId: 'Cart',
      );

      expect(roundTrip(payload), payload);
    });

    test('allows a null next screen when leaving the last screen', () {
      const payload = ScreenExitPayload(screenId: 'Home');
      expect((roundTrip(payload) as ScreenExitPayload).nextScreenId, isNull);
    });
  });

  group('AppLogPayload', () {
    test('round-trips through JSON', () {
      const payload = AppLogPayload(
        level: LogLevel.warning,
        message: 'cart total recalculated',
        loggerName: 'CartBloc',
      );

      expect(roundTrip(payload), payload);
    });

    test('preserves a stack trace when present', () {
      const payload = AppLogPayload(
        level: LogLevel.error,
        message: 'boom',
        stackTrace: '#0 main (file:///a.dart:1:1)',
      );

      final restored = roundTrip(payload) as AppLogPayload;
      expect(restored.stackTrace, contains('main'));
    });
  });

  group('HeartbeatPayload', () {
    test('round-trips through JSON', () {
      const payload = HeartbeatPayload(sequence: 7);
      expect(roundTrip(payload), payload);
    });
  });

  group('event catalogue', () {
    test('every event type has a wire name that is unique', () {
      final wires = EventType.values.map((t) => t.wire).toList();
      expect(wires.toSet().length, wires.length);
    });

    test('every event type can be decoded from its own wire name', () {
      for (final type in EventType.values) {
        expect(EventType.fromWire(type.wire), type);
      }
    });

    test('the six Phase 1 event types are present', () {
      expect(
        EventType.values.map((t) => t.wire).toSet(),
        containsAll(<String>[
          'SESSION_START',
          'SESSION_END',
          'SCREEN_ENTER',
          'SCREEN_EXIT',
          'APP_LOG',
          'HEARTBEAT',
        ]),
      );
    });
  });
}
