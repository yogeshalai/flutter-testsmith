import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// How strongly the supplied evidence supports a statement.
///
/// The three levels the specification requires, and they are not
/// decoration: a model that cannot distinguish "the data proves this"
/// from "this is a guess" produces text nobody can safely act on.
enum FindingClass {
  /// Restates only what the deterministic data already establishes.
  confirmedFailure('confirmed_failure'),

  /// A cause the supplied data supports, though does not prove.
  probableCause('probable_cause'),

  /// Plausible, and not established by the data. A lead, not a finding.
  hypothesis('hypothesis');

  const FindingClass(this.wire);

  final String wire;

  /// Parses a value from the model.
  ///
  /// Anything unrecognised becomes [hypothesis] - the weakest claim.
  /// Defaulting the other way would let a malformed response promote a
  /// guess to a certainty, which is the one failure mode this whole
  /// classification exists to prevent.
  static FindingClass parse(Object? value) {
    final text = value?.toString().trim().toLowerCase();
    for (final level in values) {
      if (level.wire == text) return level;
    }
    return hypothesis;
  }
}

/// One explanation, attached to one deterministic failure.
@immutable
class AiFinding {
  const AiFinding({
    required this.validatorId,
    required this.classification,
    required this.explanation,
    this.elementId,
    this.confidence,
    this.suggestedChecks = const [],
  });

  final String validatorId;
  final String? elementId;
  final FindingClass classification;
  final String explanation;

  /// How sure the model says it is, 0..1.
  ///
  /// Confidence lives here and **only** here. A [ValidationResult] has
  /// no such field, and a test asserts it never gains one: a
  /// deterministic comparison either matched or it did not, and a
  /// probability printed beside it would blur the line that makes the
  /// rest of the platform trustworthy.
  final double? confidence;

  /// What a person could do next to settle it.
  final List<String> suggestedChecks;

  Map<String, Object?> toJson() => {
        'validatorId': validatorId,
        if (elementId != null) 'elementId': elementId,
        'classification': classification.wire,
        'explanation': explanation,
        if (confidence != null) 'confidence': confidence,
        if (suggestedChecks.isNotEmpty) 'suggestedChecks': suggestedChecks,
      };

  factory AiFinding.fromJson(Map<String, Object?> json) {
    final confidence = json['confidence'];
    return AiFinding(
      validatorId: (json['validatorId'] ?? 'unknown').toString(),
      elementId: json['elementId']?.toString(),
      classification: FindingClass.parse(json['classification']),
      explanation: (json['explanation'] ?? '').toString(),
      confidence: confidence is num
          ? confidence.toDouble().clamp(0.0, 1.0)
          : null,
      suggestedChecks: [
        for (final check in (json['suggestedChecks'] as List?) ?? const [])
          check.toString(),
      ],
    );
  }

  @override
  String toString() => '[${classification.wire}] $validatorId'
      '${elementId == null ? '' : ' $elementId'}: $explanation';
}

/// What a model said about a run's failures.
///
/// Carried alongside the deterministic result, never inside it. The
/// pass or fail of a run is computed before this is requested and is
/// not a function of anything here.
@immutable
class AiAnalysis {
  const AiAnalysis({
    required this.provider,
    required this.model,
    required this.generatedAt,
    required this.summary,
    required this.findings,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.latency = Duration.zero,
  });

  /// Provenance, so a reader knows who said this.
  final String provider;
  final String model;
  final DateTime generatedAt;

  final String summary;
  final List<AiFinding> findings;

  final int promptTokens;
  final int completionTokens;
  final Duration latency;

  List<AiFinding> ofClass(FindingClass level) =>
      [for (final f in findings) if (f.classification == level) f];

  Map<String, Object?> toJson() => {
        'provider': provider,
        'model': model,
        'generatedAt': formatUtcTimestamp(generatedAt),
        'summary': summary,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'latencyMs': latency.inMilliseconds,
        'findings': [for (final f in findings) f.toJson()],
      };
}

/// Why there is, or is not, an analysis.
///
/// Three outcomes rather than a nullable analysis, for the same reason
/// validation distinguishes skip from error: "nothing failed, so there
/// was nothing to explain" and "the model could not be reached" are
/// different facts, and a report that renders them identically teaches
/// people to ignore both.
sealed class AnalysisOutcome {
  const AnalysisOutcome();

  Map<String, Object?> toJson();
}

/// A model answered.
final class AnalysisReady extends AnalysisOutcome {
  const AnalysisReady(this.analysis);

  final AiAnalysis analysis;

  @override
  Map<String, Object?> toJson() => {
        'state': 'ready',
        ...analysis.toJson(),
      };
}

/// Nothing needed explaining, or analysis was not requested.
final class AnalysisSkipped extends AnalysisOutcome {
  const AnalysisSkipped(this.reason);

  final String reason;

  @override
  Map<String, Object?> toJson() => {'state': 'skipped', 'reason': reason};
}

/// Analysis was wanted and could not be produced.
///
/// Never fails the run. The verdicts were complete before the model was
/// asked, and a provider outage is not evidence about the application.
final class AnalysisUnavailable extends AnalysisOutcome {
  const AnalysisUnavailable(this.reason);

  final String reason;

  @override
  Map<String, Object?> toJson() => {'state': 'unavailable', 'reason': reason};
}
