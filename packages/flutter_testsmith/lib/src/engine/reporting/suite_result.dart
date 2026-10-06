import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../device/device_profile.dart';
import '../environment/preflight.dart';
import '../validation/validation_dimension.dart';
import '../validation/validation_result.dart';
import 'dimension_verdict.dart';
import 'run_result.dart';

/// What one test in a suite did.
enum TestVerdict {
  pass('pass'),
  fail('fail'),
  error('error'),
  skip('skip');

  const TestVerdict(this.wire);

  final String wire;
}

/// What a whole suite did.
enum SuiteVerdict {
  pass('pass'),
  fail('fail'),
  error('error'),
  skip('skip');

  const SuiteVerdict(this.wire);

  final String wire;

  /// The process exit code for this verdict.
  ///
  /// The CI contract: 0 passed, 1 something is wrong with the
  /// application, 2 something is wrong with the run. Distinguished
  /// because they need different people: a 1 goes to whoever wrote the
  /// screen, a 2 goes to whoever owns the device or the fixture.
  ///
  /// 64 is reserved for usage errors, as `testsmith run` already uses it.
  int get exitCode => switch (this) {
        SuiteVerdict.pass => 0,
        SuiteVerdict.fail => 1,
        SuiteVerdict.error => 2,
        // Nothing required was skipped - that is what makes it a skip
        // rather than an error - so there is nothing to report as bad.
        SuiteVerdict.skip => 0,
      };
}

/// Whether a result says something about the application, or something
/// about the run.
///
/// This is the distinction E-04 exists to make. A report that cannot
/// answer "did the application fail, or could we not test it?" sends the
/// wrong person to look, and a device missing a permission has told
/// nobody anything about a screen.
enum ResultClassification {
  product('product'),
  environment('environment');

  const ResultClassification(this.wire);

  final String wire;
}

/// Which kind of environment problem stopped a test.
///
/// All three are ERROR. They differ only in what a reader should do about
/// them, so they are a label on the result rather than a verdict of their
/// own: E-03's precedence and exit codes already say everything about how
/// "the run did not answer the question" aggregates, and inventing a
/// second vocabulary for it would make every existing consumer wrong.
enum EnvironmentKind {
  /// Preflight refused before anything ran.
  blocked('blocked'),

  /// A condition the suite declared was not met - the application was
  /// somewhere the suite calls "not ready", so the screen was never under
  /// test.
  precondition('precondition'),

  /// Something went wrong during the run: the application would not
  /// start, the flow would not parse, the device went away.
  error('error');

  const EnvironmentKind(this.wire);

  final String wire;
}

/// One thing the suite undid, and whether it managed to.
///
/// Recorded rather than assumed. A teardown that is believed to have
/// happened is a teardown nobody checks, and the state it leaves behind
/// turns up later as a run whose behaviour depends on whether a previous
/// run happened.
@immutable
class CleanupStep {
  const CleanupStep(this.name, {required this.succeeded, this.detail = ''});

  final String name;
  final bool succeeded;

  /// Why it did not happen. Empty when it did.
  final String detail;

  Map<String, Object?> toJson() => {
        'name': name,
        'succeeded': succeeded,
        if (detail.isNotEmpty) 'detail': detail,
      };
}

/// One test's outcome inside a suite.
///
/// There is deliberately **no** constructor that takes a verdict
/// directly. PASS and FAIL are statements about the application; ERROR
/// and SKIP are statements about the run. Splitting the constructors is
/// what makes "an environment problem can never be reported as a product
/// failure" a property of the type rather than a rule somebody has to
/// remember at every call site.
@immutable
class SuiteTestResult {
  const SuiteTestResult._({
    required this.id,
    required this.verdict,
    required this.classification,
    required this.required,
    required this.duration,
    this.environmentKind,
    this.reason,
    this.run,
    this.outputDirectory,
  });

  /// The per-dimension verdicts of this test's run, when it produced
  /// one.
  ///
  /// Carried rather than re-derived, so a suite report cannot disagree
  /// with the run report it links to.
  Map<ValidationDimension, DimensionVerdict>? get dimensions =>
      run?.dimensions;

  /// A statement about the application: it passed, or it failed.
  const SuiteTestResult.product({
    required String id,
    required bool passed,
    required bool required,
    required Duration duration,
    RunResult? run,
    String? outputDirectory,
  }) : this._(
          id: id,
          verdict: passed ? TestVerdict.pass : TestVerdict.fail,
          classification: ResultClassification.product,
          required: required,
          duration: duration,
          run: run,
          outputDirectory: outputDirectory,
        );

