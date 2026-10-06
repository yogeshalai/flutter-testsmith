import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/protocol.dart';

/// The fixture files are the canonical wire format.
///
/// They are hand-written to express the contract independently of the Dart
/// implementation. The SDK and the engine both speak the wire format
/// through the one protocol component (lib/src/protocol), so a change to
/// it that breaks a fixture fails here, which is the primary defence
/// against protocol drift.
const List<String> fixtureNames = [
  'session_start',
  'session_end',
  'screen_enter',
  'screen_exit',
  'app_log',
  'heartbeat',
  'widget_tree',
  'screenshot',
  'api_request',
  'api_response',
];

Map<String, Object?> loadFixture(String name) {
  final file = File('test/protocol/fixtures/$name.json');
  if (!file.existsSync()) {
    fail('Missing fixture: ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  group('canonical fixtures', () {
    for (final name in fixtureNames) {
      test('$name decodes into a TestEvent', () {
        final event = TestEvent.fromJson(loadFixture(name));

        expect(event.eventId, isNotEmpty);
        expect(event.sessionId, isNotEmpty);
        expect(event.timestamp.isUtc, isTrue);
        expect(event.app.devicePixelRatio, 1.875);
      });

      test('$name re-encodes to exactly the fixture', () {
        final fixture = loadFixture(name);

        final reencoded = TestEvent.fromJson(fixture).toJson();

        // Deep equality: any accidental change to the wire format - a
        // renamed key, a dropped optional, a changed timestamp precision -
        // fails here.
        expect(reencoded, equals(fixture));
      });
    }

    test('every event type has a fixture pinning its wire format', () {
      final covered = <EventType>{
        for (final name in fixtureNames)
          TestEvent.fromJson(loadFixture(name)).type,
      };

      expect(covered, EventType.values.toSet());
    });
  });

  group('fixture contents', () {
    test('screen_enter carries route and previous screen', () {
      final event = TestEvent.fromJson(loadFixture('screen_enter'));
      final payload = event.payload as ScreenEnterPayload;

      expect(payload.screenId, 'ProductDetails');
      expect(payload.routeName, '/product/123');
      expect(payload.previousScreenId, 'ProductList');
      expect(event.metadata, {'trigger': 'tap'});
    });

    test('timestamps keep microsecond precision', () {
      final event = TestEvent.fromJson(loadFixture('screen_enter'));

      expect(event.timestamp.millisecond, 123);
      expect(event.timestamp.microsecond, 456);
    });
  });
}
