import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

import 'flow_runner.dart';
import 'mock_api_server.dart';
import 'project_config.dart';

/// Grants the permissions a suite declares, once, before anything checks
/// them.
///
/// Setup, then verification - not the other way round. A suite declares
/// `device.permissions` precisely so the runner will grant them, so a
/// preflight that read the device first would block every fresh run on a
/// state the very next step was about to establish.
///
/// Declared rather than inferred, and granted rather than dismissed: a
/// runtime permission dialog drawn over the application swallows the tap
/// meant for the button beneath it, and the run then reports a tap that
/// happened and a navigation that did not. Granting here is also what
/// stops the next run inheriting a half-permissioned device, because a
/// test declaring `clearState` revokes these along with everything else -
/// the recurrence E-03 documented and could only ask a person to
/// remember.
///
/// Failures are reported, not raised. A grant that did not work is a
/// finding for preflight to make against the device itself, with the real
/// reason, rather than an exception from here with a guess at one.
/// Grants [permissions] to [appId], reporting each and raising nothing.
///
/// Extracted from [grantDeclaredPermissions] so auth setup arranges its
/// device exactly as a suite does, rather than growing a second way of
/// doing the same thing. A failure is logged rather than thrown: the
/// permission check that follows is what decides whether the run can
/// proceed, and it gives a better message than this could.
Future<void> grantPermissions({
  required String appId,
  required List<String> permissions,
  required DeviceController device,
  required void Function(String) log,
}) async {
  for (final permission in permissions) {
    try {
      await device.grantPermission(appId, permission);
      log('  granted $permission');
    } catch (error) {
      log('  ! could not grant $permission: $error');
    }
  }
}

Future<void> grantDeclaredPermissions({
  required SuiteFile suite,
  required Directory projectDirectory,
  required DeviceController device,
  required void Function(String) log,
}) async {
  if (suite.devicePermissions.isEmpty) return;

  final appId = declaredAppId(suite, projectDirectory);
  if (appId == null) return;

  await grantPermissions(
    appId: appId,
    permissions: suite.devicePermissions,
    device: device,
    log: log,
  );
}

/// The application a suite drives, read from its first readable flow.
///
/// Null when no flow can be read, and then nothing is arranged: a flow
/// that will not parse is already an ERROR when the suite reaches it,
/// with a better message than this could give.
String? declaredAppId(SuiteFile suite, Directory projectDirectory) {
  for (final test in suite.tests) {
    final file = File('${projectDirectory.path}/${test.flow}');
    if (!file.existsSync()) continue;
    try {
      return TestFlow.parse(file.readAsStringSync(), source: file.path).appId;
    } on Object {
      continue;
    }
  }
  return null;
}

/// The result of a suite whose environment could not support one.
///
/// Every test is an environment finding and none is a verdict on the
/// application: a screen nobody looked at has not been shown to be wrong,
/// and saying it failed would be a claim about code the run never
/// reached.
///
/// One definition, called both from [SuiteRunner] and from the command
/// that blocks before the fixture server is even started. Two copies of
/// this rule would be two chances for one of them to start reporting a
/// blocked environment as a failure.
SuiteResult blockedSuiteResult({
  required SuiteFile suite,
  required DeviceProfile profile,
  required PreflightReport preflight,
  required DateTime startedAt,
  Duration duration = Duration.zero,
  List<CleanupStep> cleanup = const [],
}) {
  final reason = 'preflight blocked: '
      '${preflight.blockers.map((check) => check.name).join(', ')}';

  return SuiteResult(
    suiteName: suite.name,
    profile: profile,
    startedAt: startedAt,
    duration: duration,
    preflight: preflight,
    cleanup: cleanup,
    tests: [
      for (final test in suite.tests)
        SuiteTestResult.environment(
          id: test.id,
          kind: EnvironmentKind.blocked,
          required: test.required,
          duration: Duration.zero,
          reason: reason,
        ),
    ],
  );
}