  /// A statement about the run: the question was not answered.
  ///
  /// Always ERROR. An environment problem that could report FAIL would be
  /// an environment problem wearing a product defect's clothes.
  ///
  /// [run] is optional because some of these happen before there is a
  /// run at all - a device that refused the build has nothing to report.
  /// But a check that could not be established has a whole run behind
  /// it, and the evidence it *did* gather is worth keeping: an API that
  /// answered correctly before the screenshot could not be taken is
  /// still a fact, and dropping it would make "could not be
  /// established" look like "nothing happened".
  const SuiteTestResult.environment({
    required String id,
    required EnvironmentKind kind,
    required bool required,
    required Duration duration,
    required String reason,
    String? outputDirectory,
    RunResult? run,
  }) : this._(
          id: id,
          verdict: TestVerdict.error,
          classification: ResultClassification.environment,
          environmentKind: kind,
          required: required,
          duration: duration,
          reason: reason,
          outputDirectory: outputDirectory,
          run: run,
        );

  /// A test that did not run at all.
  ///
  /// Classified as environment because nothing about the application was
  /// observed. A required one still counts as an ERROR when the suite
  /// aggregates, exactly as E-03 established.
  const SuiteTestResult.skipped({
    required String id,
    required bool required,
    required String reason,
  }) : this._(
          id: id,
          verdict: TestVerdict.skip,
          classification: ResultClassification.environment,
          required: required,
          duration: Duration.zero,
          reason: reason,
        );

  final String id;
  final TestVerdict verdict;

  /// Whether this says something about the application or about the run.
  final ResultClassification classification;

  /// Which kind of environment problem, when something actually stopped
  /// this test. Null for a product result and for a plain skip.
  final EnvironmentKind? environmentKind;

  /// Whether the suite's verdict depends on this test.
  final bool required;

  final Duration duration;

  /// Why it errored, or why it was skipped. Null when it simply ran.
  final String? reason;

  /// The full result, when the test actually executed.
  ///
  /// Null for a test that never ran - which is the difference between
  /// "this screen is wrong" and "nobody looked".
  final RunResult? run;

  /// Where this test's own report was written, relative to the suite's
  /// output directory.
  final String? outputDirectory;

  Map<String, Object?> toJson() {
    final report = run;
    return {
      'id': id,
      'verdict': verdict.wire,
      'classification': classification.wire,
      if (environmentKind != null) 'environment': environmentKind!.wire,
      'required': required,
      'durationMs': duration.inMilliseconds,
      if (reason != null) 'reason': reason,
      if (outputDirectory != null) 'output': outputDirectory,

      // What each screen came to, from the screen's own canonical
      // status. Nothing is re-derived here.
      //
      // `checks` below lists the results that failed, errored or were
      // skipped - so a screen that *passed* appeared in none of them,
      // and "screen A passed, screen B could not be checked" could only
      // be inferred from absence. Absence is not evidence.
      //
      // Id and status only. The full validation block lives in the run
      // artefact the `output` path names, and copying it here would make
      // the suite file a second copy of something already written.
      if (report != null)
        'screens': [
          for (final screen in report.screens)
            {'screenId': screen.screenId, 'status': screen.status.wire},
        ],

      // The run's own per-dimension verdicts, carried rather than
      // recomputed. This is what lets a reader see that the API answered
      // correctly while the UI could not be read - a fact no list of
      // failures, errors or skips can express, because a dimension that
      // passed produces no entry in any of them.
      if (report != null)
        'dimensions': {
          for (final entry in report.dimensions.entries)
            entry.key.wire: entry.value.toJson(),
        },

      if (report != null)
        'checks': {
          'steps': report.steps.length,
          'screens': report.screens.length,
          'apiChecks': report.apiChecks.length,
          'failures': [
            for (final screen in report.screens)
              for (final result in screen.report.results)
                if (result.status == ValidationStatus.fail)
                  {
                    'screen': screen.screenId,
                    'validator': result.validatorId,
                    if (result.elementId != null) 'element': result.elementId,
                    'message': result.message,
                  },
          ],
          'errors': [
            for (final screen in report.screens)
              for (final result in screen.report.results)
                if (result.status == ValidationStatus.error)
                  {
                    'screen': screen.screenId,
                    'validator': result.validatorId,
                    'message': result.message,
                  },
          ],
          'skips': [
            for (final screen in report.screens)
              for (final result in screen.report.results)
                if (result.status == ValidationStatus.skip)
                  {
                    'screen': screen.screenId,
                    'validator': result.validatorId,
                    'message': result.message,
                  },
          ],
        },
    };
  }
}

