import 'package:meta/meta.dart';

import '../ai/ai_analysis.dart';
import '../dsl/steps.dart';
import '../validation/api_expectation.dart';
import '../validation/validation_dimension.dart';
import '../validation/validation_result.dart';
import 'dimension_verdict.dart';
import 'network_record.dart';

/// How a single step turned out.
enum StepStatus {
  ok('ok'),

  /// The step ran and what it asserted did not hold.
  ///
  /// A statement about the application, which is why it becomes a UI
  /// FAIL below.
  failed('failed'),

  /// The step could not be carried out, because the engine lost its
  /// ability to observe the application.
  ///
  /// Not [failed]. A lost VM Service connection, an unanswered RPC or an
  /// event stream this build cannot read say nothing whatever about the
  /// screen - and reported as a failure they said the screen was wrong.
  /// See `isInfrastructureFailure`, which is what decides this.
  observationFailed('observationFailed'),

  skipped('skipped');

  const StepStatus(this.wire);

  final String wire;
}

@immutable
class StepOutcome {
  const StepOutcome({
    required this.description,
    required this.kind,
    required this.status,
    required this.durationMs,
    this.detail,
    this.startedOffsetMs,
  });

  final String description;

  /// What the step was, from the concrete [Step] that produced it.
  ///
  /// Required, with no default. A default would be a way for a step to
  /// reach a 1.3 report as an unknown, and the point of the field is
  /// that it cannot: `stepKindOf` is exhaustive over the sealed
  /// hierarchy, so the compiler asks the question at the one place that
  /// knows the answer.
  final StepKind kind;

  final StepStatus status;
  final int durationMs;
  final String? detail;

  /// When the step began, in milliseconds after [RunResult.startedAt].
  ///
  /// Read off the run's own stopwatch, which is monotonic, so a clock
  /// that steps mid-run can neither reorder the steps nor stretch one.
  /// The wall-clock moment is `startedAt` plus this.
  ///
  /// Null for a step recorded without one, which a report treats as "not
  /// recorded" rather than as the start of the run.
  final int? startedOffsetMs;

  Map<String, Object?> toJson() => {
        'description': description,
        'kind': kind.wire,
        'status': status.wire,
        if (startedOffsetMs != null) 'startedOffsetMs': startedOffsetMs,
        'durationMs': durationMs,
        if (detail != null) 'detail': detail,
      };
}

/// Whether a serialised step is an `expectApi` assertion rather than a
/// UI action.
///
/// It exists because an `expectApi` produces two results by design - a
/// UI-dimension step outcome and an API-dimension check - and a report
/// that lists both in one place makes the run look like twice as much
/// happened. One rule, read by every report, so the terminal summary and
/// the HTML page cannot come to different answers about the same run.
///
/// [kind] is `steps[].kind` as written at run schema 1.3, or null for an
/// artefact written before it.
///
/// **A kind that is present is authoritative.** The description is not
/// consulted, not even to disagree: the field exists precisely because
/// [isApiAssertionDescription] gets two cases wrong, and letting text
/// override the declared kind would hand those cases straight back.
bool isApiAssertionStep({String? kind, required String description}) =>
    kind == null
        ? isApiAssertionDescription(description)
        : kind == StepKind.expectApi.wire;

/// The pre-1.3 classifier, for artefacts that carry no kind.
///
/// Matches [Step.describe] text because that is all such a file has.
/// `ExpectApiStep.describe()` is the sole producer of this wording.
///
/// Known to be wrong in two cases, both of them an `expect …` step whose
/// user-supplied text contains the phrase: an `expectElement` whose
/// expected text does, and an `expectScreen` whose screen id does. Both
/// are then hidden from the UI section of a report that has no API entry
/// for them either.
///
/// Left wrong on purpose. Repairing an old artefact would mean guessing
/// at what it meant, and a report that guesses is how it starts
/// disagreeing with the run it describes. Files written from 1.3 carry a
/// kind and never reach this.
bool isApiAssertionDescription(String description) =>
    description.startsWith('expect ') &&
    description.contains('to have answered');

/// One API exchange, flattened for the report.
@immutable
class ExchangeSummary {
  const ExchangeSummary({
    required this.method,
    required this.path,
    required this.durationMs,
    this.statusCode,
    this.error,
    this.requestId,
  });

  final String method;
  final String path;
  final int? statusCode;
  final String? error;

  /// As the application measured it, or null when no response was
  /// observed.
  ///
  /// Until schema 1.5 an unanswered request was written as `0`, which is
  /// a measurement nobody made: it read as the fastest call in the run.
  /// The key is now omitted instead.
  final int? durationMs;

  /// Pairs this row with the same request in `network.exchanges`.
  final String? requestId;