/// Runs a suite of flows against one device.
///
/// Orchestration only. Every flow is executed by [FlowRunner], which is
/// the same unit `testsmith run` uses, so a flow cannot behave one way
/// alone and another way in a suite.
///
/// The lifecycle between tests is explicit and minimal:
///
/// * the application is relaunched for every test, because that is what
///   a single run does and a suite whose tests saw a different starting
///   state would be measuring something else,
/// * stored state is cleared only where the suite says so,
/// * the fixture server keeps running and swaps scenarios, because
///   restarting it would tear down the `adb reverse` the device talks
///   through.
class SuiteRunner {
  SuiteRunner({
    required this.suite,
    required this.projectDirectory,
    required this.profile,
    required this.device,
    required this.execution,
    required this.outputDirectory,
    required this.log,
    this.mockApi,
    this.scenarios,
    this.preflight,
    this.teardown = const {},
  });

  final SuiteFile suite;
  /// The application root. Flows are resolved against it.
  final Directory projectDirectory;
  final DeviceProfile profile;

  /// Used only for the declared lifecycle: clearing state, granting a
  /// permission. Nothing here touches the device otherwise.
  final DeviceController device;

  /// How a flow is executed. [FlowRunner] in a real run; a fake in the
  /// tests that cover ordering, fail-fast and aggregation.
  final FlowExecution execution;

  final Directory outputDirectory;
  final void Function(String) log;
  final MockApiServer? mockApi;
  final ScenarioLibrary? scenarios;

  /// What the environment looked like before any test ran.
  ///
  /// When it blocks, nothing is launched and no test is given a verdict
  /// about the application: a screen nobody looked at has not been shown
  /// to be correct, and calling that a failure would be a claim about
  /// code this run never reached.
  final PreflightReport? preflight;

  /// What to undo on the way out, in order, whatever happened.
  ///
  /// Named so the report can say what was undone and whether it worked. A
  /// teardown that is believed to have happened is a teardown nobody
  /// checks.
  final Map<String, Future<void> Function()> teardown;

  Future<SuiteResult> run() async {
    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();

    final blocked = preflight;
    if (blocked != null && blocked.isBlocked) {
      log('');
      log('  nothing was launched, and no test was judged');

      return blockedSuiteResult(
        suite: suite,
        profile: profile,
        preflight: blocked,
        startedAt: startedAt,
        duration: stopwatch.elapsed,
        cleanup: await _tearDown(),
      );
    }

    final results = <SuiteTestResult>[];
    var stopped = false;
    String? appVersion;
    String? buildMode;
    var profileChecked = false;

    for (final test in suite.tests) {
      if (stopped) {
        results.add(
          SuiteTestResult.skipped(
            id: test.id,
            required: test.required,
            reason: 'not run: the suite stopped at the first failure',
          ),
        );
        continue;
      }

      log('');
      log('── ${test.id} ${'─' * (46 - test.id.length).clamp(0, 46)}');

      final perTest = Stopwatch()..start();
      final testOutput = Directory('${outputDirectory.path}/${test.id}');

      SuiteTestResult outcome;
      try {
        outcome = await _runOne(
          test,
          testOutput,
          onDescribed: (environment, facts) {
            appVersion ??= environment.appVersion;
            buildMode ??= environment.buildMode;
            if (profileChecked) return;
            profileChecked = true;
            // Checked once, on the first launch, because the pixel
            // ratio and the build mode come from the handshake rather
            // than from adb. A device that is not the one the profile
            // names makes every baseline comparison meaningless, so the
            // suite stops rather than producing confident nonsense.
            final mismatches = profile.mismatchesAgainst(facts);
            if (mismatches.isNotEmpty) {
              throw _ProfileMismatch(mismatches);
            }
          },
          elapsed: perTest,
        );
      } on _ProfileMismatch catch (error) {
        outcome = SuiteTestResult.environment(
          id: test.id,
          kind: EnvironmentKind.error,
          required: test.required,
          duration: perTest.elapsed,
          reason: 'the device is not the one "${profile.id}" describes: '
              '${error.mismatches.join('; ')}',
        );
      } catch (error) {
        // The application would not start, the flow could not be parsed,
        // the device went away. None of these is the screen being wrong,
        // so none of them is a FAIL.
        outcome = SuiteTestResult.environment(
          id: test.id,
          kind: EnvironmentKind.error,
          required: test.required,
          duration: perTest.elapsed,
          reason: '$error',
        );
      }

      results.add(outcome);
      _logOutcome(outcome);

      if (suite.onFailure == OnFailure.stop &&
          (outcome.verdict == TestVerdict.fail ||
              outcome.verdict == TestVerdict.error)) {
        stopped = true;
      }
    }

    final cleanup = await _tearDown();

    return SuiteResult(
      suiteName: suite.name,
      profile: profile,
      appVersion: appVersion,
      buildMode: buildMode,
      startedAt: startedAt,
      duration: stopwatch.elapsed,
      preflight: preflight,
      cleanup: cleanup,
      tests: results,
    );
  }

