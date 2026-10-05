// The run-wide network record: every request a run captured, and how
// much of the application's traffic that could have been.
//
// Built from synthetic events through the real SessionManager and
// SessionCorrelator, so nothing here needs a device - and so the record
// is tested against the same correlation a run performs.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const AppContext _app = AppContext(
  appVersion: '1.0.0',
  buildMode: BuildMode.debug,
  environment: 'test',
  platform: 'android',
  devicePixelRatio: 2,
);

DateTime _at(int seconds, [int millis = 0]) =>
    DateTime.utc(2026, 10, 2, 9, 0, seconds, millis);

TestEvent _event(String id, EventPayload payload, DateTime when) => TestEvent(
      eventId: id,
      timestamp: when,
      sessionId: 's',
      app: _app,
      payload: payload,
    );

TestEvent _enter(String id, String screen, DateTime when) =>
    _event(id, ScreenEnterPayload(screenId: screen), when);

TestEvent _request(
  String id,
  String url,
  DateTime when, {
  String method = 'GET',
  Map<String, String> headers = const {},
  String? body,
}) =>
    _event(
      'req-$id',
      ApiRequestPayload(
        requestId: id,
        method: method,
        url: url,
        headers: headers,
        body: body,
      ),
      when,
    );

TestEvent _response(
  String id,
  DateTime when, {
  int? status = 200,
  String? error,
  int durationMs = 40,
  String? body,
}) =>
    _event(
      'res-$id',
      ApiResponsePayload(
        requestId: id,
        statusCode: status,
        error: error,
        durationMs: durationMs,
        body: body,
      ),
      when,
    );

NetworkRecord _observe(
  List<TestEvent> events, {
  bool advertised = true,
  int dropped = 0,
  String? protocolFailure,
  bool connectionLost = false,
  bool monotonic = true,
}) =>
    NetworkRecord.observe(
      advertised: advertised,
      monotonicTiming: monotonic,
      correlation: const SessionCorrelator()
          .correlateAll(SessionManager()..ingestAll(events)),
      droppedEventCount: dropped,
      protocolFailure: protocolFailure,
      connectionLost: connectionLost,
    );