  Map<String, Object?> toJson() => {
        if (requestId != null) 'requestId': requestId,
        'method': method,
        'path': path,
        if (statusCode != null) 'statusCode': statusCode,
        if (error != null) 'error': error,
        if (durationMs != null) 'durationMs': durationMs,
      };
}

/// What was moving on a screen when it was validated.
///
/// Kept on the result rather than only logged, so the report can say
/// what a PASS covered. An exclusion nobody mentions is a hole in the
/// check.
@immutable
class QuiescenceSummary {
  const QuiescenceSummary({
    required this.ticking,
    required this.permitted,
    required this.unexpected,
    this.lines = const [],
  });

  final int ticking;
  final int permitted;
  final int unexpected;

  /// The report block, already worded by the evaluator.
  final List<String> lines;

  Map<String, Object?> toJson() => {
        'ticking': ticking,
        'permitted': permitted,
        'unexpected': unexpected,
        if (lines.isNotEmpty) 'detail': lines,
      };
}

/// Everything known about one screen after a run.
@immutable
class ScreenResult {
  const ScreenResult({
    required this.screenId,
    required this.report,
    this.exchanges = const [],
    this.screenshotPath,
    this.uiNodeCount,
    this.quiescence,
  });

  final String screenId;
  final ValidationReport report;
  final List<ExchangeSummary> exchanges;
  final String? screenshotPath;
  final int? uiNodeCount;

  /// What was ticking when this screen was validated, if anything was.
  final QuiescenceSummary? quiescence;

  /// This screen's own verdict.
  ///
  /// Canonical and derived, never stored: the results are already here
  /// and each already carries a status, so computing it twice is the
  /// only way the two could ever disagree.
  ///
  /// It lived in the CLI renderer until now, which meant `result.json`
  /// carried `passed` and four counts and left every machine consumer
  /// to re-derive PASS / FAIL / ERROR / SKIP with the precedence rule
  /// copied out by hand - the duplicate aggregation just removed from
  /// the run level, one level down and outside this repository.
  ///
  /// Screen-local on purpose. A run of three screens where one could not
  /// be photographed has one ERROR and two PASSes, and flattening that
  /// into [RunResult.overall] would lose which screen to go and look at.
  ///
  /// The same `aggregateStatus` every other level uses, so
  /// ERROR > FAIL > PASS > SKIP holds here too and a screen that checked
  /// nothing reports SKIP rather than a vacuous pass.
  ValidationStatus get status =>
      aggregateStatus(report.results.map((r) => r.status));

  Map<String, Object?> toJson() => {
        'screenId': screenId,
        'status': status.wire,
        'validation': report.toJson(),
        'exchanges': [for (final e in exchanges) e.toJson()],
        if (screenshotPath != null) 'screenshot': screenshotPath,
        if (uiNodeCount != null) 'uiNodeCount': uiNodeCount,
        if (quiescence != null) 'quiescence': quiescence!.toJson(),
      };
}

/// The machine-readable outcome of a run.
///
/// Written **before** the HTML, which is rendered from this and nothing
/// else. CI consumes this file, so the human report cannot disagree with
/// what CI saw.
@immutable
class RunResult {
  const RunResult({
    required this.flowName,
    required this.appId,
    required this.device,
    required this.startedAt,
    required this.duration,
    required this.steps,
    required this.screens,
    this.apiChecks = const [],
    this.analysis,
    this.fixture,
    this.appVersion,
    this.buildMode,
    this.sessionId,
    this.network,
  });

  /// The SDK session this run observed, as the handshake named it.
  ///
  /// Every event the application emitted carries the same id, so this is
  /// what ties the artefact to a log of the raw stream. Generated by the
  /// application, not by the run; null when no session was established.
  final String? sessionId;

  /// Every request the run captured, and how much it could have
  /// captured.
  ///
  /// Null when the run recorded no such thing - a result built outside
  /// `FlowExecutor`, or written before 1.5. That is a different fact from
  /// a record whose capture was [NetworkCaptureState.unavailable], and the
  /// report says which it is looking at.
  ///
  /// Like [analysis], read by no verdict.
  final NetworkRecord? network;

  /// The API scenario this run was measured against, when one was named.
  ///
  /// The name of a scenario file, as `TestFlow.parse` requires it and as
  /// `ScenarioLibrary.resolve` looks it up - the effective one, so a run
  /// started with `--fixture` records what it actually ran against
  /// rather than what the flow declared.
  ///
  /// Recorded because every UI and API assertion in the run was measured
  /// against it. Two runs of the same flow against different scenarios
  /// are different measurements, and without this the artefacts are
  /// indistinguishable.
  ///
  /// Null when no scenario was named. Deliberately not filled in with
  /// the library's default: absence here means "this run named none",
  /// which is a different fact from naming one.
  final String? fixture;

