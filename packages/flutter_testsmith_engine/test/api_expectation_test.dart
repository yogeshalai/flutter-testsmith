import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// Asserting on the API *inside* a UI flow.
///
/// The gap this closes: every check the platform had was a statement
/// about a screen. A run could therefore go green while the application
/// rendered a plausible screen from a cached response, a 304, or the
/// wrong endpoint entirely - which is exactly what STOP-1 found on a
/// real profile screen.
///
/// `expectApi` asserts against the exchange the **application** made, as
/// captured by the SDK. Not against the fixture server's own log: that
/// would prove what was sent, which is not the same claim as what
/// arrived.

ApiExchange exchange({
  String method = 'GET',
  String path = '/api/dashboard/summary',
  int? status = 200,
  String? body,
  String? error,
  DateTime? at,
}) {
  final when = at ?? DateTime.utc(2026, 9, 12, 10);
  final id = 'r-${path.hashCode}-${when.microsecondsSinceEpoch}';
  return ApiExchange(
    request: ApiRequestPayload(
      requestId: id,
      method: method,
      url: 'http://127.0.0.1:8080$path',
      headers: const {},
    ),
    requestedAt: when,
    response: ApiResponsePayload(
      requestId: id,
      statusCode: status,
      headers: const {},
      body: body,
      error: error,
      durationMs: 12,
    ),
    respondedAt: when.add(const Duration(milliseconds: 12)),
  );
}

List<ScreenSession> sessionWith(
  List<ApiExchange> exchanges, {
  String screen = '/home',
}) {
  final session = ScreenSession(
    screenId: screen,
    enteredAt: DateTime.utc(2026, 9, 12, 9, 59),
  );
  session.exchanges.addAll(exchanges);
  return [session];
}

ApiExpectationOutcome run(ExpectApiStep step, List<ScreenSession> history) =>
    const ApiExpectationEvaluator().evaluate(step: step, history: history);

const ApiEndpoint dashboard =
    ApiEndpoint('GET', '/api/dashboard/summary');

