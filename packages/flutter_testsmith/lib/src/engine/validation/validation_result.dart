import 'package:meta/meta.dart';

import 'validation_dimension.dart';

/// Four outcomes, deliberately distinct.
///
/// `skip` and `error` are not `fail`. "Figma is not configured" and "the
/// price is wrong" must never render as the same red X - conflating them
/// teaches people to ignore failures. But `error` still blocks a pass: a
/// validator that could not run has not shown the screen to be correct.
enum ValidationStatus {
  pass('pass'),
  fail('fail'),
  skip('skip'),
  error('error');

  const ValidationStatus(this.wire);

  final String wire;
}

enum Severity {
  info('info'),
  warning('warning'),
  critical('critical');

  const Severity(this.wire);

  final String wire;
}

/// Where to look for the evidence behind a result.
@immutable
class Evidence {
  const Evidence({required this.kind, required this.reference});

  final String kind;
  final String reference;

  Map<String, Object?> toJson() => {'kind': kind, 'reference': reference};
}

/// One deterministic finding.
///
/// Note what is absent: there is no confidence field, and a test asserts
/// there never is one. A deterministic comparison either matched or it
/// did not; a probability here would blur the line that makes the whole
/// platform trustworthy. Confidence attaches only to AI *suggestions*.
@immutable
class ValidationResult {
  const ValidationResult._({
    required this.validatorId,
    required this.status,
    required this.message,
    this.severity = Severity.critical,
    this.elementId,
    this.expected,
    this.actual,
    this.evidence = const [],
    this.facts = const {},
    this.dimension,
  });

  const ValidationResult.pass({
    required String validatorId,
    required String message,
    String? elementId,
    Object? expected,
    Object? actual,
    List<Evidence> evidence = const [],
    Map<String, Object?> facts = const {},
    ValidationDimension? dimension,
  }) : this._(
          validatorId: validatorId,
          status: ValidationStatus.pass,
          message: message,
          elementId: elementId,
          expected: expected,
          actual: actual,
          evidence: evidence,
          facts: facts,
          severity: Severity.info,
          dimension: dimension,
        );

  const ValidationResult.fail({
    required String validatorId,
    required String message,
    String? elementId,
    Object? expected,
    Object? actual,
    Severity severity = Severity.critical,
    List<Evidence> evidence = const [],
    ValidationDimension? dimension,
  }) : this._(
          validatorId: validatorId,
          status: ValidationStatus.fail,
          message: message,
          elementId: elementId,
          expected: expected,
          actual: actual,
          severity: severity,
          evidence: evidence,
          dimension: dimension,
        );

  const ValidationResult.skip({
    required String validatorId,
    required String message,
    String? elementId,
    ValidationDimension? dimension,
  }) : this._(
          validatorId: validatorId,
          status: ValidationStatus.skip,
          message: message,
          elementId: elementId,
          severity: Severity.info,
          dimension: dimension,
        );

  const ValidationResult.error({
    required String validatorId,
    required String message,
    String? elementId,
    ValidationDimension? dimension,
  }) : this._(
          validatorId: validatorId,
          status: ValidationStatus.error,
          message: message,
          elementId: elementId,
          dimension: dimension,
        );

  final String validatorId;
  final ValidationStatus status;
  final String message;
  final Severity severity;
  final String? elementId;
  final Object? expected;
  final Object? actual;
  final List<Evidence> evidence;

  /// Counted facts about the comparison, for a reader that is a program.
  ///
  /// Deliberately narrow. This is not a general-purpose bag: it exists so
  /// coverage - how much of a design a verdict actually speaks for - can
  /// be read out of `result.json` without parsing prose. A test asserts
  /// that nothing here ever carries a confidence, at any depth, because
  /// the moment a deterministic result can be qualified by a probability
  /// the line this platform is built on stops meaning anything.
  final Map<String, Object?> facts;

  /// Which source of truth this was measured against.
  ///
  /// Null only between construction and the producing validator stamping
  /// its default. Nothing that reaches a report carries a null, and a
  /// test asserts it.
  final ValidationDimension? dimension;