  /// The application build under test, as the SDK handshake reported it.
  ///
  /// Read from the running application rather than typed into a file,
  /// for the reason `describe` already gives: a provenance note somebody
  /// maintains separately is one that goes stale. Null when the device
  /// could not be read, which is never fatal - the record simply says
  /// less rather than saying something untrue.
  final String? appVersion;

  final String? buildMode;

  /// Versioned separately from the protocol: a consumer of reports
  /// should not have to track the wire format as well.
  ///
  /// 1.1 adds `dimensions` and `overall`. Purely additive - every key
  /// that existed at 1.0 keeps its meaning, so a 1.0 consumer is
  /// unaffected.
  ///
  /// 1.2 adds `status` to each screen, on the same terms and for the
  /// same reason 1.1 was raised: a key was added, nothing existing
  /// changed meaning, and the version says so rather than leaving a
  /// consumer to discover it. A 1.1 consumer reads every field it knows
  /// and keeps deriving the screen status from `validation.counts` if it
  /// wants to; a 1.2 consumer reads it instead of reimplementing it.
  ///
  /// 1.3 adds `kind` to each step, on the same terms again. It says what
  /// a step *was* - `tap`, `expectElement`, `expectApi` - rather than
  /// leaving a reader to infer it from the description, which is
  /// presentation text carrying user-supplied values. A 1.2 consumer
  /// ignores the key and keeps reading descriptions; a 1.3 consumer
  /// stops guessing. `StepKind` holds the vocabulary.
  ///
  /// 1.4 adds the run's preconditions - `fixture`, `appVersion` and
  /// `buildMode` - on the same additive terms. They say what the run was
  /// measured against and which build it measured, so two artefacts of
  /// the same flow can be told apart when the scenario or the build
  /// differed. Each is omitted when it was not known, because "no
  /// scenario was named" and "a scenario was named" are different facts
  /// and a placeholder would erase the difference.
  ///
  /// 1.5 adds the run's network record - `network`, with every captured
  /// request, its timestamps and an explicit statement of how much the
  /// capture could see - together with `sessionId` and each step's
  /// `startedOffsetMs`, all additive. One existing key is corrected
  /// rather than added to: `screens[].exchanges[].durationMs` is now
  /// omitted for a request that was never answered, where it used to say
  /// 0. A 0 is a measurement, and none was made; a consumer that read it
  /// as one was being told the hung request was the fastest in the run.
  ///
  /// 1.6 adds `network.durationClock`: `monotonic` when the application's
  /// SDK advertised `monotonicNetworkTiming`, `wall` when it advertised
  /// network capture without it, and absent when capture was unavailable.
  /// Additive, and nothing earlier is relabelled: a 1.5 file has no key,
  /// which means "not recorded". `durationMs` keeps its key and type; from
  /// an SDK that advertises the capability it is measured on a monotonic
  /// clock from before the connection was opened, so it includes
  /// connection setup that a 1.5-era SDK's figure left out.
  static const String schemaVersion = '1.6';

  final String flowName;
  final String appId;
  final String device;
  final DateTime startedAt;
  final Duration duration;
  final List<StepOutcome> steps;
  final List<ScreenResult> screens;

  /// What each `expectApi` step found, in the order they ran.
  ///
  /// Separate from [screens] because an API assertion is a statement
  /// about a moment in the flow rather than about a screen - which is
  /// the whole point of it being a step.
  final List<ApiExpectationOutcome> apiChecks;

  /// What a model said about the failures, when one was asked.
  ///
  /// Note what [passed] does *not* read. The verdict is a function of
  /// the steps and the deterministic reports alone; this field could
  /// say anything at all and the outcome would not move. That is the
  /// separation the whole platform rests on, expressed as code rather
  /// than as a promise.
  final AnalysisOutcome? analysis;

  bool get passed =>
      steps.every((s) => s.status != StepStatus.failed) &&
      !observationFailed &&
      screens.every((s) => s.report.passed) &&
      apiChecks.every((c) => c.satisfied);

  /// Whether the engine stopped being able to observe the application
  /// part-way through.
  ///
  /// A statement about the run rather than about the application, and
  /// the one a caller needs to decide which of them to blame: the suite
  /// reports it as an environment error rather than a product failure,
  /// and the CLI exits 2 rather than 1.
  ///
  /// Derived, never stored, so it cannot disagree with the steps.
  bool get observationFailed =>
      steps.any((s) => s.status == StepStatus.observationFailed);


