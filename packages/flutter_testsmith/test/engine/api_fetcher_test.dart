import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// A fetcher that answers from a script. No network, no timing.
class ScriptedFetcher implements ApiFetcher {
  ScriptedFetcher(this.outcome);

  final FetchOutcome outcome;
  ApiSource? sawSource;
  String? sawBase;
  Secret? sawToken;

  @override
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  }) async {
    sawSource = source;
    sawBase = resolvedBaseUrl;
    sawToken = token;
    return outcome;
  }
}

const _source = ApiSource(
  baseUrl: 'https://h.example',
  method: 'GET',
  endpoint: '/p',
);

void main() {
  test('a JSON 200 becomes a readable response payload', () async {
    final fetcher = ScriptedFetcher(
      FetchSucceeded(
        jsonResponse(statusCode: 200, body: '{"price": 120}', durationMs: 7),
      ),
    );
    final outcome = await fetcher.fetch(
      source: _source,
      resolvedBaseUrl: 'https://h.example',
      token: null,
    );
    expect(outcome, isA<FetchSucceeded>());
    final payload = (outcome as FetchSucceeded).payload;
    expect(payload.statusCode, 200);
    expect(payload.readPath('price'), 120);
    expect(payload.isSuccess, isTrue);
  });

  test('a fetched payload never carries headers', () {
    final payload = jsonResponse(statusCode: 200, body: '{}', durationMs: 1);
    expect(payload.headers, isEmpty);
    expect(payload.toJson().containsKey('headers'), isFalse);
  });

  test('a non-2xx payload is not a success', () {
    final payload =
        jsonResponse(statusCode: 401, body: 'nope', durationMs: 1);
    expect(payload.isSuccess, isFalse);
  });

  test('a failure carries a reason and no payload', () async {
    final fetcher = ScriptedFetcher(
      const FetchFailed('the connection to https://h.example was refused'),
    );
    final outcome = await fetcher.fetch(
      source: _source,
      resolvedBaseUrl: 'https://h.example',
      token: null,
    );
    expect(outcome, isA<FetchFailed>());
    expect((outcome as FetchFailed).reason, contains('refused'));
  });

  test('the token reaches the fetcher as a Secret, not a String', () async {
    final fetcher = ScriptedFetcher(
      FetchSucceeded(jsonResponse(statusCode: 200, body: '{}', durationMs: 1)),
    );
    await fetcher.fetch(
      source: _source,
      resolvedBaseUrl: 'https://h.example',
      token: const Secret('supersecret'),
    );
    // Interpolating it - the way a secret actually escapes, through an
    // error message somebody added in a hurry - yields the marker.
    expect('${fetcher.sawToken}', redactionMarker);
    expect(fetcher.sawToken!.expose(), 'supersecret');
  });
}
