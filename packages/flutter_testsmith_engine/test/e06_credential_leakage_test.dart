import 'dart:convert';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const _apiToken = 'sk-live-THIS-MUST-NEVER-APPEAR';
const _figmaToken = 'figd-THIS-MUST-NEVER-APPEAR';

void _assertClean(String text, String where) {
  expect(text, isNot(contains(_apiToken)),
      reason: '$where leaked the API token');
  expect(text, isNot(contains(_figmaToken)),
      reason: '$where leaked the Figma token');
}

void main() {
  test('the sentinel check can actually fail', () {
    // Without this, every assertion below would pass on an empty string
    // and prove nothing at all.
    expect(
      () => _assertClean('prefix $_apiToken suffix', 'canary'),
      throwsA(isA<TestFailure>()),
    );
  });

  test('a mappings file holds references, never values', () {
    final file = MappingsFile.parse('''
screen: /product/details
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /products/123
  token: env:EXAMPLE_API_TOKEN
figmaSource:
  url: https://figma.com/design/abc/F?node-id=1-2
  token: env:FIGMA_TOKEN
  mapping: figma/p.mapping.yaml
''', source: 't');

    expect('${file.apiSource!.token}', 'env:EXAMPLE_API_TOKEN');
    expect('${file.figmaSource!.token}', 'env:FIGMA_TOKEN');
    _assertClean('${file.apiSource} ${file.figmaSource}', 'toString');
  });

  test('a literal credential cannot even be written into a mappings file', () {
    expect(
      () => MappingsFile.parse('''
screen: /s
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /p
  token: $_apiToken
''', source: 't'),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('a resolved secret renders as the marker under interpolation', () {
    const secret = Secret(_apiToken);
    _assertClean('the request failed with $secret', 'interpolation');
    expect('$secret', redactionMarker);
  });

  test('a fetched payload carries no headers into result.json', () {
    final payload = jsonResponse(
      statusCode: 200,
      body: '{"price": 120}',
      durationMs: 4,
    );
    _assertClean(jsonEncode(payload.toJson()), 'ApiResponsePayload');
    expect(payload.headers, isEmpty);
  });

  test('result.json and report.html are clean end to end', () {
    final run = RunResult(
      flowName: 'product_details',
      appId: 'com.example.ecommerce_app',
      device: 'emulator-5554',
      startedAt: DateTime.utc(2026, 9, 15),
      duration: const Duration(seconds: 2),
      steps: const [
        StepOutcome(
          description: 'launch the app',
          kind: StepKind.launchApp,
          status: StepStatus.ok,
          durationMs: 5,
        ),
      ],
      screens: [
        ScreenResult(
          screenId: '/product/details',
          report: ValidationReport([
            ValidationResult.pass(
              validatorId: 'api-to-ui',
              message: 'response.price matches product.price.text',
              dimension: ValidationDimension.api,
              evidence: const [
                Evidence(kind: 'responseProvenance', reference: 'fetched'),
                Evidence(
                  kind: 'fallbackReason',
                  reference: 'the application did not call GET /products/123',
                ),
              ],
            ),
          ]),
        ),
      ],
    );

    final json = jsonEncode(run.toJson());
    _assertClean(json, 'result.json');
    _assertClean(const HtmlReporter().render(run.toJson()), 'report.html');
  });

  test('a missing secret names the variable and nothing around it', () {
    final ref = SecretRef.parse('env:EXAMPLE_API_TOKEN', source: 't');
    final message = MissingSecretException(ref).toString();
    expect(message, contains('EXAMPLE_API_TOKEN'));
    _assertClean(message, 'MissingSecretException');
  });

  test('an acquisition failure names the variable, never the value', () async {
    final acquisition = await const ApiAcquirer().acquire(
      mappings: MappingsFile.parse('''
screen: /s
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /p
  token: env:EXAMPLE_API_TOKEN
''', source: 't'),
      session: ScreenSession(
        screenId: '/s',
        enteredAt: DateTime.utc(2026, 9, 15),
      ),
      history: const [],
      fetcher: _NeverCalled(),
      secrets: const _LeakyResolver(),
    );

    expect(acquisition, isA<AcquisitionUnavailable>());
    _assertClean(
      (acquisition as AcquisitionUnavailable).reason,
      'AcquisitionUnavailable',
    );
  });
}

/// A resolver that holds a real-looking credential, so the assertion
/// above is testing something.
class _LeakyResolver implements SecretResolver {
  const _LeakyResolver();

  @override
  bool isPresent(SecretRef ref) => false;

  @override
  Secret resolve(SecretRef ref) => const Secret(_apiToken);
}

class _NeverCalled implements ApiFetcher {
  @override
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  }) async =>
      throw StateError('no fetch should have been attempted');
}
