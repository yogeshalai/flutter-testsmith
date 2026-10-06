import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

RunResult _run(List<ValidationResult> results) => RunResult(
      flowName: 'product_details',
      appId: 'com.example.ecommerce_app',
      device: 'emulator-5554',
      startedAt: DateTime.utc(2026, 9, 15),
      duration: const Duration(seconds: 3),
      steps: const [
        StepOutcome(
          description: 'launch the app',
          kind: StepKind.launchApp,
          status: StepStatus.ok,
          durationMs: 10,
        ),
      ],
      screens: [
        ScreenResult(
          screenId: '/product/details',
          report: ValidationReport(results),
        ),
      ],
    );

void main() {
  test('the report shows every dimension, including the skipped ones', () {
    final html = const HtmlReporter().render(
      _run([
        ValidationResult.pass(
          validatorId: 'api-to-ui',
          message: 'response.price matches product.price.text',
          dimension: ValidationDimension.api,
        ),
        ValidationResult.fail(
          validatorId: 'figma-geometry',
          message: 'width is 282.0px but the design specifies 322.0px',
          dimension: ValidationDimension.figma,
        ),
      ]).toJson(),
    );

    expect(html, contains('API'));
    expect(html, contains('FIGMA'));
    expect(html, contains('UI'));
    expect(html, contains('VISUAL'));
    expect(html, contains('OVERALL'));
    // The failure's own sentence reaches the block, not just a colour.
    expect(html, contains('322.0px'));
    // A dimension nobody checked says so rather than going quiet.
    expect(html, contains('nothing was checked'));
  });

  test('a passing dimension is not rendered as the overall verdict', () {
    final json = _run([
      ValidationResult.pass(
        validatorId: 'api-to-ui',
        message: 'matches',
        dimension: ValidationDimension.api,
      ),
      ValidationResult.fail(
        validatorId: 'figma-geometry',
        message: 'differs',
        dimension: ValidationDimension.figma,
      ),
    ]).toJson();

    expect((json['dimensions']! as Map)['api'], containsPair('status', 'pass'));
    expect(json['overall'], 'fail');
    expect(json['passed'], isFalse);
  });

  test('the HTML is a pure function of the JSON', () {
    final json = _run([
      ValidationResult.pass(
        validatorId: 'api-to-ui',
        message: 'matches',
        dimension: ValidationDimension.api,
      ),
    ]).toJson();
    expect(const HtmlReporter().render(json), const HtmlReporter().render(json));
  });
}
