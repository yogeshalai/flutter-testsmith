// A flow measured under `testsmith run` and errored under `testsmith suite
// run`, on a difference that had nothing to do with the application.
//
// `testsmith run` builds a dotenv-aware `EnvSecretResolver` and hands it to
// `FlowRunner`. A suite built the same resolver - for Figma - and did
// not hand it on, so `FlowExecutor` fell back to `_DefaultSecrets`,
// which reads the process environment and no `.env`.
//
// An `apiSource:` whose `baseUrl` or `token` lived only in a `.env` then
// resolved to nothing under a suite. `ApiAcquirer` returned
// `AcquisitionUnavailable`, `api-to-ui` reported ERROR rather than a
// comparison, ERROR outranks FAIL, and the suite classified the whole
// test as an environment error and exited 2. The same flow under
// `testsmith run` resolved the secret and measured the screen.
//
// These tests use the real `EnvSecretResolver` rather than a stub, so
// they exercise the actual lookup and its actual precedence, and prove
// the one thing a stub cannot: that the suite command passes the
// dependency on.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/dotenv.dart';
import 'package:flutter_testsmith_cli/src/secrets/env_secret_resolver.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// Records what the acquirer resolved before issuing a request.
class RecordingFetcher implements ApiFetcher {
  String? sawBaseUrl;
  Secret? sawToken;
  int calls = 0;

  @override
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  }) async {
    calls++;
    sawBaseUrl = resolvedBaseUrl;
    sawToken = token;
    return FetchSucceeded(
      ApiResponsePayload(
        requestId: 'r',
        statusCode: 200,
        body: '{"price": 999}',
        durationMs: 1,
      ),
    );
  }
}

/// An `apiSource:` whose base URL *and* token are both references.
const _envSourced = '''
screen: /product/details
apiSource:
  baseUrl: env:API_BASE
  method: GET
  endpoint: /products/123
  token: env:API_TOKEN
mappings:
  - target: product.price
    source: response.price
''';

ApiExchange _exchange(String method, String path, String body) {
  const requestId = 'captured-1';
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

ScreenSession _screen([List<ApiExchange> exchanges = const []]) {
  final session = ScreenSession(
    screenId: '/product/details',
    enteredAt: DateTime.utc(2026, 9, 15),
  );
  session.exchanges.addAll(exchanges);
  return session;
}

Future<ApiAcquisition> _acquire({
  required SecretResolver secrets,
  required ApiFetcher fetcher,
  List<ApiExchange> exchanges = const [],
  String mappings = _envSourced,
}) =>
    const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(mappings, source: 't'),
      session: _screen(exchanges),
      history: const [],
      fetcher: fetcher,
      secrets: secrets,
    );

/// The resolver `testsmith run` and `testsmith suite run` both build, with the
/// process environment injected so the real one need not be mutated.
EnvSecretResolver _resolver({
  Map<String, String> environment = const {},
  Map<String, String> dotenv = const {},
}) =>
    EnvSecretResolver(
      dotenv: DotEnv(dotenv),
      environment: environment,
    );

/// What a suite used to fall back to: the process environment only.
EnvSecretResolver _withoutDotenv(Map<String, String> environment) =>
    EnvSecretResolver(environment: environment);

String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

