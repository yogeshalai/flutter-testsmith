// Every visual result `FlowExecutor` builds itself carries its dimension.
//
// `VisualValidator` stamps the results it produces. Two paths in
// `_compareVisually` return *before* it is reached - the screen would not
// hold still, and the screenshot could not be taken at all - and those
// results were built unstamped. `ValidationReport` refuses an unstamped
// result, so both paths ended the run with an
// `UndimensionedResultException` instead of the skip and the error they
// are: a screen that could not be photographed reported as a crash.
//
// Neither path is reachable without a device, which is why nothing caught
// them. They are guarded at the source instead, the way
// `step_classification_test` already guards this same file for the same
// reason - the rule is visible in the text, and a device is not.
//
// The behavioural half of the invariant is exercised properly below:
// `ValidationReport` is what enforces it, and it is tested directly.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

String executorSource() {
  for (final candidate in [
    'lib/src/flow_executor.dart',
    'packages/flutter_testsmith_cli/lib/src/flow_executor.dart',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find flow_executor.dart');
}

void main() {
  group('the results FlowExecutor builds for the visual dimension', () {
    test('every VisualValidator result it constructs names a dimension', () {
      // Each `ValidationResult.<kind>(validatorId: VisualValidator.id …)`
      // in this file is a result nothing downstream will stamp.
      final source = executorSource();
      const marker = 'validatorId: VisualValidator.id,';
      final starts = marker.allMatches(source).map((m) => m.start).toList();

      expect(starts, isNotEmpty,
          reason: 'the guard found nothing to guard');

      for (final start in starts) {
        // The argument list this id belongs to: up to the next result
        // construction, or a generous window when it is the last one.
        final next = source.indexOf('ValidationResult.', start);
        final end = next < 0 ? source.length : next;
        final arguments = source.substring(start, end.clamp(start, start + 800));

        expect(
          arguments,
          contains('dimension: ValidationDimension.visual'),
          reason: 'a visual result built here is never stamped by '
              'VisualValidator, and ValidationReport refuses it.\n'
              'Argument list:\n$arguments',
        );
      }
    });
  });

  group('and ValidationReport is what makes that a rule', () {
    // The behaviour the guard above stands in for. Not a duplicate of
    // dimension_invariant_test: this pins the two specific results the
    // executor builds, in the shape it builds them.
    test('an unstamped visual skip is refused', () {
      expect(
        () => ValidationReport([
          ValidationResult.skip(
            validatorId: VisualValidator.id,
            message: 'the screen would not hold still',
          ),
        ]),
        throwsA(isA<UndimensionedResultException>()),
      );
    });

    test('an unstamped visual error is refused', () {
      expect(
        () => ValidationReport([
          ValidationResult.error(
            validatorId: VisualValidator.id,
            message: 'the app cannot take that picture',
          ),
        ]),
        throwsA(isA<UndimensionedResultException>()),
      );
    });

    test('and both are accepted once stamped', () {
      // The negative control: the fix is the stamp, not a weakening of
      // the rule.
      final report = ValidationReport([
        ValidationResult.skip(
          validatorId: VisualValidator.id,
          dimension: ValidationDimension.visual,
          message: 'the screen would not hold still',
        ),
        ValidationResult.error(
          validatorId: VisualValidator.id,
          dimension: ValidationDimension.visual,
          message: 'the app cannot take that picture',
        ),
      ]);

      expect(report.results, hasLength(2));
      expect(report.errorCount, 1);
      expect(report.skipCount, 1);
    });
  });
}
