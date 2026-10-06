// Not understanding an event was reported as nothing having happened.
//
// The engine's event boundary had two silent exits: an event carrying no
// data returned early, and an event that failed to decode was pushed
// onto the stream as an error, which the session logged as
// "! malformed event" and carried on past. Either way the run continued,
// making deterministic assertions from a stream it had stopped reading
// properly. An unread event and an absent event are indistinguishable
// from the far end, and only one of them means the application did
// nothing.
//
// Failing closed on *everything* unrecognised would be the opposite
// mistake. Two kinds of "we do not know this" are genuinely different:
//
//   * a peer on an incompatible **major** version, or a known event whose
//     payload is wrong - the engine cannot read what it was sent, and
//     must say so;
//   * a peer on a compatible major emitting an event **type** this build
//     has never heard of - which is what a minor version addition looks
//     like, and is exactly the case `ProtocolVersion` exists to permit.
//
// Refusing the second would break a legitimately compatible newer SDK.
import 'package:test/test.dart';
import 'package:flutter_testsmith/protocol.dart';

Map<String, Object?> event({
  String? protocolVersion = '1.0',
  String? type = 'SCREEN_ENTER',
  Object? payload = const {'screenId': '/home'},
  bool withApp = true,
  bool withEventId = true,
}) =>
    {
      'protocolVersion': ?protocolVersion,
      'event': ?type,
      if (withEventId) 'eventId': 'e1',
      'timestamp': '2026-09-16T00:00:00.000Z',
      'sessionId': 's1',
      if (withApp)
        'app': const {
          'appVersion': '1.0.0',
          'buildMode': 'debug',
          'environment': 'test',
          'platform': 'android',
          'devicePixelRatio': 2.0,
        },
      'payload': ?payload,
    };

void main() {
  group('an event the engine understands is decoded', () {
    test('a well-formed event comes back as one', () {
      final decoded = decodeTestEvent(event());

      expect(decoded, isA<DecodedEvent>());
      expect((decoded as DecodedEvent).event.type, EventType.screenEnter);
    });

    test('its payload survives', () {
      final decoded = decodeTestEvent(event()) as DecodedEvent;
      final payload = decoded.event.payload as ScreenEnterPayload;

      expect(payload.screenId, '/home');
    });
  });

  group('a compatible peer emitting something newer is ignored', () {
    test('an unknown event type is not a failure', () {
      // The forward-compatibility case. Same major version, a type added
      // in a later minor. Refusing it would make every SDK upgrade a
      // breaking change.
      final decoded = decodeTestEvent(event(type: 'SOMETHING_NEWER'));

      expect(decoded, isA<IgnoredEvent>());
    });

    test('the reason names the type, so it is discoverable', () {
      final decoded =
          decodeTestEvent(event(type: 'SOMETHING_NEWER')) as IgnoredEvent;

      expect(decoded.reason, contains('SOMETHING_NEWER'));
    });

    test('an unknown type is ignored even with an unreadable payload', () {
      // We cannot judge the payload of an event we do not know. The type
      // decides, and nothing further is attempted.
      final decoded = decodeTestEvent(
        event(type: 'SOMETHING_NEWER', payload: 'not a map'),
      );

      expect(decoded, isA<IgnoredEvent>());
    });
  });

  group('an event the engine cannot read is a failure, not a silence', () {
    test('an incompatible major version', () {
      final decoded = decodeTestEvent(event(protocolVersion: '2.0'));

      expect(decoded, isA<UndecodableEvent>());
      expect((decoded as UndecodableEvent).error,
          isA<ProtocolVersionMismatch>());
    });

    test('a missing protocol version', () {
      expect(
        decodeTestEvent(event(protocolVersion: null)),
        isA<UndecodableEvent>(),
      );
    });

    test('an unparseable protocol version', () {
      expect(
        decodeTestEvent(event(protocolVersion: 'one')),
        isA<UndecodableEvent>(),
      );
    });

    test('a missing event type', () {
      expect(decodeTestEvent(event(type: null)), isA<UndecodableEvent>());
    });

    test('a known event with a malformed payload', () {
      // SCREEN_ENTER requires a screenId. This is the case that must not
      // be confused with the forward-compatible one above: the engine
      // knows this event and cannot read it.
      expect(
        decodeTestEvent(event(payload: const {'wrong': 'field'})),
        isA<UndecodableEvent>(),
      );
    });

    test('a known event with no payload at all', () {
      expect(decodeTestEvent(event(payload: null)), isA<UndecodableEvent>());
    });

    test('a missing envelope field', () {
      expect(
        decodeTestEvent(event(withEventId: false)),
        isA<UndecodableEvent>(),
      );
      expect(decodeTestEvent(event(withApp: false)), isA<UndecodableEvent>());
    });

    test('the failure carries the cause rather than a bare flag', () {
      final decoded =
          decodeTestEvent(event(payload: const {})) as UndecodableEvent;

      expect(decoded.describe, isNotEmpty);
      expect(decoded.error, isNotNull);
    });
  });

  group('version is judged before type', () {
    test('an incompatible peer is a failure even for an unknown type', () {
      // Otherwise a peer two majors ahead would look like harmless
      // forward compatibility, and every one of its events would be
      // quietly dropped.
      final decoded = decodeTestEvent(
        event(protocolVersion: '2.0', type: 'SOMETHING_NEWER'),
      );

      expect(decoded, isA<UndecodableEvent>());
    });

    test('a compatible minor difference is still decoded', () {
      expect(
        decodeTestEvent(event(protocolVersion: '1.7')),
        isA<DecodedEvent>(),
      );
    });
  });
}
