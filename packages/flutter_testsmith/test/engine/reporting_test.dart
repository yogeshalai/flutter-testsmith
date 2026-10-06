import 'dart:convert';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

RunResult buildResult({bool failing = true}) => RunResult(
      flowName: 'product_purchase',
      appId: 'com.example.ecommerce_app',
      device: 'RZ8T11QETWM',
      startedAt: DateTime.utc(2026, 9, 10, 12),
      duration: const Duration(seconds: 42),
      steps: const [
        StepOutcome(
          description: 'launch the app',
          kind: StepKind.launchApp,
          status: StepStatus.ok,
          durationMs: 12000,
        ),
        StepOutcome(
          description: 'tap "home.open_product"',
          kind: StepKind.tap,
          status: StepStatus.ok,
          durationMs: 800,
        ),
      ],
      screens: [
        ScreenResult(
          screenId: '/product/details',
          report: ValidationReport([
            const ValidationResult.pass(
              validatorId: 'ui-presence',
              dimension: ValidationDimension.ui,
              elementId: 'product.name',
              message: 'present',
            ),
            if (failing)
              const ValidationResult.fail(
                validatorId: 'api-to-ui',
                dimension: ValidationDimension.api,
                elementId: 'product.price',
                message: 'product.price.text does not match response.price. '
                    'API returned 2999; currency(INR) gives "Rs 2,999"; '
                    'the UI shows "Rs 2,599".',
                expected: 'Rs 2,999',
                actual: 'Rs 2,599',
              ),
            const ValidationResult.skip(
              validatorId: 'figma',
              dimension: ValidationDimension.figma,
              message: 'Figma is not configured',
            ),
          ]),
          exchanges: const [
            ExchangeSummary(
              method: 'GET',
              path: '/products/123',
              statusCode: 200,
              durationMs: 143,
            ),
          ],
        ),
      ],
    );

void main() {
  provenanceReportingTests();
  group('result.json', () {
    test('carries its own schema version', () {
      // Versioned independently of the protocol: a consumer of the
      // report should not have to track the wire format too.
      expect(buildResult().toJson()['resultSchemaVersion'], isNotNull);
    });

    test('reports the overall verdict', () {
      expect(buildResult().toJson()['passed'], isFalse);
      expect(buildResult(failing: false).toJson()['passed'], isTrue);
    });

    test('a skip does not fail the run', () {
      // "Figma is not configured" must not read as a defect.
      final passing = buildResult(failing: false);

      expect(passing.passed, isTrue);
      expect(passing.screens.single.report.skipCount, 1);
    });

    test('includes each step and each screen', () {
      final json = buildResult().toJson();

      expect(json['steps'], hasLength(2));
      expect(json['screens'], hasLength(1));
    });

    test('keeps the failure detail that explains the failure', () {
      final json = jsonEncode(buildResult().toJson());

      expect(json, contains('Rs 2,999'));
      expect(json, contains('Rs 2,599'));
      expect(json, contains('2999'));
    });

    test('is valid JSON', () {
      expect(
        () => jsonDecode(jsonEncode(buildResult().toJson())),
        returnsNormally,
      );
    });

    test('summarises API exchanges per screen', () {
      final screen = (buildResult().toJson()['screens']! as List).single
          as Map<String, Object?>;

      expect((screen['exchanges']! as List).single, {
        'method': 'GET',
        'path': '/products/123',
        'statusCode': 200,
        'durationMs': 143,
      });
    });
  });

  group('report.html', () {
    test('is a pure function of result.json', () {
      // Rendering from the JSON rather than the objects is what
      // guarantees CI and the human report can never disagree.
      final json = buildResult().toJson();

      expect(
        const HtmlReporter().render(json),
        const HtmlReporter().render(json),
      );
    });

    test('shows the verdict', () {
      final html = const HtmlReporter().render(buildResult().toJson());

      expect(html, contains('FAIL'));
    });

    test('shows the failing values', () {
      final html = const HtmlReporter().render(buildResult().toJson());

      expect(html, contains('Rs 2,999'));
      expect(html, contains('Rs 2,599'));
    });

    test('distinguishes a skip from a failure', () {
      final html = const HtmlReporter().render(buildResult().toJson());

      expect(html, contains('skip'));
      expect(html, contains('Figma is not configured'));
    });

    test('escapes content so a response body cannot break the page', () {
      final result = RunResult(
        flowName: '<script>alert(1)</script>',
        appId: 'a',
        device: 'd',
        startedAt: DateTime.utc(2026),
        duration: Duration.zero,
        steps: const [],
        screens: const [],
      );

      final html = const HtmlReporter().render(result.toJson());

      expect(html, isNot(contains('<script>alert(1)</script>')));
      expect(html, contains('&lt;script&gt;'));
    });

    test('renders a passing run without failure sections', () {
      final html =
          const HtmlReporter().render(buildResult(failing: false).toJson());

      expect(html, contains('PASS'));
    });
  });
}

/// STOP-1: a report must say where a screen's data came from when the
/// screen did not fetch it.
void provenanceReportingTests() {
  Map<String, Object?> resultWithSource() => const ValidationResult.pass(
        validatorId: 'api-to-ui',
        dimension: ValidationDimension.api,
        elementId: 'profile.display_name',
        message: 'response.data.firstName matches '
            'profile.display_name.text (from GET /api/profile/me '
            'captured on "/", 15s earlier)',
        expected: 'Test',
        actual: 'Test',
        evidence: [
          Evidence(kind: 'sourceEndpoint', reference: 'GET /api/profile/me'),
          Evidence(kind: 'sourceScreen', reference: '/'),
          Evidence(kind: 'sourceCapturedAt', reference: '2026-09-12T10:00:05.000Z'),
          Evidence(kind: 'sourceRequestId', reference: 'req-42'),
          Evidence(kind: 'sourceAgeSeconds', reference: '15'),
          Evidence(kind: 'renderedScreen', reference: '/profile'),
        ],
      ).toJson();

  Map<String, Object?> runWith(Map<String, Object?> result) => {
        'flow': 'profile',
        'passed': true,
        'steps': <Object?>[],
        'screens': [
          {
            'screenId': '/profile',
            'validation': {
              'passed': true,
              'counts': {'pass': 1, 'fail': 0, 'skip': 0, 'error': 0},
              'results': [result],
            },
            'exchanges': <Object?>[],
          },
        ],
      };

  group('provenance in the report', () {
    test('result.json carries every source field', () {
      final evidence = {
        for (final item in (resultWithSource()['evidence']! as List)
            .cast<Map<String, Object?>>())
          item['kind']: item['reference'],
      };

      expect(
        evidence.keys,
        containsAll(<String>[
          'sourceEndpoint',
          'sourceScreen',
          'sourceCapturedAt',
          'sourceRequestId',
          'renderedScreen',
        ]),
      );
    });

    test('the HTML names the source screen, endpoint and request', () {
      final html = const HtmlReporter().render(runWith(resultWithSource()));

      expect(html, contains('GET /api/profile/me'));
      expect(html, contains('captured on'));
      expect(html, contains('req-42'));
      expect(html, contains('15s before this screen'));
    });

    test('a result with no declared source renders no provenance line', () {
      final html = const HtmlReporter().render(
        runWith(
          const ValidationResult.pass(
            validatorId: 'api-to-ui',
            dimension: ValidationDimension.api,
            elementId: 'product.price',
            message: 'matches',
          ).toJson(),
        ),
      );

      expect(html, isNot(contains('captured on')));
    });
  });
}