  /// Undoes what the suite set up, and records each attempt.
  ///
  /// Never throws. Teardown must not throw over whatever caused it: when
  /// a run fails because the device vanished, every cleanup step fails
  /// too, and an exception from one of those would replace the real cause
  /// with a confusing one.
  Future<List<CleanupStep>> _tearDown() async {
    final steps = <CleanupStep>[];
    for (final entry in teardown.entries) {
      try {
        await entry.value();
        steps.add(CleanupStep(entry.key, succeeded: true));
      } catch (error) {
        log('  ! could not tear down ${entry.key}: $error');
        steps.add(
          CleanupStep(entry.key, succeeded: false, detail: '$error'),
        );
      }
    }
    return steps;
  }

  Future<SuiteTestResult> _runOne(
    SuiteTest test,
    Directory testOutput, {
    required void Function(BaselineEnvironment, DeviceFacts) onDescribed,
    required Stopwatch elapsed,
  }) async {
    final flowFile = File('${projectDirectory.path}/${test.flow}');
    final flow = TestFlow.parse(
      await flowFile.readAsString(),
      source: flowFile.path,
    );

    await _prepare(test, flow.appId);

    final fixture = flow.fixture;
    if (fixture != null) {
      final library = scenarios;
      final mock = mockApi;
      if (library == null || mock == null) {
        throw StateError(
          '"${test.id}" needs the "$fixture" API state, and this suite '
          'declares no mockApi port. A flow that names an API state is '
          'only a test when that state is arranged.',
        );
      }
      mock.serve(library.resolve(fixture));
      log('  › API state "$fixture"');
    }

    var screenHistory = const <String>[];
    final result = await execution.execute(
      flow: flow,
      outputDirectory: testOutput,
      fixture: fixture,
      onDescribed: onDescribed,
      onScreensObserved: (screens) => screenHistory = screens,
    );

    // Written here rather than by the caller, so a test that ran always
    // has the report its result points at. A test that never ran has no
    // result to write, and gets no directory - an empty report would
    // read as "we looked and found nothing wrong".
    await writeRunReports(result, testOutput);

    // A run the engine could not observe is a statement about the run,
    // and `SuiteTestResult` already refuses to let such a thing report
    // FAIL - there is deliberately no constructor for it. What was
    // missing was the runner saying so, which left every lost connection
    // arriving here as `product(passed: false)`: a product defect's
    // clothes on an environment problem.
    //
    // Checked before the precondition rule, because that rule reads the
    // route history to decide the application was "not ready" - and the
    // history after the engine stopped observing is simply the last one
    // that reached it.
    if (result.observationFailed) {
      return SuiteTestResult.environment(
        id: test.id,
        kind: EnvironmentKind.error,
        required: test.required,
        duration: elapsed.elapsed,
        reason: result.steps
                .firstWhere(
                  (s) => s.status == StepStatus.observationFailed,
                )
                .detail ??
            'the engine could not observe the application',
        outputDirectory: test.id,
        // Carried, for the same reason the `overall == error` branch
        // below carries it: a run that lost the connection part-way had
        // still established something before it did, and a suite row
        // with no evidence at all reads as though nothing had happened.
        // This branch is the *commonest* environment failure, so it is
        // the one that could least afford to drop it.
        run: result,
      );
    }

    if (!result.passed) {
      final unmet = _unmetPrecondition(test, screenHistory);
      if (unmet != null) {
        return SuiteTestResult.environment(
          id: test.id,
          kind: EnvironmentKind.precondition,
          required: test.required,
          duration: elapsed.elapsed,
          reason: unmet,
          outputDirectory: test.id,
          // Carried here too. The run happened; it was reclassified
          // because the screen it ended on says the precondition was
          // never met, and what it managed to check on the way is still
          // evidence.
          run: result,
        );
      }
    }

    // A check that could not be established is not evidence about the
    // application. `passed` is false for a screen that was contradicted
    // and equally false for one the tool could not photograph, and
    // handing that single boolean to `.product` reported the second as
    // the first - exiting 1, and sending someone to read a screen nobody
    // had measured.
    //
    // `overall` is the run's own verdict, so the suite row and the run
    // report cannot disagree. It aggregates through the dimension block,
    // which is complete now that a report refuses a result carrying no
    // dimension.
    //
    // Last of the three, deliberately: a lost connection and an unmet
    // precondition are more specific facts, and both are decided above.
    if (result.overall == ValidationStatus.error) {
      return SuiteTestResult.environment(
        id: test.id,
        kind: EnvironmentKind.error,
        required: test.required,
        duration: elapsed.elapsed,
        reason: _unestablished(result) ??
            'a check could not be established on this run',
        outputDirectory: test.id,
        // Carried, so the suite row still links to what the run *did*
        // establish. An API that answered before the screenshot could
        // not be taken is evidence, and losing it would make this read
        // as though nothing had happened.
        run: result,
      );
    }

    return SuiteTestResult.product(
      id: test.id,
      passed: result.passed,
      required: test.required,
      duration: elapsed.elapsed,
      run: result,
      outputDirectory: test.id,
    );
  }