void main() {
  group('finding the exchange', () {
    test('passes when the declared endpoint answered with the status', () {
      final outcome = run(
        const ExpectApiStep(endpoint: dashboard, status: 200),
        sessionWith([exchange()]),
      );

      expect(outcome.satisfied, isTrue);
      expect(outcome.describe(), contains('200'));
    });

    test('fails, naming the status, when the endpoint answered differently',
        () {
      final outcome = run(
        const ExpectApiStep(endpoint: dashboard, status: 200),
        sessionWith([exchange(status: 500)]),
      );

      expect(outcome.satisfied, isFalse);
      expect(outcome.describe(), allOf(contains('500'), contains('200')));
    });

    test('fails, naming what the app did call, when it never called this', () {
      // The STOP-1 failure mode. "Not found" is useless here; the list
      // of what *was* called is what shows the endpoint was misspelled
      // or the screen never fetched at all.
      final outcome = run(
        const ExpectApiStep(endpoint: dashboard, status: 200),
        sessionWith([exchange(path: '/api/profile/me')]),
      );

      expect(outcome.satisfied, isFalse);
      expect(outcome.describe(), contains('/api/profile/me'));
    });

    test('a transport error is a failure that says so, not a missing status',
        () {
      final outcome = run(
        const ExpectApiStep(endpoint: dashboard, status: 200),
        sessionWith([exchange(status: null, error: 'Connection refused')]),
      );

      expect(outcome.satisfied, isFalse);
      expect(outcome.describe(), contains('Connection refused'));
    });

    test('matches a wildcard path segment', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: ApiEndpoint('GET', '/api/requests/*'),
          status: 200,
        ),
        sessionWith([exchange(path: '/api/requests/abc123')]),
      );

      expect(outcome.satisfied, isTrue);
    });

    test('refuses to choose between two matches unless told which', () {
      // The same rule `usesResponseFrom:` follows. Guessing by recency
      // is how a stale response becomes indistinguishable from a fresh
      // one.
      final outcome = run(
        const ExpectApiStep(endpoint: dashboard, status: 200),
        sessionWith([
          exchange(at: DateTime.utc(2026, 9, 12, 10)),
          exchange(at: DateTime.utc(2026, 9, 12, 10, 1)),
        ]),
      );

      expect(outcome.satisfied, isFalse);
      expect(outcome.describe(), contains('occurrence'));
    });

    test('occurrence: last takes the most recent of several', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          occurrence: ResponseOccurrence.last,
        ),
        sessionWith([
          exchange(status: 500, at: DateTime.utc(2026, 9, 12, 10)),
          exchange(at: DateTime.utc(2026, 9, 12, 10, 1)),
        ]),
      );

      expect(outcome.satisfied, isTrue);
    });

    test('an exchange still in flight is not an answer', () {
      final pending = ApiExchange(
        request: ApiRequestPayload(
          requestId: 'r-1',
          method: 'GET',
          url: 'http://127.0.0.1:8080/api/dashboard/summary',
          headers: const {},
        ),
        requestedAt: DateTime.utc(2026, 9, 12, 10),
      );

      final outcome = run(
        const ExpectApiStep(endpoint: dashboard, status: 200),
        sessionWith([pending]),
      );

      expect(outcome.satisfied, isFalse);
    });
  });

  group('asserting on the body', () {
    const body = '{'
        '"outletsNearYou": {'
        '  "isOutletsNearYouDataAvailable": true,'
        '  "outletsNearYouData": ['
        '    { "_id": "b-1", "businessName": "Example Restaurant" },'
        '    { "_id": "b-2", "businessName": "Riverside Bakehouse" }'
        '  ]'
        '},'
        '"token": "SEEDED"'
        '}';

    test('equals compares the value at a dotted path', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [
            ApiExpectation(
              path: 'outletsNearYou.outletsNearYouData.0.businessName',
              equals: 'Example Restaurant',
            ),
          ],
        ),
        sessionWith([exchange(body: body)]),
      );

      expect(outcome.satisfied, isTrue);
    });

    test('a mismatch names the path, what was wanted and what arrived', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [ApiExpectation(path: 'token', equals: 'OTHER')],
        ),
        sessionWith([exchange(body: body)]),
      );

      expect(outcome.satisfied, isFalse);
      expect(
        outcome.describe(),
        allOf(contains('token'), contains('OTHER'), contains('SEEDED')),
      );
    });

    test('count asserts how many entries a list holds', () {
      // The fixture assertion that matters most: a dashboard rendering
      // two outlet cards when the fixture holds five is a screen that
      // silently dropped data.
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [
            ApiExpectation(path: 'outletsNearYou.outletsNearYouData', count: 2),
          ],
        ),
        sessionWith([exchange(body: body)]),
      );

      expect(outcome.satisfied, isTrue);
    });

    test('count on something that is not a list fails and says so', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [ApiExpectation(path: 'token', count: 1)],
        ),
        sessionWith([exchange(body: body)]),
      );

      expect(outcome.satisfied, isFalse);
      expect(outcome.describe(), contains('not a list'));
    });

    test('present asserts a field exists without pinning its value', () {
      // For a token or a session id: the test must not write the secret
      // down, and asserting on its value would.
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [ApiExpectation(path: 'token', present: true)],
        ),
        sessionWith([exchange(body: body)]),
      );

      expect(outcome.satisfied, isTrue);
    });

    test('present: false catches a field that should not be there', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [ApiExpectation(path: 'token', present: false)],
        ),
        sessionWith([exchange(body: body)]),
      );

      expect(outcome.satisfied, isFalse);
    });

    test('a body assertion on an absent path fails rather than passing', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [ApiExpectation(path: 'nothing.here', equals: 'x')],
        ),
        sessionWith([exchange(body: body)]),
      );

      expect(outcome.satisfied, isFalse);
    });

    test('a body that is not JSON fails the assertion, not the parser', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [ApiExpectation(path: 'token', present: true)],
        ),
        sessionWith([exchange(body: '<html>nope</html>')]),
      );

      expect(outcome.satisfied, isFalse);
    });

    test('every failed expectation is reported, not only the first', () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [
            ApiExpectation(path: 'token', equals: 'A'),
            ApiExpectation(path: 'outletsNearYou.outletsNearYouData', count: 9),
          ],
        ),
        sessionWith([exchange(body: body)]),
      );

      expect(outcome.satisfied, isFalse);
      expect(outcome.failures, hasLength(2));
    });

    test('the status is checked before the body, and reported alone', () {
      // A 500's body is an error document. Reporting five missing
      // fields as well as the 500 buries the one fact that matters.
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [ApiExpectation(path: 'token', present: true)],
        ),
        sessionWith([exchange(status: 500, body: '{"error":"boom"}')]),
      );

      expect(outcome.satisfied, isFalse);
      expect(outcome.failures, hasLength(1));
      expect(outcome.failures.single, contains('500'));
    });
  });

  group('what the report carries', () {
    test('a passing outcome names the endpoint and the status', () {
      final outcome = run(
        const ExpectApiStep(endpoint: dashboard, status: 200),
        sessionWith([exchange()]),
      );

      expect(outcome.endpoint, 'GET /api/dashboard/summary');
      expect(outcome.status, 200);
      expect(outcome.screenId, '/home');
    });

    test('it carries no response body, so a token cannot leak into a report',
        () {
      final outcome = run(
        const ExpectApiStep(
          endpoint: dashboard,
          status: 200,
          expectations: [ApiExpectation(path: 'token', present: true)],
        ),
        sessionWith([exchange(body: '{"token":"SUPER_SECRET_VALUE"}')]),
      );

      expect(outcome.satisfied, isTrue);
      expect(outcome.describe(), isNot(contains('SUPER_SECRET_VALUE')));
    });
  });
}
