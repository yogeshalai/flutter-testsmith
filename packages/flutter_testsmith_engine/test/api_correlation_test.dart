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

DateTime at(int seconds, [int millis = 0]) =>
    DateTime.utc(2026, 9, 10, 12, 0, seconds, millis);

TestEvent event(String id, EventPayload payload, DateTime when) => TestEvent(
      eventId: id,
      timestamp: when,
      sessionId: 's',
      app: app,
      payload: payload,
    );

TestEvent enter(String id, String screen, DateTime when) =>
    event(id, ScreenEnterPayload(screenId: screen), when);

TestEvent apiRequest(String id, String path, DateTime when) => event(
      id,
      ApiRequestPayload(requestId: id, method: 'GET', url: 'http://x$path'),
      when,
    );

TestEvent apiResponse(String requestId, DateTime when, {int status = 200}) =>
    event(
      'res-$requestId',
      ApiResponsePayload(
        requestId: requestId,
        statusCode: status,
        durationMs: 10,
      ),
      when,
    );

List<ScreenSession> correlate(
  List<TestEvent> events, {
  Duration grace = const Duration(seconds: 2),
}) {
  final manager = SessionManager()..ingestAll(events);
  return SessionCorrelator(graceWindow: grace).correlate(manager);
}

void main() {
  group('building screen sessions', () {
    test('creates one session per screen entry, in order', () {
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        enter('e2', 'ProductDetails', at(10)),
      ]);

      expect(sessions.map((ScreenSession s) => s.screenId),
          ['Home', 'ProductDetails']);
      expect(sessions.first.enteredAt, at(0));
    });

    test('a screen ends when the next one begins', () {
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        enter('e2', 'Cart', at(10)),
      ]);

      expect(sessions.first.exitedAt, at(10));
      expect(sessions.last.exitedAt, isNull);
    });
  });

  group('attribution by request issue time', () {
    test('attributes a request to the screen active when it was issued', () {
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        apiRequest('r1', '/home-feed', at(1)),
        apiResponse('r1', at(2)),
        enter('e2', 'ProductDetails', at(10)),
        apiRequest('r2', '/products/123', at(11)),
        apiResponse('r2', at(12)),
      ]);

      expect(sessions.first.exchanges.single.request.path, '/home-feed');
      expect(sessions.last.exchanges.single.request.path, '/products/123');
    });

    test('attributes by request time even when the response arrives later',
        () {
      // The response landing after the screen changed does not move the
      // exchange: attributing by response time is the classic cause of
      // unreproducible mis-assignment.
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        apiRequest('r1', '/slow', at(1)),
        enter('e2', 'Cart', at(5)),
        apiResponse('r1', at(8)),
      ]);

      expect(sessions.first.exchanges.single.request.path, '/slow');
      expect(sessions.last.exchanges, isEmpty);
    });

    test('pairs a response to its request', () {
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        apiRequest('r1', '/a', at(1)),
        apiResponse('r1', at(2), status: 404),
      ]);

      final exchange = sessions.single.exchanges.single;
      expect(exchange.isComplete, isTrue);
      expect(exchange.response!.statusCode, 404);
      expect(exchange.succeeded, isFalse);
    });

    test('an unanswered request is kept, and marked incomplete', () {
      // A request with no response is a finding, not something to hide.
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        apiRequest('r1', '/hangs', at(1)),
      ]);

      final exchange = sessions.single.exchanges.single;
      expect(exchange.isComplete, isFalse);
      expect(exchange.response, isNull);
    });
  });

  group('the grace window', () {
    test('gives a still-open request to the screen that follows it', () {
      // A tap handler that fetches and then navigates issues the request
      // while the old screen is technically still current, but the data
      // is for the new one. Still being in flight when the new screen
      // appears is what distinguishes it.
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        apiRequest('r1', '/products/123', at(9)),
        enter('e2', 'ProductDetails', at(10)),
        apiResponse('r1', at(11)),
      ]);

      expect(sessions.first.exchanges, isEmpty);
      expect(sessions.last.exchanges.single.request.path, '/products/123');
    });

    test('leaves an already-answered request with the screen that made it',
        () {
      // Completed before the navigation, so it was genuinely the old
      // screen's business.
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        apiRequest('r1', '/home-feed', at(9)),
        apiResponse('r1', at(9, 500)),
        enter('e2', 'ProductDetails', at(10)),
      ]);

      expect(sessions.first.exchanges.single.request.path, '/home-feed');
      expect(sessions.last.exchanges, isEmpty);
    });

    test('does not reach back further than the window', () {
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        apiRequest('r1', '/long-poll', at(1)),
        enter('e2', 'Cart', at(10)),
        apiResponse('r1', at(11)),
      ]);

      expect(sessions.first.exchanges.single.request.path, '/long-poll');
      expect(sessions.last.exchanges, isEmpty);
    });

    test('is configurable', () {
      final sessions = correlate(
        [
          enter('e1', 'Home', at(0)),
          apiRequest('r1', '/x', at(5)),
          enter('e2', 'Cart', at(10)),
          apiResponse('r1', at(11)),
        ],
        grace: const Duration(seconds: 6),
      );

      expect(sessions.last.exchanges.single.request.path, '/x');
    });
  });

  group('requests that belong to no screen', () {
    test('a startup request within the window joins the first screen', () {
      final sessions = correlate([
        apiRequest('r1', '/config', at(0)),
        enter('e1', 'Home', at(1)),
        apiResponse('r1', at(2)),
      ]);

      expect(sessions.single.exchanges.single.request.path, '/config');
    });

    test('an exchange with no plausible screen is reported, not dropped', () {
      // Silently discarding it would hide a real request from the
      // report; arbitrarily assigning it would be a lie.
      final manager = SessionManager()
        ..ingestAll([
          apiRequest('r1', '/very-early', at(0)),
          apiResponse('r1', at(1)),
          enter('e1', 'Home', at(30)),
        ]);

      final result = SessionCorrelator().correlateAll(manager);

      expect(result.sessions.single.exchanges, isEmpty);
      expect(result.unattributed.single.request.path, '/very-early');
    });

    test('a response with no matching request is reported', () {
      final manager = SessionManager()
        ..ingestAll([
          enter('e1', 'Home', at(0)),
          apiResponse('ghost', at(1)),
        ]);

      final result = SessionCorrelator().correlateAll(manager);

      expect(result.orphanResponses, hasLength(1));
    });
  });

  group('screen session summary', () {
    test('reports whether every exchange succeeded', () {
      final sessions = correlate([
        enter('e1', 'Home', at(0)),
        apiRequest('r1', '/a', at(1)),
        apiResponse('r1', at(2)),
        apiRequest('r2', '/b', at(3)),
        apiResponse('r2', at(4), status: 500),
      ]);

      expect(sessions.single.allExchangesSucceeded, isFalse);
      expect(sessions.single.failedExchanges, hasLength(1));
    });

    test('finds an exchange by path', () {
      final sessions = correlate([
        enter('e1', 'ProductDetails', at(0)),
        apiRequest('r1', '/products/123', at(1)),
        apiResponse('r1', at(2)),
      ]);

      expect(sessions.single.exchangeFor('/products/123'), isNotNull);
      expect(sessions.single.exchangeFor('/nope'), isNull);
    });
  });
}
