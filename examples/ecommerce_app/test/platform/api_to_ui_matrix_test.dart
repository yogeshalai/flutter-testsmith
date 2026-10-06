import 'package:ecommerce_app/api/api_client.dart';
import 'package:ecommerce_app/api/defects.dart';
import 'package:ecommerce_app/api/models.dart';
import 'package:ecommerce_app/product_details_screen.dart'
    show ProductDetailsScreen;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/engine.dart';

import 'harness.dart';

/// Phase 12, brief items 2 and 3.
///
/// Every row drives the real widgets through the real
/// [UiTreeInspector] and the real [ApiToUiValidator], against a body
/// taken from a real fixture file. The assertion is always the same
/// shape: which validator, about which element, with what status - and,
/// for a failure, that the report carries the raw API value, what the
/// declared transformation says it should become, and what the UI
/// actually shows.
///
/// No AI is involved in any verdict here, and there is nothing in the
/// code path that could be.

final matrix = MatrixRecorder(
  'API to UI validation matrix',
  'docs/evidence/api_to_ui_matrix.md',
  const [
    'Case',
    'Fixture',
    'API path',
    'Raw API value',
    'Transformation',
    'Transformed',
    'Element',
    'UI value',
    'Validator',
    'Status',
  ],
);

/// Renders ProductDetails from a fixture and validates it.
Future<ValidationReport> productDetails(
  WidgetTester tester,
  String fixture,
) async {
  final body = fixtureBody(fixture, 'GET', '/products/123');

  final snapshot = await pumpAndCapture(
    tester,
    ProductDetailsScreen(fetchProduct: () async => Product.fromJson(body)),
    screenId: '/product/details',
  );

  return validate(
    snapshot: snapshot,
    response: responseFrom(body),
    mappings: mappingsFor('product_details'),
  );
}

/// Records a row and returns the result, so an assertion reads once.
ValidationResult record({
  required String label,
  required String fixture,
  required ValidationReport report,
  required String validatorId,
  required String elementId,
}) {
  final result = resultFor(report, validatorId, elementId);
  matrix.add([
    label,
    fixture,
    evidence(result, 'apiPath') ?? '-',
    evidence(result, 'apiValue') ?? '-',
    evidence(result, 'transformation') ?? '-',
    evidence(result, 'transformedValue') ?? '${result.expected ?? '-'}',
    elementId,
    evidence(result, 'uiValue') ?? '${result.actual ?? '-'}',
    validatorId,
    result.status.wire.toUpperCase(),
  ]);
  return result;
}

