import 'package:meta/meta.dart';

import '../validation/validation_dimension.dart';
import '../validation/validation_result.dart';

/// One dimension's verdict, and what it rests on.
@immutable
class DimensionVerdict {
  const DimensionVerdict({
    required this.dimension,
    required this.status,
    required this.counts,
    this.reason,
  });

  final ValidationDimension dimension;
  final ValidationStatus status;

  /// How many results of each status contributed.
  final Map<String, int> counts;

  /// Why this is not a PASS. Null when it is.
  ///
  /// Taken from the first result that decided the verdict, so a reader
  /// gets the actionable sentence without opening the detail.
  final String? reason;

  Map<String, Object?> toJson() => {
        'status': status.wire,
        'counts': counts,
        if (reason != null) 'reason': reason,
      };

  @override
  String toString() => '${dimension.wire}: ${status.wire}';
}

/// E-03's precedence, applied to a set of statuses.
///
/// ERROR > FAIL > PASS > SKIP. SKIP last is the line that does the work:
/// a dimension that was never checked reports SKIP and never PASS,
/// because a PASS is a positive claim and a claim needs something to
/// have been compared.
///
/// ERROR outranking FAIL preserves E-04: a run that could not answer the
/// question must not read as a run that answered it.
ValidationStatus aggregateStatus(Iterable<ValidationStatus> statuses) {
  var sawPass = false;
  var sawFail = false;
  for (final status in statuses) {
    switch (status) {
      case ValidationStatus.error:
        return ValidationStatus.error;
      case ValidationStatus.fail:
        sawFail = true;
      case ValidationStatus.pass:
        sawPass = true;
      case ValidationStatus.skip:
        break;
    }
  }
  if (sawFail) return ValidationStatus.fail;
  if (sawPass) return ValidationStatus.pass;
  return ValidationStatus.skip;
}

/// Builds one dimension's verdict from the results attributed to it.
DimensionVerdict verdictFor(
  ValidationDimension dimension,
  List<ValidationResult> results,
) {
  final status = aggregateStatus(results.map((r) => r.status));

  ValidationResult? firstWith(ValidationStatus wanted) {
    for (final result in results) {
      if (result.status == wanted) return result;
    }
    return null;
  }

  final decisive = switch (status) {
    ValidationStatus.error => firstWith(ValidationStatus.error),
    ValidationStatus.fail => firstWith(ValidationStatus.fail),
    ValidationStatus.skip => firstWith(ValidationStatus.skip),
    ValidationStatus.pass => null,
  };

  return DimensionVerdict(
    dimension: dimension,
    status: status,
    reason: results.isEmpty
        ? 'nothing was checked in this dimension'
        : decisive?.message,
    counts: {
      for (final s in ValidationStatus.values)
        s.wire: results.where((r) => r.status == s).length,
    },
  );
}
