import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// Collects what the capture would have emitted.
class _Recorder {
  final List<EventPayload> emitted = <EventPayload>[];

  void call(EventPayload payload) => emitted.add(payload);

  List<ApiRequestPayload> get requests =>
      emitted.whereType<ApiRequestPayload>().toList();
  List<ApiResponsePayload> get responses =>
      emitted.whereType<ApiResponsePayload>().toList();

  /// Everything emitted, as one blob. Used to prove a secret is nowhere
  /// in it - including in a field nobody thought to check.
  String get everything => jsonEncode([
        for (final payload in emitted) payload.toJson(),
      ]);
}

({NetworkCapture capture, _Recorder recorder}) makeCapture({
  TestSdkConfig config = const TestSdkConfig(enabled: true),
}) {
  final recorder = _Recorder();
  // A monotonic source that moves 100 ms on every reading, so a begin and
  // its completion are always 100 ms apart.
  var micros = 0;
  return (
    capture: NetworkCapture(
      config: config,
      emit: recorder.call,
      monotonicMicros: () => micros += 100000,
    ),
    recorder: recorder,
  );
}

void main() {
  group('capturing a request', () {
    test('emits an API_REQUEST and returns an id', () {
      final (:capture, :recorder) = makeCapture();

      final id = capture.begin(
        method: 'GET',
        url: Uri.parse('http://127.0.0.1:8080/products/123'),
      );

      expect(id, isNotNull);
      expect(recorder.requests.single.method, 'GET');
      expect(recorder.requests.single.path, '/products/123');
    });

    test('pairs the response to the request by id', () {
      final (:capture, :recorder) = makeCapture();

      final id = capture.begin(
        method: 'GET',
        url: Uri.parse('http://x/products/1'),
      );
      capture.complete(id, statusCode: 200, body: '{"name":"Nike"}');

      expect(recorder.responses.single.requestId, id);
      expect(recorder.responses.single.statusCode, 200);
    });

    test('measures how long the exchange took', () {
      final (:capture, :recorder) = makeCapture();

      final id = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      capture.complete(id, statusCode: 200);

      expect(recorder.responses.single.durationMs, greaterThan(0));
    });

    test('records a failure with no status code', () {
      final (:capture, :recorder) = makeCapture();

      final id = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      capture.fail(id, error: 'SocketException: refused');

      final response = recorder.responses.single;
      expect(response.statusCode, isNull);
      expect(response.error, contains('refused'));
      expect(response.isSuccess, isFalse);
    });
  });

  group('secrets never enter an event', () {
    test('an authorization header is redacted at capture', () {
      final (:capture, :recorder) = makeCapture();

      capture.begin(
        method: 'GET',
        url: Uri.parse('http://x/products/1'),
        headers: {'authorization': 'Bearer sk_live_TOPSECRET'},
      );

      expect(recorder.everything, isNot(contains('sk_live_TOPSECRET')));
      expect(recorder.requests.single.headers['authorization'],
          RedactionPolicy.marker);
    });

    test('a password in a request body is redacted', () {
      final (:capture, :recorder) = makeCapture();

      capture.begin(
        method: 'POST',
        url: Uri.parse('http://x/login'),
        body: '{"user":"y","password":"hunter2"}',
      );

      expect(recorder.everything, isNot(contains('hunter2')));
    });

    test('a token in a response body is redacted', () {
      // The response is where a freshly minted token actually appears.
      final (:capture, :recorder) = makeCapture();

      final id = capture.begin(
        method: 'POST',
        url: Uri.parse('http://x/login'),
      );
      capture.complete(
        id,
        statusCode: 200,
        body: '{"accessToken":"eyJhbGciOi_SECRET","user":"y"}',
      );

      expect(recorder.everything, isNot(contains('eyJhbGciOi_SECRET')));
      // The rest of the body survives: redaction removes the secret, not
      // the response. Read it back parsed, since the raw blob escapes
      // the body's own quotes.
      expect(recorder.responses.single.readPath('user'), 'y');
      expect(recorder.responses.single.readPath('accessToken'),
          RedactionPolicy.marker);
    });

    test('a set-cookie response header is redacted', () {
      final (:capture, :recorder) = makeCapture();

      final id = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      capture.complete(
        id,
        statusCode: 200,
        headers: {'set-cookie': 'session=SECRETVALUE; HttpOnly'},
      );

      expect(recorder.everything, isNot(contains('SECRETVALUE')));
    });

    test('an excluded endpoint is not captured at all', () {
      final (:capture, :recorder) = makeCapture(
        config: const TestSdkConfig(
          enabled: true,
          redaction: RedactionPolicy(
            sensitiveKeys: {},
            excludedPaths: {'/auth'},
          ),
        ),
      );

      final id = capture.begin(
        method: 'POST',
        url: Uri.parse('http://x/auth/login'),
        body: '{"password":"hunter2"}',
      );
      capture.complete(id, statusCode: 200, body: '{"token":"SECRET"}');

      expect(recorder.emitted, isEmpty);
      expect(id, isNull);
    });

    test('a credential in the URL does not come back through the error', () {
      // dart:io's HttpException prints `uri = <the whole URL>`, and the
      // adapter forwards the exception as it was raised. The request
      // event masks the query value; the failure carrying the same URL
      // verbatim handed it straight back to every report.
      final (:capture, :recorder) = makeCapture();
      final url = Uri.parse('https://x/orders?access_token=TOPSECRET&page=2');

      final id = capture.begin(method: 'GET', url: url);
      capture.fail(
        id,
        error: HttpException('Connection closed before full header', uri: url),
      );

      expect(recorder.everything, isNot(contains('TOPSECRET')));
      // The rest of the message is the diagnosis, and it survives.
      final error = recorder.responses.single.error!;
      expect(error, contains('Connection closed before full header'));
      expect(error, contains('access_token=${RedactionPolicy.marker}'));
      expect(error, contains('page=2'));
    });

    test('a connection that fails before a request is redacted too', () {
      // The openUrl path: no request object ever existed, and begin and
      // fail are called back to back with the URL the caller passed.
      final (:capture, :recorder) = makeCapture();
      final url = Uri.parse('https://x/a?token=TOPSECRET');

      capture.fail(
        capture.begin(method: 'GET', url: url),
        error: HttpException('refused', uri: url),
      );

      expect(recorder.everything, isNot(contains('TOPSECRET')));
    });

    test('completing an unknown id is harmless', () {
      // begin() returns null for an excluded endpoint, and callers pass
      // that straight through; it must not throw.
      final (:capture, :recorder) = makeCapture();

      capture.complete(null, statusCode: 200);
      capture.fail(null, error: 'x');

      expect(recorder.emitted, isEmpty);
    });
  });

  group('body limits', () {
    test('truncates an oversized body and says so', () {
      final (:capture, :recorder) = makeCapture(
        config: const TestSdkConfig(enabled: true, maxBodyBytes: 10),
      );

      final id = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      capture.complete(id, statusCode: 200, body: 'x' * 100);

      final response = recorder.responses.single;
      expect(response.bodyTruncated, isTrue);
      expect(response.body!.length, 10);
    });

    test('a truncated body is never parsed for values', () {
      final (:capture, :recorder) = makeCapture(
        config: const TestSdkConfig(enabled: true, maxBodyBytes: 12),
      );

      final id = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      capture.complete(id, statusCode: 200, body: '{"name":"Nike Air Max"}');

      expect(recorder.responses.single.readPath('name'), isNull);
    });
  });

  group('when capture is disabled', () {
    test('nothing is emitted', () {
      final (:capture, :recorder) = makeCapture(
        config: const TestSdkConfig(enabled: true, enableNetworkCapture: false),
      );

      final id = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      capture.complete(id, statusCode: 200);

      expect(recorder.emitted, isEmpty);
    });
  });

  group('in-flight tracking', () {
    test('reports how many requests are outstanding', () {
      // Settle detection in Phase 4 needs this: a screen is not ready
      // while it is still waiting on the network.
      final capture = makeCapture().capture;

      expect(capture.inFlightCount, 0);

      final a = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      capture.begin(method: 'GET', url: Uri.parse('http://x/b'));
      expect(capture.inFlightCount, 2);

      capture.complete(a, statusCode: 200);
      expect(capture.inFlightCount, 1);
    });

    test('a failure also clears the in-flight entry', () {
      final capture = makeCapture().capture;

      final id = capture.begin(method: 'GET', url: Uri.parse('http://x/a'));
      capture.fail(id, error: 'boom');

      expect(capture.inFlightCount, 0);
    });
  });
}
