import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

class CountingFetcher implements ApiFetcher {
  CountingFetcher(this.outcome);

  final FetchOutcome outcome;
  int calls = 0;

  @override
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  }) async {
    calls++;
    return outcome;
  }
}

class FixedResolver implements SecretResolver {
  const FixedResolver(this._values);

  final Map<String, String> _values;

  @override
  bool isPresent(SecretRef ref) => _values.containsKey(ref.name);

  @override
  Secret resolve(SecretRef ref) {
    final value = _values[ref.name];
    if (value == null) throw MissingSecretException(ref);
    return Secret(value);
  }
}

/// `ApiExchange` is immutable - the response goes in through the
/// constructor, not a cascade.
ApiExchange _exchange(String method, String path, String body) {
  final requestId = '$method$path$body';
  final at = DateTime.utc(2026, 9, 15);
  return ApiExchange(
    request: ApiRequestPayload(
      requestId: requestId,
      method: method,
      url: 'https://host.example$path',
    ),
    requestedAt: at,
    response: ApiResponsePayload(
      requestId: requestId,
      statusCode: 200,
      body: body,
      durationMs: 3,
    ),
    respondedAt: at,
  );
}

ScreenSession _screenWith(List<ApiExchange> exchanges) {
  final session = ScreenSession(
    screenId: '/product/details',
    enteredAt: DateTime.utc(2026, 9, 15),
  );
  session.exchanges.addAll(exchanges);
  return session;
}

const _withApiSource = '''
screen: /product/details
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /products/123
  token: env:API_TOKEN
mappings:
  - target: product.price
    source: response.price
''';

CountingFetcher _succeeds([String body = '{"price": 999}']) => CountingFetcher(
      FetchSucceeded(jsonResponse(statusCode: 200, body: body, durationMs: 1)),
    );

Future<ApiAcquisition> _acquire({
  required String mappings,
  required List<ApiExchange> exchanges,
  required ApiFetcher fetcher,
  Map<String, String> secrets = const {'API_TOKEN': 'x'},
}) =>
    const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(mappings, source: 't'),
      session: _screenWith(exchanges),
      history: const [],
      fetcher: fetcher,
      secrets: FixedResolver(secrets),
    );

void main() {
  test('captured traffic is preferred, and no request is issued', () async {
    final fetcher = _succeeds();
    final acquisition = await _acquire(
      mappings: _withApiSource,
      exchanges: [_exchange('GET', '/products/123', '{"price": 120}')],
      fetcher: fetcher,
    );

    expect(acquisition, isA<AcquiredFromCapture>());
    expect((acquisition as AcquiredFromCapture).payload.readPath('price'), 120);
    expect(fetcher.calls, 0, reason: 'a fetch was issued despite a capture');
  });

  test('a fetch happens only when the capture is unavailable', () async {
    final fetcher = _succeeds('{"price": 120}');
    final acquisition = await _acquire(
      mappings: _withApiSource,
      // The screen called something else entirely.
      exchanges: [_exchange('GET', '/appconfig', '{}')],
      fetcher: fetcher,
    );

    expect(acquisition, isA<AcquiredFromFetch>());
    final fetched = acquisition as AcquiredFromFetch;
    expect(fetched.payload.readPath('price'), 120);
    expect(fetched.fallbackReason, contains('/products/123'));
    expect(fetcher.calls, 1);
  });

  test('ambiguity never falls back to a fetch', () async {
    final fetcher = _succeeds('{"price": 1}');
    final acquisition = await _acquire(
      mappings: _withApiSource,
      exchanges: [
        _exchange('GET', '/products/123', '{"price": 120}'),
        _exchange('GET', '/products/123', '{"price": 140}'),
      ],
      fetcher: fetcher,
    );

    expect(acquisition, isA<AcquisitionAmbiguous>());
    expect(fetcher.calls, 0,
        reason: 'a fetch silently answered a question the platform refuses');
    expect((acquisition as AcquisitionAmbiguous).reason, contains('2'));
  });

  test('a failed fetch is unavailable with the reason, not a fake pass',
      () async {
    final acquisition = await _acquire(
      mappings: _withApiSource,
      exchanges: const [],
      fetcher: CountingFetcher(const FetchFailed('the connection was refused')),
    );
    expect(acquisition, isA<AcquisitionUnavailable>());
    expect(
        (acquisition as AcquisitionUnavailable).reason, contains('refused'));
  });

  test('a non-2xx fetch is unavailable and names the status', () async {
    final acquisition = await _acquire(
      mappings: _withApiSource,
      exchanges: const [],
      fetcher: CountingFetcher(
        FetchSucceeded(jsonResponse(statusCode: 401, body: '', durationMs: 1)),
      ),
    );
    expect(acquisition, isA<AcquisitionUnavailable>());
    expect((acquisition as AcquisitionUnavailable).reason, contains('401'));
  });

  test('a missing credential is unavailable and names the variable only',
      () async {
    final acquisition = await _acquire(
      mappings: _withApiSource,
      exchanges: const [],
      fetcher: _succeeds(),
      secrets: const {},
    );
    expect(acquisition, isA<AcquisitionUnavailable>());
    final reason = (acquisition as AcquisitionUnavailable).reason;
    expect(reason, contains('API_TOKEN'));
    expect(reason, isNot(contains('x')));
  });

  test('a screen with no apiSource is unchanged', () async {
    final acquisition = await _acquire(
      mappings: 'screen: /product/details\napi: GET /products/123\n',
      exchanges: [_exchange('GET', '/products/123', '{"price": 120}')],
      fetcher: _succeeds(),
      secrets: const {},
    );
    expect(acquisition, isA<AcquiredFromCapture>());
  });

  test('a screen with no apiSource and no capture is unavailable, not fetched',
      () async {
    final fetcher = _succeeds();
    final acquisition = await _acquire(
      mappings: 'screen: /product/details\napi: GET /products/123\n',
      exchanges: const [],
      fetcher: fetcher,
      secrets: const {},
    );
    expect(acquisition, isA<AcquisitionUnavailable>());
    expect(fetcher.calls, 0);
  });

  test('the base URL path prefix is part of the match', () async {
    final fetcher = _succeeds();
    final acquisition = await _acquire(
      mappings: '''
screen: /product/details
apiSource:
  baseUrl: https://host.example/api/v1
  method: GET
  endpoint: /products/123
''',
      // The application calls the prefixed path, as it really would.
      exchanges: [_exchange('GET', '/api/v1/products/123', '{"price": 120}')],
      fetcher: fetcher,
      secrets: const {},
    );
    expect(acquisition, isA<AcquiredFromCapture>());
    expect(fetcher.calls, 0);
  });

  test('usesResponseFrom ambiguity also refuses to fall back', () async {
    final fetcher = _succeeds();
    final acquisition = await _acquire(
      mappings: '''
screen: /product/details
usesResponseFrom:
  endpoint: GET /products/123
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /products/123
''',
      exchanges: [
        _exchange('GET', '/products/123', '{"price": 120}'),
        _exchange('GET', '/products/123', '{"price": 140}'),
      ],
      fetcher: fetcher,
      secrets: const {},
    );
    expect(acquisition, isA<AcquisitionAmbiguous>());
    expect(fetcher.calls, 0);
  });
}