void main() {
  setUp(resetDefects);
  tearDownAll(() => matrix.write(
        preamble: 'Each row is one execution of the deterministic '
            'validators over the real application widgets, with the body '
            'read from the named fixture file. `mappings/*.yaml` supplies '
            'the transformation; nothing here consults a model.',
      ));

  group('API success - the response is correct and so is the screen', () {
    testWidgets('normal response', (tester) async {
      final report = await productDetails(tester, 'default');

      final price = record(
        label: 'normal response',
        fixture: 'default',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.price',
      );
      expect(price.status, ValidationStatus.pass);
      expect(evidence(price, 'apiValue'), '90');
      expect(evidence(price, 'uiValue'), 'Rs 90');

      final name = record(
        label: 'normal response',
        fixture: 'default',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.name',
      );
      expect(name.status, ValidationStatus.pass);
      expect(report.passed, isTrue, reason: '${report.failures}');
    });

    testWidgets('zero value - a free sample, not a falsy nothing',
        (tester) async {
      final report = await productDetails(tester, 'product_zero_price');

      final price = record(
        label: 'zero value',
        fixture: 'product_zero_price',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.price',
      );
      expect(price.status, ValidationStatus.pass);
      expect(evidence(price, 'apiValue'), '0');
      // The failure mode this row exists for: `if (price)` renders
      // nothing, and the screen shows a blank where "Rs 0" belongs.
      expect(evidence(price, 'uiValue'), 'Rs 0');
    });

    testWidgets('large value groups correctly', (tester) async {
      final report = await productDetails(tester, 'product_large_values');

      final price = record(
        label: 'large value',
        fixture: 'product_large_values',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.price',
      );
      expect(price.status, ValidationStatus.pass);
      expect(evidence(price, 'uiValue'), 'Rs 98,765,432');
    });

    testWidgets('null fields render a placeholder, not a broken box',
        (tester) async {
      final report = await productDetails(tester, 'product_null_fields');

      final price = record(
        label: 'null image and rating',
        fixture: 'product_null_fields',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.price',
      );
      expect(price.status, ValidationStatus.pass);
      expect(report.passed, isTrue, reason: '${report.failures}');
    });

    testWidgets('an empty string name becomes a placeholder', (tester) async {
      final body = fixtureBody('product_empty_name', 'GET', '/products/123');
      final snapshot = await pumpAndCapture(
        tester,
        ProductDetailsScreen(fetchProduct: () async => Product.fromJson(body)),
        screenId: '/product/details',
      );
      final report = validate(
        snapshot: snapshot,
        response: responseFrom(body),
        mappings: mappingsFor('product_details'),
      );

      final name = record(
        label: 'empty string name',
        fixture: 'product_empty_name',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.name',
      );
      // An empty name and the placeholder that replaces it genuinely
      // disagree, and the platform says so. That is correct: the screen
      // is showing something the API did not send, and whether that is
      // acceptable is a product decision, not a silent one.
      expect(name.status, ValidationStatus.fail);
      expect(evidence(name, 'uiValue'), 'Unnamed product');
    });

    testWidgets('a missing field fails, and says which field', (tester) async {
      final report = await productDetails(tester, 'product_missing_price');

      final price = record(
        label: 'missing price field',
        fixture: 'product_missing_price',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.price',
      );
      expect(price.status, ValidationStatus.fail);
      expect(price.message, contains('has no field "price"'));
    });
  });

  group('conditional UI - rules over the response', () {
    testWidgets('out of stock disables Add to Cart and shows the notice',
        (tester) async {
      final report = await productDetails(tester, 'product_out_of_stock');

      final rule = record(
        label: 'out of stock (rule)',
        fixture: 'product_out_of_stock',
        report: report,
        validatorId: 'rules',
        elementId: 'product.add_to_cart',
      );
      expect(rule.status, ValidationStatus.pass);

      final mapped = record(
        label: 'out of stock (mapping)',
        fixture: 'product_out_of_stock',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.add_to_cart',
      );
      expect(mapped.status, ValidationStatus.pass);
      expect(evidence(mapped, 'apiValue'), 'false');
      expect(evidence(mapped, 'uiValue'), 'false');
    });

    testWidgets('a discount shows the badge', (tester) async {
      final report = await productDetails(tester, 'product_discounted');

      final rule = record(
        label: 'discounted',
        fixture: 'product_discounted',
        report: report,
        validatorId: 'rules',
        elementId: 'product.discount_badge',
      );
      expect(rule.status, ValidationStatus.pass);
    });

    testWidgets('no discount hides the badge', (tester) async {
      final report = await productDetails(tester, 'default');

      final rule = record(
        label: 'no discount',
        fixture: 'default',
        report: report,
        validatorId: 'rules',
        elementId: 'product.discount_badge',
      );
      expect(rule.status, ValidationStatus.pass);
    });
  });

  group('seeded defects - the API is right and the screen is wrong', () {
    testWidgets('D1 price 2999 rendered as 2599', (tester) async {
      // The specification's motivating example, end to end.
      Defects.current = const Defects(priceOffBy: 400);
      final report = await productDetails(tester, 'product_large_values');

      final price = record(
        label: 'DEFECT price off by 400',
        fixture: 'product_large_values',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.price',
      );

      expect(price.status, ValidationStatus.fail);
      expect(evidence(price, 'apiValue'), '98765432');
      expect(evidence(price, 'transformedValue'), 'Rs 98,765,432');
      expect(evidence(price, 'uiValue'), 'Rs 98,765,032');
      // All three in the message too, because that triple is what
      // separates a data bug from a formatting bug.
      expect(price.message, contains('98765432'));
      expect(price.message, contains('Rs 98,765,032'));
      expect(report.passed, isFalse);
    });

    testWidgets('D2 available=false but Add to Cart stays enabled',
        (tester) async {
      Defects.current = const Defects(ignoreAvailability: true);
      final report = await productDetails(tester, 'product_out_of_stock');

      final mapped = record(
        label: 'DEFECT availability ignored (mapping)',
        fixture: 'product_out_of_stock',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.add_to_cart',
      );
      expect(mapped.status, ValidationStatus.fail);
      expect(evidence(mapped, 'apiValue'), 'false');
      expect(evidence(mapped, 'uiValue'), 'true');

      final rule = record(
        label: 'DEFECT availability ignored (rule)',
        fixture: 'product_out_of_stock',
        report: report,
        validatorId: 'rules',
        elementId: 'product.add_to_cart',
      );
      // Two independent checks catch it: the mapping compares the value,
      // the rule asserts the consequence. Redundant on purpose - a
      // project with no rules still gets the mapping.
      expect(rule.status, ValidationStatus.fail);
    });

    testWidgets('D3 "Nike Air Max" rendered as "Nike Air"', (tester) async {
      Defects.current = const Defects(truncateNameTo: 8);
      final body = fixtureBody('default', 'GET', '/products/789');
      final snapshot = await pumpAndCapture(
        tester,
        ProductDetailsScreen(fetchProduct: () async => Product.fromJson(body)),
        screenId: '/product/details',
      );
      final report = validate(
        snapshot: snapshot,
        response: responseFrom(body),
        mappings: mappingsFor('product_details'),
      );

      final name = record(
        label: 'DEFECT name truncated',
        fixture: 'default (/products/789)',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.name',
      );
      expect(name.status, ValidationStatus.fail);
      expect(evidence(name, 'apiValue'), 'Nike Air Max');
      expect(evidence(name, 'uiValue'), 'Nike Air');
    });

    testWidgets('D4 image is null but the image widget is rendered anyway',
        (tester) async {
      Defects.current = const Defects(renderImageWhenNull: true);
      final body = fixtureBody('product_null_fields', 'GET', '/products/123');
      final snapshot = await pumpAndCapture(
        tester,
        ProductDetailsScreen(fetchProduct: () async => Product.fromJson(body)),
        screenId: '/product/details',
      );

      // Caught structurally rather than by a value comparison: the
      // placeholder the design requires is simply not on the screen.
      // A mapping cannot express this - there is no API value to compare
      // an absent widget against - which is why presence is its own
      // check.
      expect(snapshot.find('product.image_placeholder'), isNull);
      expect(snapshot.find('product.image'), isNotNull);

      matrix.add([
        'DEFECT null image still rendered',
        'product_null_fields',
        'response.image',
        'null',
        '-',
        'product.image_placeholder present',
        'product.image_placeholder',
        'absent',
        'ui-presence (structural)',
        'FAIL',
      ]);

      // And the same screen, built correctly, does show it.
      Defects.current = Defects.none;
      final correct = await pumpAndCapture(
        tester,
        ProductDetailsScreen(fetchProduct: () async => Product.fromJson(body)),
        screenId: '/product/details',
      );
      expect(correct.find('product.image_placeholder'), isNotNull);
    });

    testWidgets('D5 discount badge shown when the discount is zero',
        (tester) async {
      Defects.current = const Defects(showDiscountWhenZero: true);
      final report = await productDetails(tester, 'default');

      final rule = record(
        label: 'DEFECT discount badge at zero',
        fixture: 'default',
        report: report,
        validatorId: 'rules',
        elementId: 'product.discount_badge',
      );
      expect(rule.status, ValidationStatus.fail);
      expect(rule.message, contains('discount == 0'));
    });

    testWidgets('D6 wrong currency symbol', (tester) async {
      Defects.current = const Defects(currencySymbol: r'$');
      final report = await productDetails(tester, 'default');

      final price = record(
        label: 'DEFECT currency symbol',
        fixture: 'default',
        report: report,
        validatorId: 'api-to-ui',
        elementId: 'product.price',
      );
      expect(price.status, ValidationStatus.fail);
      expect(evidence(price, 'transformedValue'), 'Rs 90');
      expect(evidence(price, 'uiValue'), r'$90');
      // The data is right and the formatting is wrong, and the report
      // shows exactly that: same number, different rendering.
      expect(evidence(price, 'apiValue'), '90');
    });
  });

  group('a validator with nothing to compare', () {
    testWidgets('reports error, not fail, and still blocks the pass',
        (tester) async {
      // "The price is wrong" and "the API never answered" must not
      // render as the same red X: conflating them teaches people to
      // ignore failures. But an unanswered API has not shown the screen
      // to be correct either, so error blocks the pass just as a
      // failure does.
      final snapshot = await pumpAndCapture(
        tester,
        ProductDetailsScreen(
          fetchProduct: () async =>
              throw const ApiException('boom', statusCode: 500),
        ),
        screenId: '/product/details',
      );

      final session = ScreenSession(
        screenId: '/product/details',
        enteredAt: DateTime.now().toUtc(),
      )..uiSnapshot = snapshot;

      final report = ValidationReport(
        runValidator(
          const ApiToUiValidator(),
          ValidationContext(
            session: session,
            mappings: mappingsFor('product_details'),
          ),
        ),
      );

      expect(report.results.single.status, ValidationStatus.error);
      expect(report.failCount, 0);
      expect(report.errorCount, 1);
      expect(report.passed, isFalse);

      matrix.add([
        'no response to compare',
        '(HTTP 500)',
        '-',
        '-',
        '-',
        '-',
        '(whole screen)',
        '-',
        'api-to-ui',
        'ERROR',
      ]);
    });

    testWidgets('a screen with no mappings skips rather than passing',
        (tester) async {
      // A dimension that was never checked must not read as evidence
      // the screen is correct.
      final snapshot = await pumpAndCapture(
        tester,
        ProductDetailsScreen(
          fetchProduct: () async => Product.fromJson(
            fixtureBody('default', 'GET', '/products/123'),
          ),
        ),
        screenId: '/product/details',
      );

      final session = ScreenSession(
        screenId: '/nowhere',
        enteredAt: DateTime.now().toUtc(),
      )..uiSnapshot = snapshot;

      final report = ValidationReport(
        runValidator(
          const ApiToUiValidator(),
          ValidationContext(session: session),
        ),
      );

      expect(report.results.single.status, ValidationStatus.skip);
      expect(report.passCount, 0);
      expect(report.skipCount, 1);
    });
  });

  group('the line that must never blur', () {
    testWidgets('no deterministic result carries a confidence', (tester) async {
      final report = await productDetails(tester, 'default');

      for (final result in report.results) {
        expect(
          result.toJson().keys,
          isNot(contains('confidence')),
          reason: 'a deterministic comparison either matched or it did not',
        );
      }
    });
  });
}