  /// Every validation result in the run, with the step outcomes and the
  /// API checks folded in as results of their own.
  ///
  /// Steps are UI: they are the execution of the user-written test.
  /// `expectApi` outcomes are API: they are assertions about the API.
  List<ValidationResult> get _allResults => [
        for (final step in steps)
          switch (step.status) {
            StepStatus.ok => ValidationResult.pass(
                validatorId: 'step',
                message: step.description,
                dimension: ValidationDimension.ui,
              ),
            StepStatus.failed => ValidationResult.fail(
                validatorId: 'step',
                message: step.detail ?? step.description,
                dimension: ValidationDimension.ui,
              ),
            // ERROR, and the choice between ERROR and SKIP is the whole
            // of this. SKIP would aggregate away behind the steps that
            // ran before it: a flow cut short at step four still has
            // three passes in front of it, and `aggregateStatus` would
            // report PASS - claiming a journey works when nobody
            // finished walking it.
            //
            // ERROR is what this codebase already means by "could not
            // answer the question"; `aggregateStatus` says exactly that,
            // and the visual validator already returns ERROR for a
            // screen it could not photograph - "an error rather than a
            // fail - the application is not necessarily wrong - and
            // never a pass".
            //
            // A dimension nothing touched still has no results at all,
            // so it is still SKIP. The invariant is unmoved.
            StepStatus.observationFailed => ValidationResult.error(
                validatorId: 'step',
                message: step.detail ?? step.description,
                dimension: ValidationDimension.ui,
              ),
            StepStatus.skipped => ValidationResult.skip(
                validatorId: 'step',
                message: step.description,
                dimension: ValidationDimension.ui,
              ),
          },
        for (final check in apiChecks)
          if (check.satisfied)
            ValidationResult.pass(
              validatorId: 'expect-api',
              message: check.describe(),
              dimension: ValidationDimension.api,
            )
          else
            ValidationResult.fail(
              validatorId: 'expect-api',
              message: check.describe(),
              dimension: ValidationDimension.api,
            ),
        for (final screen in screens) ...screen.report.results,
      ];

  /// One verdict per dimension. Every dimension is always present.
  ///
  /// Computed, never stored. That is the property this rests on: the
  /// block cannot disagree with [passed], because it is derived from the
  /// same fields.
  Map<ValidationDimension, DimensionVerdict> get dimensions {
    final all = _allResults;
    return {
      for (final dimension in ValidationDimension.values)
        dimension: verdictFor(
          dimension,
          [for (final r in all) if (r.dimension == dimension) r],
        ),
    };
  }

  /// The deterministic verdict over every dimension.
  ///
  /// [passed] is true exactly when this does not block a pass - asserted
  /// as a property test over every combination, so E-03's and E-04's
  /// verdicts and exit codes are provably unmoved by the dimension
  /// block. Stated that way rather than as `overall == pass` because a
  /// run in which nothing was checked passes vacuously and rolls up to
  /// SKIP.
  ValidationStatus get overall =>
      aggregateStatus(dimensions.values.map((v) => v.status));

  /// The same result with an analysis attached.
  ///
  /// Deliberately a copy: the run is complete and immutable before a
  /// model is asked, so attaching an explanation cannot disturb it.
  RunResult withAnalysis(AnalysisOutcome outcome) => RunResult(
        flowName: flowName,
        appId: appId,
        device: device,
        startedAt: startedAt,
        duration: duration,
        steps: steps,
        screens: screens,
        apiChecks: apiChecks,
        analysis: outcome,
        // Carried, like everything else. A copy that dropped the run's
        // preconditions would mean asking a model for an explanation
        // silently cost the artefact what it was measured against.
        fixture: fixture,
        appVersion: appVersion,
        buildMode: buildMode,
        sessionId: sessionId,
        network: network,
      );

  Map<String, Object?> toJson() => {
        'resultSchemaVersion': schemaVersion,
        'flow': flowName,
        'appId': appId,
        'device': device,
        // The run's preconditions: what it was measured against, and
        // which build it measured. Omitted rather than nulled when
        // unknown, as every other optional key here is.
        if (fixture != null) 'fixture': fixture,
        if (appVersion != null) 'appVersion': appVersion,
        if (buildMode != null) 'buildMode': buildMode,
        if (sessionId != null) 'sessionId': sessionId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'passed': passed,
        'overall': overall.wire,
        'dimensions': {
          for (final entry in dimensions.entries)
            entry.key.wire: entry.value.toJson(),
        },
        'steps': [for (final s in steps) s.toJson()],
        'screens': [for (final s in screens) s.toJson()],
        if (apiChecks.isNotEmpty)
          'apiChecks': [for (final c in apiChecks) c.toJson()],
        if (network != null) 'network': network!.toJson(),
        if (analysis != null) 'aiAnalysis': analysis!.toJson(),
      };
}
