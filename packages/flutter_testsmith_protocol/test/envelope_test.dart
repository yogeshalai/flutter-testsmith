import 'package:test/test.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

TestEvent buildEvent({
  String eventId = 'evt-1',
  String? screenId = 'ProductDetails',
  Map<String, Object?> metadata = const {},
  EventPayload? payload,
}) {
  return TestEvent(
    eventId: eventId,
    timestamp: DateTime.utc(2026, 9, 10, 12, 30, 45, 123, 456),
    sessionId: 'session-1',
    screenId: screenId,
    app: const AppContext(
      appVersion: '1.2.3',
      buildMode: BuildMode.debug,
      environment: 'test',
      platform: 'android',
      devicePixelRatio: 1.875,
    ),
    metadata: metadata,
    payload: payload ??
        const ScreenEnterPayload(
          screenId: 'ProductDetails',
          routeName: '/product/123',
        ),
  );
}

void main() {
  group('TestEvent', () {
    test('round-trips through JSON preserving every envelope field', () {
      final original = buildEvent(metadata: const {'attempt': 2});

      final restored = TestEvent.fromJson(original.toJson());

      expect(restored.eventId, original.eventId);
      expect(restored.timestamp, original.timestamp);
      expect(restored.sessionId, original.sessionId);
      expect(restored.screenId, original.screenId);
      expect(restored.app, original.app);
      expect(restored.metadata, original.metadata);
      expect(restored.payload, original.payload);
    });

    test('stamps the current protocol version on serialization', () {
      expect(
        buildEvent().toJson()['protocolVersion'],
        ProtocolVersion.current.value,
      );
    });

    test('derives its type from the payload rather than storing it', () {
      // Deriving makes a type/payload mismatch unrepresentable.
      expect(buildEvent().type, EventType.screenEnter);
      expect(buildEvent().toJson()['event'], 'SCREEN_ENTER');
    });

    test('preserves microsecond precision through a round trip', () {
      final restored = TestEvent.fromJson(buildEvent().toJson());
      expect(restored.timestamp.microsecond, 456);
      expect(restored.timestamp.millisecond, 123);
    });

    test('serializes the timestamp as UTC', () {
      final json = buildEvent().toJson();
      expect(json['timestamp'], endsWith('Z'));
    });

    test('allows a null screenId for events with no screen', () {
      final restored = TestEvent.fromJson(buildEvent(screenId: null).toJson());
      expect(restored.screenId, isNull);
    });
  });

  group('TestEvent.fromJson rejects bad input', () {
    test('names the offending type when the event type is unknown', () {
      final json = buildEvent().toJson()..['event'] = 'NOT_A_REAL_EVENT';

      expect(
        () => TestEvent.fromJson(json),
        throwsA(
          isA<ProtocolFormatException>().having(
            (e) => e.message,
            'message',
            contains('NOT_A_REAL_EVENT'),
          ),
        ),
      );
    });

    test('rejects an incompatible major protocol version', () {
      final json = buildEvent().toJson()..['protocolVersion'] = '2.0';

      expect(
        () => TestEvent.fromJson(json),
        throwsA(
          isA<ProtocolVersionMismatch>()
              .having((e) => e.received.major, 'received.major', 2)
              .having((e) => e.expected, 'expected', ProtocolVersion.current),
        ),
      );
    });

    test('accepts a differing minor protocol version', () {
      final json = buildEvent().toJson()..['protocolVersion'] = '1.99';

      expect(TestEvent.fromJson(json).eventId, 'evt-1');
    });

    test('reports a missing required field by name', () {
      final json = buildEvent().toJson()..remove('sessionId');

      expect(
        () => TestEvent.fromJson(json),
        throwsA(
          isA<ProtocolFormatException>()
              .having((e) => e.message, 'message', contains('sessionId')),
        ),
      );
    });
  });

  group('AppContext', () {
    test('round-trips through JSON', () {
      const original = AppContext(
        appVersion: '9.9.9',
        buildMode: BuildMode.profile,
        environment: 'staging',
        platform: 'ios',
        devicePixelRatio: 3.0,
      );

      expect(AppContext.fromJson(original.toJson()), original);
    });
  });
}