  /// The first check that could not be established, named with its
  /// screen, or null when every check ran.
  ///
  /// The first rather than all of them: the rest are usually the same
  /// cause seen again, and a suite row has one line.
  String? _unestablished(RunResult result) {
    for (final screen in result.screens) {
      for (final row in screen.report.results) {
        if (row.status == ValidationStatus.error) {
          return '${screen.screenId}: ${row.message}';
        }
      }
    }
    return null;
  }

  /// Why this test could not be judged, or null if it could.
  ///
  /// Consulted only for a test that did **not** pass. That is what makes
  /// the reclassification safe: it can only ever move a result *up* the
  /// precedence ladder, from FAIL to ERROR, so declaring a precondition
  /// can never make a suite greener than it would otherwise have been.
  ///
  /// The last route the application reached is the one that decides. A
  /// flow that ended on a screen the suite calls "not ready" was never in
  /// a position to say anything about the screen it was asked about.
  String? _unmetPrecondition(SuiteTest test, List<String> screenHistory) {
    // Nothing observed, so nothing concluded: the failure keeps whatever
    // it already said.
    if (test.requires.isEmpty || screenHistory.isEmpty) return null;
    final last = screenHistory.last;

    for (final name in test.requires) {
      final precondition = suite.preconditions[name];
      if (precondition == null) continue;
      if (!precondition.unmetOn.contains(last)) continue;

      final because = precondition.description.isEmpty
          ? ''
          : ', and this test needs ${precondition.description}';
      return 'the precondition "$name" is not met: the application ended on '
              '"$last"$because. ${precondition.remedy}'
          .trim();
    }
    return null;
  }

  /// Arranges whatever the suite declared for this test, and nothing
  /// else.
  Future<void> _prepare(SuiteTest test, String appId) async {
    if (test.reset == StateReset.clearState) {
      log('  › clearing application state');
      await device.clearAppState(appId);
    }
    for (final permission in test.grant) {
      await device.grantPermission(appId, permission);
      log('  › granted $permission');
    }
  }

  void _logOutcome(SuiteTestResult outcome) {
    final label = switch (outcome.verdict) {
      TestVerdict.pass => 'PASS',
      TestVerdict.fail => 'FAIL',
      TestVerdict.error => 'ERROR',
      TestVerdict.skip => 'SKIP',
    };
    log('  $label ${outcome.id}'
        '${outcome.reason == null ? '' : ' - ${outcome.reason}'}');
  }
}

/// The connected device is not the one the profile describes.
class _ProfileMismatch implements Exception {
  _ProfileMismatch(this.mismatches);

  final List<String> mismatches;

  @override
  String toString() => mismatches.join('; ');
}
