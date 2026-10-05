import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const AppContext app = AppContext(
  appVersion: '1.0.0',
  buildMode: BuildMode.debug,
  environment: 'test',
  platform: 'android',
  devicePixelRatio: 1.875,
);

/// [at] is seconds past a fixed origin, so ordering assertions read clearly.
TestEvent event(
  String id,
  EventPayload payload, {
  required int at,
  String? screenId,
}) =>
    TestEvent(
      eventId: id,
      timestamp: DateTime.utc(2026, 9, 10, 12, 0, at),
      sessionId: 'session-1',
      screenId: screenId,
      app: app,
      payload: payload,
    );

TestEvent enter(String id, String screen, {required int at}) =>
    event(id, ScreenEnterPayload(screenId: screen), at: at, screenId: screen);

TestEvent exit(String id, String screen, {String? next, required int at}) =>
    event(
      id,
      ScreenExitPayload(screenId: screen, nextScreenId: next),
      at: at,
      screenId: screen,
    );

void main() {
  group('deduplication', () {
    test('keeps only the first copy of a repeated event id', () {
      // DDS replay and the handshake drain both deliver the events emitted
      // before attach, so every startup event arrives twice. See R2b.
      final manager = SessionManager()
        ..ingest(enter('e1', 'Home', at: 1))
        ..ingest(enter('e1', 'Home', at: 1));

      expect(manager.events, hasLength(1));
      expect(manager.duplicateCount, 1);
    });

    test('counts duplicates without discarding distinct events', () {
      final manager = SessionManager()
        ..ingestAll([
          enter('e1', 'Home', at: 1),
          enter('e2', 'Cart', at: 2),
        ])
        ..ingestAll([
          enter('e1', 'Home', at: 1),
          enter('e2', 'Cart', at: 2),
        ]);

      expect(manager.events.map((TestEvent e) => e.eventId), ['e1', 'e2']);
      expect(manager.duplicateCount, 2);
    });

    test('reports no duplicates for a clean stream', () {
      final manager = SessionManager()
        ..ingestAll([
          enter('e1', 'Home', at: 1),
          enter('e2', 'Cart', at: 2),
        ]);

      expect(manager.duplicateCount, 0);
    });
  });

  group('ordering', () {
    test('orders chronologically, not by arrival', () {
      // The case that forces this: DDS replay is capped, so the live stream
      // can deliver later events before the handshake drain supplies the
      // earlier ones it dropped. Arrival order would put them backwards.
      final manager = SessionManager()
        ..ingestAll([
          enter('e3', 'Cart', at: 3),
          enter('e4', 'Checkout', at: 4),
        ])
        ..ingestAll([
          enter('e1', 'Home', at: 1),
          enter('e2', 'ProductList', at: 2),
        ]);

      expect(
        manager.events.map((TestEvent e) => e.eventId),
        ['e1', 'e2', 'e3', 'e4'],
      );
    });

    test('breaks a timestamp tie by arrival order', () {
      final manager = SessionManager()
        ..ingest(enter('second', 'B', at: 1))
        ..ingest(enter('first', 'A', at: 1));

      expect(
        manager.events.map((TestEvent e) => e.eventId),
        ['second', 'first'],
      );
    });

    test('merges a handshake drain with a live stream correctly', () {
      final manager = SessionManager()
        // Live stream, partially replayed by DDS.
        ..ingestAll([
          enter('e2', 'ProductList', at: 2),
          enter('e3', 'Cart', at: 3),
        ])
        // Handshake drain: the full history, overlapping the above.
        ..ingestAll([
          enter('e1', 'Home', at: 1),
          enter('e2', 'ProductList', at: 2),
          enter('e3', 'Cart', at: 3),
        ]);

      expect(
        manager.events.map((TestEvent e) => e.eventId),
        ['e1', 'e2', 'e3'],
      );
      expect(manager.duplicateCount, 2);
    });
  });

  group('screen tracking', () {
    test('follows the current screen through entries and exits', () {
      final manager = SessionManager()
        ..ingest(enter('e1', 'Home', at: 1))
        ..ingest(exit('e2', 'Home', next: 'Cart', at: 2))
        ..ingest(enter('e3', 'Cart', at: 3));

      expect(manager.currentScreenId, 'Cart');
    });

    test('records the screens visited in order', () {
      final manager = SessionManager()
        ..ingest(enter('e1', 'Home', at: 1))
        ..ingest(enter('e2', 'ProductList', at: 2))
        ..ingest(enter('e3', 'ProductDetails', at: 3));

      expect(
        manager.screenHistory,
        ['Home', 'ProductList', 'ProductDetails'],
      );
    });

    test('derives the current screen chronologically, not by arrival', () {
      // A late-arriving earlier event must not rewrite the present.
      final manager = SessionManager()
        ..ingest(enter('e2', 'Cart', at: 2))
        ..ingest(enter('e1', 'Home', at: 1));

      expect(manager.currentScreenId, 'Cart');
    });

    test('ignores the removal of a screen it has already left', () {
      // Measured against the real external application. `context.go`
      // from a splash pushes the destination and *then* removes the
      // splash, and a removed route has no route beneath it - so the
      // observer reports the exit with no next screen.
      //
      // Read literally, that says "the app is on no screen", and a
      // `expectScreen` polling for the destination then waits out its
      // whole timeout while the app sits on the screen it asked for.
      // It is intermittent, because it depends on whether the poll
      // happens to run before the removal arrives.
      //
      // An exit only says where the app is when it is the screen the app
      // was on. Tidying away a background route says nothing.
      final manager = SessionManager()
        ..ingest(enter('e1', '/', at: 1))
        ..ingest(enter('e2', '/onboarding', at: 2))
        ..ingest(exit('e3', '/', next: null, at: 3));

      expect(manager.currentScreenId, '/onboarding');
    });

    test('still follows a pop of the screen the app is on', () {
      // The other side of the same rule: popping the *current* screen
      // with nothing beneath it really does leave no screen.
      final manager = SessionManager()
        ..ingest(enter('e1', '/', at: 1))
        ..ingest(exit('e2', '/', next: null, at: 2));

      expect(manager.currentScreenId, isNull);
    });

    test('has no current screen before any navigation', () {
      expect(SessionManager().currentScreenId, isNull);
    });
  });

  group('event stream', () {
    test('emits each distinct event once', () async {
      final manager = SessionManager();
      final seen = <String>[];
      final subscription =
          manager.onEvent.listen((TestEvent e) => seen.add(e.eventId));

      manager
        ..ingest(enter('e1', 'Home', at: 1))
        ..ingest(enter('e1', 'Home', at: 1))
        ..ingest(enter('e2', 'Cart', at: 2));
      await Future<void>.delayed(Duration.zero);

      expect(seen, ['e1', 'e2']);
      await subscription.cancel();
    });
  });

  group('session identity', () {
    test('adopts the session id of the first event seen', () {
      final manager = SessionManager()..ingest(enter('e1', 'Home', at: 1));

      expect(manager.sessionId, 'session-1');
    });

    test('rejects an event from a different session', () {
      // Two sessions interleaved would silently corrupt every correlation
      // built on top of this.
      final manager = SessionManager()..ingest(enter('e1', 'Home', at: 1));

      final foreign = TestEvent(
        eventId: 'x1',
        timestamp: DateTime.utc(2026, 9, 10, 12, 0, 5),
        sessionId: 'other-session',
        app: app,
        payload: const ScreenEnterPayload(screenId: 'Home'),
      );

      expect(() => manager.ingest(foreign), throwsStateError);
    });
  });
}