void main() {
  group('how much the capture could see', () {
    test('capture on with no detectable loss is active, with no reasons', () {
      final record = _observe([
        _enter('e1', '/home', _at(0)),
        _request('r1', 'http://api/products', _at(1)),
        _response('r1', _at(1, 40)),
      ]);

      expect(record.state, NetworkCaptureState.active);
      expect(record.reasons, isEmpty);
    });

    test('an application that did not offer capture is unavailable', () {
      // An empty list then means nothing at all, and the record says so
      // rather than leaving a reader to conclude "no calls were made".
      final record = _observe([_enter('e1', '/home', _at(0))],
          advertised: false);

      expect(record.state, NetworkCaptureState.unavailable);
      expect(record.exchanges, isEmpty);
      expect(record.reasons.single, contains('not evidence that none'));
    });

    test('an unavailable capture is never upgraded by the other signals', () {
      final record = _observe(const [], advertised: false, dropped: 3);

      expect(record.state, NetworkCaptureState.unavailable);
    });

    test('a buffer that dropped events makes it partial, and says why', () {
      final record = _observe(const [], dropped: 3);

      expect(record.state, NetworkCaptureState.partial);
      expect(record.reasons.single, contains('discarded 3 buffered events'));
    });

    test('an unreadable event makes it partial', () {
      final record = _observe(const [], protocolFailure: 'bad payload');

      expect(record.state, NetworkCaptureState.partial);
      expect(record.reasons.single, contains('bad payload'));
    });

    test('a connection that ended makes it partial', () {
      final record = _observe(const [], connectionLost: true);

      expect(record.state, NetworkCaptureState.partial);
      expect(record.reasons.single, contains('connection'));
    });

    test('a response with no request makes it partial and is counted', () {
      final record = _observe([
        _enter('e1', '/home', _at(0)),
        _response('ghost', _at(2)),
      ]);

      expect(record.state, NetworkCaptureState.partial);
      expect(record.orphanResponses, 1);
      expect(record.reasons.single, contains('never seen'));
    });

    test('every cause is named, not only the first', () {
      final record = _observe(
        const [],
        dropped: 1,
        protocolFailure: 'x',
        connectionLost: true,
      );

      expect(record.reasons, hasLength(3));
    });

    test('the scope is written into the record, qualifying "active"', () {
      final json = _observe(const []).toJson();

      expect(json['capture'], 'active');
      expect(json['scope'], contains('dart:io HttpClient'));
      expect(json['scope'], contains('Not seen'));
    });
  });

  group('what each request came to', () {
    NetworkExchange only(List<TestEvent> events) =>
        _observe([_enter('e1', '/home', _at(0)), ...events]).exchanges.single;

    test('a 2xx is a success, with both timestamps and a duration', () {
      final e = only([
        _request('r1', 'http://api/a', _at(1)),
        _response('r1', _at(1, 250), durationMs: 250),
      ]);

      expect(e.outcome, ExchangeOutcome.success);
      expect(e.requestedAt, _at(1));
      expect(e.respondedAt, _at(1, 250));
      expect(e.durationMs, 250);
      expect(e.screenId, '/home');
    });

    test('a 4xx and a 5xx are HTTP errors with their status', () {
      final record = _observe([
        _enter('e1', '/home', _at(0)),
        _request('r1', 'http://api/a', _at(1)),
        _response('r1', _at(1, 10), status: 404),
        _request('r2', 'http://api/b', _at(2)),
        _response('r2', _at(2, 10), status: 503),
      ]);

      expect(record.exchanges.map((e) => e.outcome),
          everyElement(ExchangeOutcome.httpError));
      expect(record.exchanges.map((e) => e.statusCode), [404, 503]);
    });

    test('a client-side exception is failed, with the error text', () {
      final e = only([
        _request('r1', 'http://api/a', _at(1)),
        _response('r1', _at(1, 5), status: null,
            error: 'SocketException: Connection refused'),
      ]);

      expect(e.outcome, ExchangeOutcome.failed);
      expect(e.statusCode, isNull);
      expect(e.error, contains('refused'));
    });

    test('a timeout is a failure, and its measured duration is kept', () {
      // A client-side timeout reaches the capture as an exception after
      // the time it waited. That time was measured, so it is reported.
      final e = only([
        _request('r1', 'http://api/slow', _at(1)),
        _response('r1', _at(31), status: null,
            error: 'TimeoutException after 0:00:30.000000',
            durationMs: 30000),
      ]);

      expect(e.outcome, ExchangeOutcome.failed);
      expect(e.durationMs, 30000);
    });

    test('an unanswered request has no duration, never 0', () {
      final e = only([_request('r1', 'http://api/hangs', _at(1))]);

      expect(e.outcome, ExchangeOutcome.unanswered);
      expect(e.durationMs, isNull);
      expect(e.respondedAt, isNull);
      expect(e.toJson().containsKey('durationMs'), isFalse);
      expect(e.toJson().containsKey('respondedAt'), isFalse);
    });
  });

  group('the run-wide list', () {
    test('includes a request no screen owns, with no screen named', () {
      // Before this record, such a request appeared nowhere in a report.
      final record = _observe([
        _request('early', 'http://api/config', _at(0)),
        _response('early', _at(0, 20)),
        _enter('e1', '/home', _at(30)),
      ]);

      expect(record.exchanges.single.requestId, 'early');
      expect(record.exchanges.single.screenId, isNull);
      expect(record.exchanges.single.toJson().containsKey('screenId'), isFalse);
    });

    test('includes every screen, not only the ones a step validated', () {
      final record = _observe([
        _enter('e1', '/home', _at(0)),
        _request('r1', 'http://api/a', _at(1)),
        _enter('e2', '/cart', _at(10)),
        _request('r2', 'http://api/b', _at(11)),
      ]);

      expect(record.exchanges.map((e) => e.screenId), ['/home', '/cart']);
    });

    test('is ordered by when each request was issued', () {
      // The unattributed request is listed last by the correlator and
      // issued first; the record orders by time.
      final record = _observe([
        _request('first', 'http://api/1', _at(0)),
        _enter('e1', '/home', _at(30)),
        _request('second', 'http://api/2', _at(31)),
        _request('third', 'http://api/3', _at(32)),
      ]);

      expect(record.exchanges.map((e) => e.requestId),
          ['first', 'second', 'third']);
    });

    test('keeps emission order for requests stamped the same instant', () {
      final record = _observe([
        _enter('e1', '/home', _at(0)),
        _request('a', 'http://api/a', _at(1)),
        _request('b', 'http://api/b', _at(1)),
        _request('c', 'http://api/c', _at(1)),
      ]);

      expect(record.exchanges.map((e) => e.requestId), ['a', 'b', 'c']);
    });
  });

  group('what the record will not carry', () {
    test('no header and no body, request or response', () {
      final json = jsonEncode(_observe([
        _enter('e1', '/home', _at(0)),
        _request('r1', 'http://api/login', _at(1),
            method: 'POST',
            headers: {'x-trace': 'HEADER-VALUE'},
            body: '{"user":"REQUEST-BODY"}'),
        _response('r1', _at(1, 30), body: '{"name":"RESPONSE-BODY"}'),
      ]).toJson());

      expect(json, isNot(contains('HEADER-VALUE')));
      expect(json, isNot(contains('REQUEST-BODY')));
      expect(json, isNot(contains('RESPONSE-BODY')));
      expect(json, isNot(contains('"headers"')));
      expect(json, isNot(contains('"body"')));
    });

    test('the URL is carried exactly as the application redacted it', () {
      final e = _observe([
        _enter('e1', '/home', _at(0)),
        _request('r1', 'http://api/a?token=[REDACTED]&page=2', _at(1)),
      ]).exchanges.single;

      expect(e.url, 'http://api/a?token=[REDACTED]&page=2');
    });
  });

  group('which clock the durations were measured on', () {
    test('an SDK advertising monotonicNetworkTiming is recorded monotonic',
        () {
      final record = _observe(const []);

      expect(record.durationClock, NetworkDurationClock.monotonic);
      expect(record.toJson()['durationClock'], 'monotonic');
    });

    test('an older SDK, network without the capability, is recorded wall',
        () {
      // An application pins its own SDK; this is an ordinary pairing, and
      // capture still works - its durations are simply not monotonic.
      final record = _observe([
        _enter('e1', '/home', _at(0)),
        _request('r1', 'http://api/a', _at(1)),
        _response('r1', _at(1, 40)),
      ], monotonic: false);

      expect(record.state, NetworkCaptureState.active);
      expect(record.exchanges.single.durationMs, 40);
      expect(record.toJson()['durationClock'], 'wall');
    });

    test('the capability does not make capture available on its own', () {
      // Never advertised without 'network' by a real SDK; if it were, there
      // would still be no durations to describe.
      final record = _observe(const [], advertised: false);

      expect(record.state, NetworkCaptureState.unavailable);
      expect(record.durationClock, isNull);
      expect(record.toJson().containsKey('durationClock'), isFalse);
    });

    test('partial capture still records the clock', () {
      final record = _observe(const [], dropped: 2);

      expect(record.state, NetworkCaptureState.partial);
      expect(record.toJson()['durationClock'], 'monotonic');
    });

    test('a record built without one says nothing about the clock', () {
      // What a 1.5 artefact looks like: no key, which a reader must treat
      // as "not recorded" rather than as either value.
      const record = NetworkRecord(
        state: NetworkCaptureState.active,
        exchanges: [],
      );

      expect(record.toJson().containsKey('durationClock'), isFalse);
    });
  });

  group('serialisation', () {
    test('is stable: the same keys, in a fixed order', () {
      final record = _observe([
        _enter('e1', '/home', _at(0)),
        _request('r1', 'http://api/a', _at(1)),
        _response('r1', _at(1, 40), durationMs: 40),
      ]);

      expect(record.toJson().keys,
          ['capture', 'durationClock', 'scope', 'orphanResponses',
            'exchanges']);
      expect((record.toJson()['exchanges'] as List).single, {
        'requestId': 'r1',
        'method': 'GET',
        'url': 'http://api/a',
        'screenId': '/home',
        'requestedAt': '2026-10-02T09:00:01.000000Z',
        'respondedAt': '2026-10-02T09:00:01.040000Z',
        'outcome': 'success',
        'statusCode': 200,
        'durationMs': 40,
      });
    });

    test('orphanResponses is written even when it is zero', () {
      expect(_observe(const []).toJson()['orphanResponses'], 0);
    });
  });
}
