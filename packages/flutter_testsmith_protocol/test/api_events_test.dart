import 'package:test/test.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

ApiRequestPayload request({
  String requestId = 'req-1',
  String method = 'GET',
  String url = 'https://api.example.com/products/123',
  Map<String, String> headers = const {},
  String? body,
  bool bodyTruncated = false,
}) =>
    ApiRequestPayload(
      requestId: requestId,
      method: method,
      url: url,
      headers: headers,
      body: body,
      bodyTruncated: bodyTruncated,
    );

void main() {
  group('ApiRequestPayload', () {
    test('round-trips through JSON', () {
      final payload = request(
        method: 'POST',
        headers: const {'content-type': 'application/json'},
        body: '{"qty":1}',
      );

      final restored =
          EventPayload.fromJson(payload.type, payload.toJson())
              as ApiRequestPayload;

      expect(restored.requestId, 'req-1');
      expect(restored.method, 'POST');
      expect(restored.url, 'https://api.example.com/products/123');
      expect(restored.headers, {'content-type': 'application/json'});
      expect(restored.body, '{"qty":1}');
    });

    test('reports its event type', () {
      expect(request().type, EventType.apiRequest);
    });

    test('records that a body was truncated', () {
      // A report must never silently show partial data as if complete.
      final restored = EventPayload.fromJson(
        EventType.apiRequest,
        request(body: 'abc', bodyTruncated: true).toJson(),
      ) as ApiRequestPayload;

      expect(restored.bodyTruncated, isTrue);
    });

    test('exposes the path for matching without the host', () {
      expect(
        request(url: 'https://api.example.com/products/123?x=1').path,
        '/products/123',
      );
    });
  });

  group('ApiResponsePayload', () {
    test('round-trips a successful response', () {
      const payload = ApiResponsePayload(
        requestId: 'req-1',
        statusCode: 200,
        headers: {'content-type': 'application/json'},
        body: '{"name":"Nike Air Max"}',
        durationMs: 143,
      );

      final restored =
          EventPayload.fromJson(payload.type, payload.toJson())
              as ApiResponsePayload;

      expect(restored.requestId, 'req-1');
      expect(restored.statusCode, 200);
      expect(restored.durationMs, 143);
      expect(restored.isSuccess, isTrue);
    });

    test('round-trips a failure with no status code', () {
      // A connection refused or a timeout has no status; forcing a 0 or
      // 500 here would misreport what happened.
      const payload = ApiResponsePayload(
        requestId: 'req-1',
        error: 'SocketException: connection refused',
        durationMs: 30000,
      );

      final restored =
          EventPayload.fromJson(payload.type, payload.toJson())
              as ApiResponsePayload;

      expect(restored.statusCode, isNull);
      expect(restored.error, contains('connection refused'));
      expect(restored.isSuccess, isFalse);
    });

    test('treats 4xx and 5xx as unsuccessful', () {
      expect(
        const ApiResponsePayload(
          requestId: 'r',
          statusCode: 404,
          durationMs: 1,
        ).isSuccess,
        isFalse,
      );
      expect(
        const ApiResponsePayload(
          requestId: 'r',
          statusCode: 500,
          durationMs: 1,
        ).isSuccess,
        isFalse,
      );
      expect(
        const ApiResponsePayload(
          requestId: 'r',
          statusCode: 201,
          durationMs: 1,
        ).isSuccess,
        isTrue,
      );
    });

    test('parses a JSON body into a value that can be read by path', () {
      const payload = ApiResponsePayload(
        requestId: 'r',
        statusCode: 200,
        body: '{"name":"Nike","price":2999,"meta":{"stock":3}}',
        durationMs: 1,
      );

      expect(payload.readPath('name'), 'Nike');
      expect(payload.readPath('price'), 2999);
      expect(payload.readPath('meta.stock'), 3);
      expect(payload.readPath('missing'), isNull);
    });

    test('reading a path from a non-JSON body yields null, not a crash', () {
      const payload = ApiResponsePayload(
        requestId: 'r',
        statusCode: 200,
        body: '<html>nope</html>',
        durationMs: 1,
      );

      expect(payload.readPath('name'), isNull);
    });

    test('reading a path from a truncated body yields null', () {
      // Truncated JSON does not parse, and guessing at the missing half
      // would produce confident nonsense.
      const payload = ApiResponsePayload(
        requestId: 'r',
        statusCode: 200,
        body: '{"name":"Nike","pri',
        bodyTruncated: true,
        durationMs: 1,
      );

      expect(payload.readPath('name'), isNull);
    });
  });

  group('the request id ties the pair together', () {
    test('a response names the request it answers', () {
      final req = request(requestId: 'abc');
      const res = ApiResponsePayload(
        requestId: 'abc',
        statusCode: 200,
        durationMs: 5,
      );

      expect(res.requestId, req.requestId);
    });
  });
}