  /// This result with [fallback] applied, if it does not already name a
  /// dimension.
  ///
  /// An explicit dimension always wins: a validator whose default is
  /// `api` still emits `ui` results when the reason it could not compare
  /// was that the UI could not be read.
  ValidationResult inDimension(ValidationDimension fallback) =>
      dimension != null
          ? this
          : ValidationResult._(
              validatorId: validatorId,
              status: status,
              message: message,
              severity: severity,
              elementId: elementId,
              expected: expected,
              actual: actual,
              evidence: evidence,
              facts: facts,
              dimension: fallback,
            );

  bool get isFailure => status == ValidationStatus.fail;

  /// Whether this result prevents the screen being reported as correct.
  bool get blocksPass =>
      status == ValidationStatus.fail || status == ValidationStatus.error;

  Map<String, Object?> toJson() => {
        'validatorId': validatorId,
        'status': status.wire,
        'severity': severity.wire,
        if (dimension != null) 'dimension': dimension!.wire,
        'message': message,
        if (elementId != null) 'elementId': elementId,
        if (expected != null) 'expected': expected.toString(),
        if (actual != null) 'actual': actual.toString(),
        if (evidence.isNotEmpty)
          'evidence': [for (final e in evidence) e.toJson()],
        if (facts.isNotEmpty) 'facts': facts,
      };

  @override
  String toString() =>
      '[${status.wire}] $validatorId${elementId == null ? '' : ' $elementId'}: '
      '$message';
}

/// A result reached a report without saying which dimension it belongs
/// to.
///
/// An **infrastructure** failure, not a verdict. It says this engine
/// produced something it cannot account for, which means the screen was
/// not trustworthily judged - it does not say the application is wrong,
/// and `isInfrastructureFailure` recognises it so that nothing downstream
/// can read it as one.
///
/// Carries the validator and the status and nothing else. A result's
/// message can quote what a screen displayed, and a diagnostic about a
/// bookkeeping mistake has no business repeating it.
@immutable
class UndimensionedResultException implements Exception {
  const UndimensionedResultException({
    required this.validatorId,
    required this.status,
  });

  final String validatorId;
  final ValidationStatus status;

  @override
  String toString() =>
      'UndimensionedResultException: "$validatorId" produced a '
      '${status.wire} result that names no dimension, so it would belong '
      'to no dimension block and be invisible to the overall verdict.\n'
      'Every result entering a report must say what it was measured '
      'against. A validator that leaves it unset is stamped by '
      '`runValidator`; one that reaches here was built somewhere that '
      'does not stamp.';
}

/// Every result for one screen.
///
/// **The boundary that makes the dimension invariant structural.** Past
/// this constructor, every consumer - `verdictFor`, `RunResult.overall`,
/// the reporters, suite classification - can rely on raw evidence and
/// dimension evidence being the same evidence.
///
/// Enforced here rather than on [ValidationResult] itself, and the
/// reason is what the constructions actually look like. Of roughly 93
/// result constructions in this repository, about 78 deliberately omit
/// the dimension: a validator states what it found, and `runValidator`
/// stamps the validator's own dimension onto it once, in one place.
/// Requiring it at each construction would trade one correct stamp for
/// 78 literals free to drift - a weaker guarantee wearing a stronger
/// type. The nullable field is the *unstamped intermediate state*, and
/// this is where that state stops being allowed.
@immutable
class ValidationReport {
  ValidationReport(this.results) {
    for (final result in results) {
      if (result.dimension != null) continue;
      // Refused rather than dropped. Filtering it away is exactly the
      // defect: `verdictFor` matches on dimension, so an unstamped FAIL
      // or ERROR sat in `results` and in no block at all, leaving the
      // overall verdict free to disagree with the evidence beneath it.
      throw UndimensionedResultException(
        validatorId: result.validatorId,
        status: result.status,
      );
    }
  }

  final List<ValidationResult> results;

  /// True only when nothing failed and nothing errored.
  bool get passed => !results.any((r) => r.blocksPass);

  List<ValidationResult> get failures =>
      [for (final r in results) if (r.isFailure) r];

  int get passCount => _count(ValidationStatus.pass);
  int get failCount => _count(ValidationStatus.fail);
  int get skipCount => _count(ValidationStatus.skip);
  int get errorCount => _count(ValidationStatus.error);

  int _count(ValidationStatus status) =>
      results.where((r) => r.status == status).length;

  Map<String, Object?> toJson() => {
        'passed': passed,
        'counts': {
          'pass': passCount,
          'fail': failCount,
          'skip': skipCount,
          'error': errorCount,
        },
        'results': [for (final r in results) r.toJson()],
      };
}