void main() {
  group('the case that used to diverge', () {
    test('a .env-only baseUrl and token now resolve', () async {
      final fetcher = RecordingFetcher();

      final acquisition = await _acquire(
        secrets: _resolver(
          dotenv: {
            'API_BASE': 'https://from-dotenv.example',
            'API_TOKEN': 'dotenv-token-value',
          },
        ),
        fetcher: fetcher,
      );

      expect(acquisition, isA<AcquiredFromFetch>());
      expect(fetcher.sawBaseUrl, 'https://from-dotenv.example');
      expect(fetcher.sawToken, isNotNull);
    });

    test('without dotenv the same configuration could not be measured',
        () async {
      // The old suite behaviour, kept as the contrast: this is what
      // `_DefaultSecrets` does, and why the screen errored.
      final fetcher = RecordingFetcher();

      final acquisition = await _acquire(
        secrets: _withoutDotenv(const {}),
        fetcher: fetcher,
      );

      expect(acquisition, isA<AcquisitionUnavailable>());
      expect(fetcher.calls, 0);
    });

    test('and that unavailability is what became an API error', () {
      // Pinned at the source: a null response is an ERROR in the api
      // dimension, which is why a missing `.env` secret changed a
      // verdict rather than being quietly skipped.
      final validators = _source('flutter_testsmith_engine/lib/src/validation/validators.dart');

      expect(validators, contains('ValidationResult.error'));
      expect(validators, contains('_noResponseMessage'));
    });
  });

  group('a .env-only value resolves for each consumer independently', () {
    test('the base URL alone', () async {
      final fetcher = RecordingFetcher();

      await _acquire(
        secrets: _resolver(
          environment: const {'API_TOKEN': 'env-token'},
          dotenv: const {'API_BASE': 'https://from-dotenv.example'},
        ),
        fetcher: fetcher,
      );

      expect(fetcher.sawBaseUrl, 'https://from-dotenv.example');
    });

    test('the token alone', () async {
      final fetcher = RecordingFetcher();

      final acquisition = await _acquire(
        secrets: _resolver(
          environment: const {'API_BASE': 'https://from-env.example'},
          dotenv: const {'API_TOKEN': 'dotenv-token-value'},
        ),
        fetcher: fetcher,
      );

      expect(acquisition, isA<AcquiredFromFetch>());
      expect(fetcher.sawBaseUrl, 'https://from-env.example');
      expect(fetcher.sawToken, isNotNull);
    });
  });

  group('precedence is unchanged', () {
    test('the process environment still wins over .env', () async {
      // The rule `EnvSecretResolver` states: the real environment always
      // wins, so CI is never overridden by a local file.
      final fetcher = RecordingFetcher();

      await _acquire(
        secrets: _resolver(
          environment: const {
            'API_BASE': 'https://from-env.example',
            'API_TOKEN': 'env-token',
          },
          dotenv: const {
            'API_BASE': 'https://from-dotenv.example',
            'API_TOKEN': 'dotenv-token-value',
          },
        ),
        fetcher: fetcher,
      );

      expect(fetcher.sawBaseUrl, 'https://from-env.example');
    });

    test('a secret in neither place still fails the way it always did',
        () async {
      final fetcher = RecordingFetcher();

      final acquisition = await _acquire(
        secrets: _resolver(),
        fetcher: fetcher,
      );

      expect(acquisition, isA<AcquisitionUnavailable>());
      final reason = (acquisition as AcquisitionUnavailable).reason;
      expect(reason, contains('API_BASE'));
      expect(fetcher.calls, 0);
    });
  });

  group('the acquisition contract is untouched', () {
    test('capture still wins, and no request is issued', () async {
      final fetcher = RecordingFetcher();

      final acquisition = await _acquire(
        secrets: _resolver(
          dotenv: const {
            'API_BASE': 'https://from-dotenv.example',
            'API_TOKEN': 'dotenv-token-value',
          },
        ),
        fetcher: fetcher,
        exchanges: [_exchange('GET', '/products/123', '{"price": 120}')],
      );

      expect(acquisition, isA<AcquiredFromCapture>());
      expect(fetcher.calls, 0);
    });

    test('the fallback still says it fetched, and why', () async {
      final acquisition = await _acquire(
        secrets: _resolver(
          dotenv: const {
            'API_BASE': 'https://from-dotenv.example',
            'API_TOKEN': 'dotenv-token-value',
          },
        ),
        fetcher: RecordingFetcher(),
      );

      final fetched = acquisition as AcquiredFromFetch;
      expect(fetched.endpoint, isNotEmpty);
      expect(fetched.fallbackReason, isNotEmpty);
    });

    test('a screen with no apiSource is unaffected', () async {
      final fetcher = RecordingFetcher();

      final acquisition = await _acquire(
        secrets: _resolver(),
        fetcher: fetcher,
        mappings: 'screen: /product/details\napi: GET /products/123\n',
        exchanges: [_exchange('GET', '/products/123', '{"price": 120}')],
      );

      expect(acquisition, isA<AcquiredFromCapture>());
      expect(fetcher.calls, 0);
    });
  });

  group('the suite command passes the dependency on', () {
    final suite = _source('flutter_testsmith_cli/lib/src/commands/suite_command.dart');
    final run = _source('flutter_testsmith_cli/lib/src/commands/run_command.dart');

    test('it hands its resolver to the runner', () {
      // Scoped to the `FlowRunner(` call. A file-wide `contains` would
      // still pass on the Figma call alone, which is exactly the state
      // this milestone fixed.
      final runner = suite.substring(suite.indexOf('FlowRunner('));

      expect(
        runner.substring(0, runner.indexOf('\n      ),')),
        contains('secrets: secrets'),
      );
    });

    test('it builds exactly one resolver, and shares it', () {
      // Identity by construction: one `EnvSecretResolver(` in the file,
      // and `secrets: secrets` at both the Figma call and the runner.
      expect('EnvSecretResolver('.allMatches(suite).length, 1);
      expect('secrets: secrets'.allMatches(suite).length, 2);
    });

    test('Figma still receives that same instance', () {
      expect(suite, contains('resolveFigmaSources('));
      final figmaCall = suite.substring(suite.indexOf('resolveFigmaSources('));
      expect(figmaCall.substring(0, figmaCall.indexOf(');')),
          contains('secrets: secrets'));
    });

    test('testsmith run is unchanged', () {
      expect(run, contains('secrets: secrets'));
      expect('EnvSecretResolver('.allMatches(run).length, 1);
    });

    test('the executor default is left alone', () {
      // `_DefaultSecrets` stays as the fallback for a caller that
      // injects nothing. This milestone changed who injects, not what
      // happens when nobody does.
      final executor = _source('flutter_testsmith_cli/lib/src/flow_executor.dart');

      expect(executor, contains('secrets ?? const _DefaultSecrets()'));
      expect(executor, contains('class _DefaultSecrets implements SecretResolver'));
    });

    test('every command agrees on where a .env is looked for', () {
      // This test used to pin the opposite: S1 deliberately left the
      // three commands disagreeing, so the divergence could not be
      // closed by accident before it had been decided. S2 decided it -
      // project first, then cwd, everywhere - and the full policy is
      // pinned in `dotenv_precedence_test.dart`. What remains here is
      // the part that matters to this file: the suite and run resolvers
      // are built the same way.
      final auth = _source('flutter_testsmith_cli/lib/src/commands/auth_command.dart');

      expect(
        auth,
        contains('DotEnv.load([project.path, Directory.current.path])'),
      );
      for (final command in [suite, run]) {
        expect(
          command,
          contains(
            'DotEnv.load([projectDirectory.path, Directory.current.path])',
          ),
        );
      }
    });
  });

  group('no secret value escapes', () {
    test('a missing-secret reason names the reference, never a value', () async {
      final acquisition = await _acquire(
        secrets: _resolver(
          dotenv: const {'API_BASE': 'https://from-dotenv.example'},
        ),
        fetcher: RecordingFetcher(),
      );

      final reason = (acquisition as AcquisitionUnavailable).reason;
      expect(reason, contains('API_TOKEN'));
      expect(reason, isNot(contains('dotenv-token-value')));
    });

    test('a resolved secret renders as the marker, not the value', () {
      const secret = Secret('dotenv-token-value');

      expect('$secret', isNot(contains('dotenv-token-value')));
      expect('$secret', redactionMarker);
    });

    test('a reference renders as scheme and name only', () {
      const ref = SecretRef(scheme: 'env', name: 'API_TOKEN');

      expect('$ref', 'env:API_TOKEN');
      expect('$ref', isNot(contains('dotenv-token-value')));
    });
  });
}
