import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

void main() {
  group('ValidationResult', () {
    test('a pass carries no failure detail', () {
      const result = ValidationResult.pass(
        validatorId: 'api-to-ui',
        elementId: 'product.price',
        message: 'matches',
      );

      expect(result.status, ValidationStatus.pass);
      expect(result.isFailure, isFalse);
    });

    test('a failure carries what was expected and what was found', () {
      const result = ValidationResult.fail(
        validatorId: 'api-to-ui',
        elementId: 'product.price',
        message: 'price mismatch',
        expected: 'Rs 2,999',
        actual: 'Rs 2,599',
      );

      expect(result.isFailure, isTrue);
      expect(result.expected, 'Rs 2,999');
      expect(result.actual, 'Rs 2,599');
    });

    test('skip is distinct from fail', () {
      // "Figma is not configured" and "the price is wrong" must never
      // render as the same red X; conflating them teaches people to
      // ignore failures.
      const result = ValidationResult.skip(
        validatorId: 'figma',
        message: 'no Figma spec configured',
      );

      expect(result.status, ValidationStatus.skip);
      expect(result.isFailure, isFalse);
    });

    test('error is distinct from fail', () {
      // The validator could not run. That is not the same as the
      // application being wrong.
      const result = ValidationResult.error(
        validatorId: 'api-to-ui',
        message: 'no API response captured for this screen',
      );

      expect(result.status, ValidationStatus.error);
      expect(result.isFailure, isFalse);
      expect(result.blocksPass, isTrue);
    });

    test('never carries a confidence score', () {
      // A deterministic comparison either matched or it did not.
      // Confidence attaches only to AI suggestions. This is asserted so
      // that adding one becomes a deliberate, visible act.
      const result = ValidationResult.fail(
        validatorId: 'x',
        message: 'y',
      );

      expect(
        result.toJson().keys,
        isNot(contains('confidence')),
      );
    });

    test('never carries a confidence score at any depth', () {
      // `facts` is a map, and a top-level key check cannot see inside
      // it. E-02 added that map for coverage counts; this asserts the
      // guarantee still holds one level down, where it would otherwise
      // have quietly stopped applying.
      final result = ValidationResult.pass(
        validatorId: 'figma-coverage',
        message: 'coverage',
        facts: const {
          'totalNodes': 181,
          'nested': {'comparedNodes': 8},
        },
      );

      expect(_keysDeep(result.toJson()), isNot(contains('confidence')));
    });

    test('serialises for result.json', () {
      const result = ValidationResult.fail(
        validatorId: 'api-to-ui',
        elementId: 'product.price',
        message: 'price mismatch',
        expected: 'Rs 2,999',
        actual: 'Rs 2,599',
      );

      final json = result.toJson();

      expect(json['status'], 'fail');
      expect(json['validatorId'], 'api-to-ui');
      expect(json['elementId'], 'product.price');
      expect(json['expected'], 'Rs 2,999');
    });
  });

  group('ValidationReport', () {
    // Each result names the dimension it actually represents. A report
    // now refuses one that does not, because a result belonging to no
    // dimension belongs to no verdict either.
    test('passes only when nothing failed or errored', () {
      final passing = ValidationReport(const [
        ValidationResult.pass(
          validatorId: 'ui-presence',
          message: 'ok',
          dimension: ValidationDimension.ui,
        ),
        ValidationResult.skip(
          validatorId: 'figma',
          message: 'not configured',
          dimension: ValidationDimension.figma,
        ),
      ]);

      expect(passing.passed, isTrue);
    });

    test('a single failure fails the report', () {
      final report = ValidationReport(const [
        ValidationResult.pass(
          validatorId: 'ui-presence',
          message: 'ok',
          dimension: ValidationDimension.ui,
        ),
        ValidationResult.fail(
          validatorId: 'api-to-ui',
          message: 'wrong',
          dimension: ValidationDimension.api,
        ),
      ]);

      expect(report.passed, isFalse);
      expect(report.failures, hasLength(1));
    });

    test('an error also fails the report', () {
      // A validator that could not run has not shown the screen to be
      // correct, so the report must not claim it is.
      final report = ValidationReport(const [
        ValidationResult.error(
          validatorId: 'api-to-ui',
          message: 'no data',
          dimension: ValidationDimension.api,
        ),
      ]);

      expect(report.passed, isFalse);
    });

    test('counts each status separately', () {
      // Spread across dimensions on purpose: the counts are a property
      // of the report, not of any one dimension.
      final report = ValidationReport(const [
        ValidationResult.pass(
          validatorId: 'a',
          message: '',
          dimension: ValidationDimension.ui,
        ),
        ValidationResult.pass(
          validatorId: 'b',
          message: '',
          dimension: ValidationDimension.api,
        ),
        ValidationResult.fail(
          validatorId: 'c',
          message: '',
          dimension: ValidationDimension.ui,
        ),
        ValidationResult.skip(
          validatorId: 'd',
          message: '',
          dimension: ValidationDimension.figma,
        ),
        ValidationResult.error(
          validatorId: 'e',
          message: '',
          dimension: ValidationDimension.visual,
        ),
      ]);

      expect(report.passCount, 2);
      expect(report.failCount, 1);
      expect(report.skipCount, 1);
      expect(report.errorCount, 1);
    });
  });

  group('transformations', () {
    final registry = TransformationRegistry.defaults();

    test('identity passes the value through', () {
      expect(registry.apply('identity', 2999), 2999);
    });

    test('currency formats an amount the way the app should', () {
      expect(registry.apply('currency(INR)', 2999), 'Rs 2,999');
      expect(registry.apply('currency(INR)', 999), 'Rs 999');
      expect(registry.apply('currency(INR)', 1234567), 'Rs 1,234,567');
    });

    test('percent renders a discount badge', () {
      expect(registry.apply('percent', 15), '15% off');
    });

    test('negate inverts a boolean', () {
      // "available == false" means "the unavailable notice is visible".
      expect(registry.apply('negate', false), true);
      expect(registry.apply('negate', true), false);
    });

    test('toText stringifies', () {
      expect(registry.apply('toText', 2999), '2999');
    });

    test('an unknown transformation is an error naming what exists', () {
      // Silently falling back to identity would make a typo look like a
      // passing test.
      expect(
        () => registry.apply('currancy(INR)', 1),
        throwsA(
          isA<UnknownTransformationException>()
              .having((e) => e.toString(), 'message', contains('currancy'))
              .having((e) => e.toString(), 'message', contains('currency')),
        ),
      );
    });

    test('a transformation given the wrong type errors rather than guesses',
        () {
      expect(
        () => registry.apply('currency(INR)', 'not a number'),
        throwsA(isA<TransformationFailedException>()),
      );
    });

    test('a null value passes through untransformed', () {
      // Absent data is a separate finding from wrongly formatted data.
      expect(registry.apply('currency(INR)', null), isNull);
    });

    test('parses arguments out of the spec', () {
      expect(registry.resolve('currency(INR)').name, 'currency');
      expect(registry.resolve('currency(INR)').arguments, ['INR']);
      expect(registry.resolve('identity').arguments, isEmpty);
    });

    test('lists what it knows, for diagnostics', () {
      expect(
        registry.names,
        containsAll(<String>['identity', 'currency', 'percent', 'negate']),
      );
    });
  });
}

/// Every key in a JSON tree, however deeply nested.
Set<String> _keysDeep(Object? node) {
  final keys = <String>{};
  if (node is Map) {
    for (final entry in node.entries) {
      keys.add(entry.key.toString());
      keys.addAll(_keysDeep(entry.value));
    }
  } else if (node is List) {
    for (final item in node) {
      keys.addAll(_keysDeep(item));
    }
  }
  return keys;
}