/// Every test in a suite, and what the suite therefore says.
///
/// The aggregation is a pure function of the test verdicts. No model
/// participates: an explanation may be attached to an individual run
/// afterwards, and it cannot move this.
@immutable
class SuiteResult {
  const SuiteResult({
    required this.suiteName,
    required this.profile,
    required this.startedAt,
    required this.duration,
    required this.tests,
    this.appVersion,
    this.buildMode,
    this.preflight,
    this.cleanup = const [],
  });

  /// Versioned separately from the run report: a consumer of suite
  /// results should not have to track both.
  ///
  /// 1.1 adds `screens` and `dimensions` to each test. Purely additive -
  /// every key that existed at 1.0 keeps its meaning, so a 1.0 consumer
  /// is unaffected - and versioned for the same reason the run report
  /// was raised twice: a key was added, and the number says so rather
  /// than leaving a consumer to discover it.
  ///
  /// Deliberately not mirrored from the run's version. The two are
  /// separate contracts, which is the whole point of the sentence above:
  /// the run is at 1.2 and that has no bearing on this number.
  static const String schemaVersion = '1.1';

  final String suiteName;

  /// What this suite ran against. A profile, never a serial - the serial
  /// names a handset on one desk and is no part of what was tested.
  final DeviceProfile profile;

  /// The application's own identity, as it reported at handshake.
  final String? appVersion;
  final String? buildMode;

  final DateTime startedAt;
  final Duration duration;

  /// What the environment looked like before any test ran.
  ///
  /// Null for a run that had no preflight - which is every run made
  /// before E-04, and is why the key is absent rather than empty.
  final PreflightReport? preflight;

  /// What the suite undid on the way out.
  final List<CleanupStep> cleanup;

  /// In declared order.
  final List<SuiteTestResult> tests;

  Iterable<SuiteTestResult> get _required => tests.where((t) => t.required);

  /// The suite's verdict.
  ///
  /// Precedence is **ERROR > FAIL > PASS**, and SKIP outranks nothing.
  ///
  /// ERROR above FAIL because the two say different things: a FAIL is a
  /// defect somebody can act on, an ERROR is the absence of an answer. A
  /// suite that could not evaluate a required test does not know whether
  /// it passes, and calling that a failure would claim knowledge it does
  /// not have.
  ///
  /// A *required* test that was skipped counts as an error, not as a
  /// pass. Fail-fast leaves later tests unrun, and a test that did not
  /// run has not been shown to be correct - so a skip can never make a
  /// suite greener than it would otherwise have been.
  SuiteVerdict get verdict {
    final required = _required.toList();

    // Nothing was required, and everything optional was skipped.
    if (required.isEmpty) {
      return tests.every((t) => t.verdict == TestVerdict.skip)
          ? SuiteVerdict.skip
          : SuiteVerdict.pass;
    }

    if (required.any((t) => t.verdict == TestVerdict.error)) {
      return SuiteVerdict.error;
    }
    if (required.any((t) => t.verdict == TestVerdict.fail)) {
      return SuiteVerdict.fail;
    }
    // A required test nobody ran. Not a pass.
    if (required.any((t) => t.verdict == TestVerdict.skip)) {
      return SuiteVerdict.error;
    }
    return SuiteVerdict.pass;
  }

  int get exitCode => verdict.exitCode;

  int countOf(TestVerdict verdict) =>
      tests.where((t) => t.verdict == verdict).length;

  Map<String, Object?> toJson() => {
        'suiteSchemaVersion': schemaVersion,
        'suite': suiteName,
        'deviceProfile': profile.toJson(),
        if (appVersion != null) 'appVersion': appVersion,
        if (buildMode != null) 'buildMode': buildMode,
        if (preflight != null) 'preflight': preflight!.toJson(),
        'startedAt': formatUtcTimestamp(startedAt),
        'durationMs': duration.inMilliseconds,
        'verdict': verdict.wire,
        'exitCode': exitCode,
        'counts': {
          for (final v in TestVerdict.values) v.wire: countOf(v),
        },
        'tests': [for (final test in tests) test.toJson()],
        if (cleanup.isNotEmpty)
          'cleanup': [for (final step in cleanup) step.toJson()],
      };
}
