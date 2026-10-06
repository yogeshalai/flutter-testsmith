import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_testsmith/figma.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/protocol.dart';

import 'app_session.dart';
import 'http_api_fetcher.dart';
import 'secrets/env_secret_resolver.dart';

/// Runs a parsed flow against a launched application.
///
/// Each step is executed and recorded. A failed step stops the run:
/// continuing past a tap that did not land produces a cascade of
/// failures that hide the one that mattered.
class FlowExecutor {
  FlowExecutor({
    required this.flow,
    required this.session,
    required this.mappings,
    required this.outputDirectory,
    required this.log,
    this.figmaSpecs = const {},
    this.figmaFailures = const {},
    this.baselines,
    this.updateBaselines = false,
    this.apiFetcher = const HttpApiFetcher(),
    this.fixture,
    this.appVersion,
    this.buildMode,
    SecretResolver? secrets,
  }) : secrets = secrets ?? const _DefaultSecrets();

  final TestFlow flow;
  final AppSession session;

  /// The API scenario actually in force, and the build under test.
  ///
  /// Passed in rather than read back off [baselines], which is nullable
  /// and whose `variant` is a baseline-selection concern that happens to
  /// share this value. These are the run's preconditions, and they are
  /// recorded because every assertion below was measured against them.
  ///
  /// All three are legitimately absent - no scenario named, or a device
  /// that would not say what it was running - and absence is recorded as
  /// absence.
  final String? fixture;
  final String? appVersion;
  final String? buildMode;

  /// Per-screen mappings, keyed by screen id. Absent means the screen's
  /// validators skip rather than fail.
  final Map<String, MappingsFile> mappings;

  /// Normalised designs, keyed by screen id. A screen with no design
  /// skips Figma validation rather than failing it.
  final Map<String, FigmaScreenSpec> figmaSpecs;

  /// Why a screen's declared `figmaSource:` could not be resolved.
  ///
  /// A declared design that did not load is ERROR, not skip: "not
  /// configured" and "configured and broken" send a reader to
  /// completely different places.
  final Map<String, String> figmaFailures;

  /// Issues a screen's declared `apiSource:` request, when the capture
  /// could not supply the response. Never called otherwise.
  final ApiFetcher apiFetcher;

  /// Resolves `env:` references for API and Figma credentials.
  final SecretResolver secrets;

  /// Where accepted screenshots live. Null disables visual comparison.
  final BaselineStore? baselines;

  /// Replaces each compared baseline with this run's capture.
  ///
  /// Off unless asked for: a run that re-records on difference can
  /// never fail the same way twice.
  final bool updateBaselines;

  final Directory outputDirectory;
  final void Function(String) log;

  final List<StepOutcome> _steps = <StepOutcome>[];
  final List<ScreenResult> _screens = <ScreenResult>[];
  final List<ApiExpectationOutcome> _apiChecks = <ApiExpectationOutcome>[];

  Future<RunResult> run({required String device}) async {
    final startedAt = DateTime.now().toUtc();
    final overall = Stopwatch()..start();

    for (final step in flow.steps) {
      // From the run's stopwatch, not the wall clock: monotonic, so the
      // order and spacing of steps survive a clock that steps mid-run.
      final startedOffsetMs = overall.elapsedMilliseconds;
      final watch = Stopwatch()..start();
      log('  › ${step.describe()}');

      try {
        await _execute(step);
        _steps.add(
          StepOutcome(
            description: step.describe(),
            // From the concrete step, while it is still in scope. This
            // is the only place in the system that knows what the step
            // was without having to read a sentence about it.
            kind: stepKindOf(step),
            status: StepStatus.ok,
            durationMs: watch.elapsedMilliseconds,
            startedOffsetMs: startedOffsetMs,
          ),
        );
      } catch (error) {
        final status = stepStatusFor(error);
        log('    ${status == StepStatus.observationFailed ? '!' : '✗'} $error');
        _steps.add(
          StepOutcome(
            description: step.describe(),
            kind: stepKindOf(step),
            status: status,
            durationMs: watch.elapsedMilliseconds,
            detail: '$error',
            startedOffsetMs: startedOffsetMs,
          ),
        );
        // Stop here. Every later step would fail for a reason that is
        // not the real one.
        break;
      }
    }

    final result = RunResult(
      flowName: flow.name,
      appId: flow.appId,
      device: device,
      startedAt: startedAt,
      duration: overall.elapsed,
      steps: _steps,
      screens: _screens,
      apiChecks: _apiChecks,
      fixture: fixture,
      appVersion: appVersion,
      buildMode: buildMode,
      sessionId: session.handshake.sessionId,
      // Everything the run captured, and the four facts that say how much
      // of the application's traffic that could have been. All of them
      // are already known to the session; nothing is measured here.
      network: NetworkRecord.observe(
        advertised: session.handshake.capabilities.contains('network'),
        // What the connected SDK says about its own durations - not what
        // this CLI's version would suggest, since an application pins its
        // own SDK.
        monotonicTiming: session.handshake.capabilities
            .contains('monotonicNetworkTiming'),
        correlation: session.correlate(),
        droppedEventCount: session.handshake.droppedEventCount,
        protocolFailure: session.transport.protocol.failure,
        connectionLost:
            session.transport.liveness == TransportLiveness.disconnected,
      ),
    );

    // Every dimension, including the ones that had nothing to say. A
    // reader who sees only PASS cannot tell which sources of truth it
    // speaks for, and a dimension left out of the block reads as
    // evidence when it is in fact a silence.
    log('');
    for (final entry in result.dimensions.entries) {
      final verdict = entry.value;
      final name = entry.key.wire.toUpperCase().padRight(8);
      log('  $name ${verdict.status.wire.toUpperCase().padRight(6)}'
          '${verdict.reason == null ? '' : '  ${verdict.reason}'}');
    }
    log('  ${'OVERALL'.padRight(8)} ${result.overall.wire.toUpperCase()}');

    return result;
  }

  Future<void> _execute(Step step) async {
    switch (step) {
      // The app is already launched by AppSession; this step marks the
      // point in the flow rather than doing the work twice.
      case LaunchAppStep():
        return;

      case WaitForSettleStep(:final timeout):
        final verdict = await session.waitForSettle(
          timeout: timeout,
          policy: _policyForCurrentScreen,
        );
        if (verdict.permitted.isNotEmpty) {
          // Never silently. A screen that settled only because two
          // animations were excused must say so on the way past.
          log('    settled with ${verdict.permitted.length} permitted '
              'animation${verdict.permitted.length == 1 ? '' : 's'}: '
              '${verdict.excludedElements.join(', ')}');
        }

      case TapStep(:final elementId):
        await session.tapById(elementId);

      case InputStep(:final elementId, :final value):
        // Focus, wait for the platform to be ready, type, and prove it
        // all arrived. Tapping and typing straight away loses the
        // leading characters - DEF-E05-04, measured on a real handset.
        await session.enterTextById(elementId, value);

      // A second lock on a door that is already shut: `TestFlow.parse`
      // cannot produce this step. Reaching here would mean a credential
      // was about to be typed by something whose report renders values.
      case SecretInputStep():
        throw StateError(
          'a secret input step is only valid in an auth flow; `testsmith run` '
          'and `testsmith suite run` refuse it',
        );

      case BackStep():
        await session.device.pressBack();

      case ExpectScreenStep(:final screenId, :final timeout):
        await _awaitScreen(screenId, timeout);

      case ExpectElementStep():
        await _expectElement(step);

      case ScreenshotStep(:final name):
        final screenId = session.manager.currentScreenId;
        final path = mappings[screenId]?.visual.capture ??
            VisualCheckConfig.defaults.capture;
        final bytes = (await session.capture(path)).bytes;
        final file = File('${outputDirectory.path}/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        log('    saved ${file.path}');

      case ExpectApiStep():
        await _expectApi(step);

      case ValidateScreenStep():
        await _validate(step);
    }
  }

  /// Asserts on an exchange the application actually made.
  ///
  /// Retried until the deadline rather than read once. The assertion
  /// follows a tap; the request then travels to the host and the event
  /// back over the VM Service, so a single read races the thing it is
  /// asserting about.
  ///
  /// The outcome is recorded whether it held or not - a failed API
  /// assertion belongs in the report as a row, not only as the reason
  /// the run stopped.
  Future<void> _expectApi(ExpectApiStep step) async {
    const evaluator = ApiExpectationEvaluator();
    final deadline = DateTime.now().add(step.timeout);

    var outcome = evaluator.evaluate(
      step: step,
      history: session.correlate().sessions,
    );

    while (!outcome.satisfied && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      outcome = evaluator.evaluate(
        step: step,
        history: session.correlate().sessions,
      );
    }

    _apiChecks.add(outcome);

    if (outcome.satisfied) {
      log('    ✓ api ${outcome.describe()}');
      return;
    }

    log('    ✗ api ${outcome.endpoint}');
    for (final failure in outcome.failures) {
      log('        $failure');
    }

    throw StateError(
      'the API assertion on ${outcome.endpoint} did not hold: '
      '${outcome.failures.join('; ')}',
    );
  }

  /// What the screen currently on declares about its animations.
  ///
  /// Read at the moment it is needed rather than captured once: a
  /// `waitForSettle` may be waiting for a screen that has not arrived
  /// yet, and the declaration belongs to whichever screen is on.
  QuiescencePolicy _policyForCurrentScreen() {
    final screenId = session.manager.currentScreenId;
    if (screenId == null) return QuiescencePolicy.none;
    return _policyForScreen(screenId);
  }

  QuiescencePolicy _policyForScreen(String screenId) =>
      mappings[screenId]?.quiescence ?? QuiescencePolicy.none;

  /// Asserts one fact about one element, retrying until the deadline.
  ///
  /// Retried rather than read once: the assertion follows a tap or a
  /// navigation, and the screen may still be arriving. A single read
  /// turns a slow machine into a failure.
  Future<void> _expectElement(ExpectElementStep step) async {
    final deadline = DateTime.now().add(step.timeout);
    String? lastProblem;

    while (true) {
      final snapshot = await session.captureUiTree();
      lastProblem = elementAssertionProblem(step, snapshot);
      if (lastProblem == null) return;
      if (!DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    throw StateError(
      'after ${step.timeout.inSeconds}s, $lastProblem',
    );
  }

  /// Whether a screenshot baseline has already been recorded.
  bool _hasBaseline(String screenId) {
    final store = baselines;
    return store != null && store.imageFile(screenId).existsSync();
  }

  /// Compares this run's screenshot with the accepted baseline.
  ///
  /// Which picture is taken comes from the screen's `visual.capture`.
  /// With the default `screencap` the image includes the status and
  /// navigation bars, whose clock and battery change between runs -
  /// which is what the configured ignore regions are for. With
  /// `surface` there are no system bars in the image at all, and the
  /// ignore regions for them become dead configuration rather than a
  /// silent mismatch, because the store refuses to compare the two.
  Future<List<ValidationResult>> _compareVisually(
    String screenId,
    UiSnapshot snapshot,
    QuiescenceVerdict quiescence,
  ) async {
    final store = baselines;
    if (store == null) {
      return const [
        ValidationResult.skip(
          validatorId: VisualValidator.id,
          dimension: ValidationDimension.visual,
          message: 'no baseline directory is configured for this project',
        ),
      ];
    }

    // An animation nobody declared means the picture is not reproducible
    // and there is no honest comparison to make. An error rather than a
    // fail - the application is not necessarily wrong - and never a
    // pass, which is what comparing anyway would eventually produce.
    if (quiescence.unexpected.isNotEmpty || quiescence.blockers.isNotEmpty) {
      return [
        ValidationResult.error(
          validatorId: VisualValidator.id,
          dimension: ValidationDimension.visual,
          message: 'cannot photograph "$screenId" deterministically: '
              '${quiescence.blockers.join('; ')}',
        ),
      ];
    }

    // Excluding needs somewhere to exclude. An animation whose position
    // the application could not report would be compared after all - at
    // random. Skip and say why, rather than record a green that means
    // nothing. See STOP-2 step 7.
    if (quiescence.unlocatable.isNotEmpty) {
      return [
        ValidationResult.skip(
          validatorId: VisualValidator.id,
          dimension: ValidationDimension.visual,
          message: 'permitted '
              '${quiescence.unlocatable.map((a) => a.owner).join(', ')} '
              'reported no bounds, so the pixels that change every frame '
              'cannot be excluded. Comparing anyway would pass or fail at '
              'random',
        ),
      ];
    }

    final declared = mappings[screenId]?.visual ?? VisualCheckConfig.defaults;

    // A permitted animation differs in every frame, so its pixels come
    // out of the comparison. Derived from the declaration rather than
    // written twice: an author who declares an animation should not also
    // have to remember to ignore it visually, and the two drifting apart
    // is how a check goes quietly flaky.
    final config = declared.excludingRegions(quiescence.excludedRegions);

    final Uint8List bytes;
    final ScreenshotSource source;
    try {
      // Two photographs that agree, not one taken on trust.
      //
      // A settle reading is taken before the shutter, and the screen can
      // change after it: measured on a real dashboard, `awaitQuiescence`
      // reported a quiet screen and the picture still caught the outlet
      // images part-way through their fade-in, 44% different from a
      // baseline of the same screen fully painted. Nothing was wrong
      // with either the reading or the capture - the gap between them is
      // simply real, and a quiet period cannot close it, because more
      // than 500ms can pass between one image arriving and the next.
      //
      // So the screen is photographed twice and the pair must agree
      // outside the ignored regions. A permitted animation changes every
      // frame and is already excluded, so it does not prevent agreement;
      // a screen still assembling itself does, and says so.
      final taken = await _photographWhenSteady(config, snapshot);
      if (taken == null) {
        return [
          ValidationResult.skip(
            validatorId: VisualValidator.id,
            // Stamped here because this result never reaches
            // VisualValidator, which is what stamps the rest of them.
            // Unstamped it is refused by ValidationReport - so a screen
            // that would not hold still ended the run with
            // UndimensionedResultException instead of the skip it is.
            dimension: ValidationDimension.visual,
            message: 'the screen would not hold still: two photographs '
                'taken in a row kept differing outside the ignored '
                'regions, so there is no picture of "$screenId" worth '
                'comparing. Nothing here says the screen is wrong',
          ),
        ];
      }
      bytes = taken.bytes;
      source = taken.source;
    } on StateError catch (error) {
      // The app cannot take the picture that was asked for. An error,
      // not a fall back to the other path: a silent substitution would
      // be compared against a baseline recorded the other way.
      return [
        ValidationResult.error(
          validatorId: VisualValidator.id,
          // As above: this one is built before VisualValidator is
          // reached, so nothing else will stamp it.
          dimension: ValidationDimension.visual,
          message: '$error',
        ),
      ];
    }

    return const VisualValidator().validate(
      screenId: screenId,
      screenshot: bytes,
      source: source,
      store: store,
      snapshot: snapshot,
      config: config,
      updateBaseline: updateBaselines,
    );
  }

  /// A photograph the screen agreed to twice.
  ///
  /// Returns null when it never held still. That is a skip rather than a
  /// failure: an unstable screen is a thing the tool could not measure,
  /// not a claim about the application.
  ///
  /// The rule itself lives in [SteadyCapture], where it can be exercised
  /// against a dictated sequence of pictures. Reproducing an unsteady
  /// screen on a device now means arranging one that changes while no
  /// ticker runs and no request is in flight, which the platform's own
  /// in-flight tracking has largely closed off - so the logic would
  /// otherwise go untested.
  Future<({Uint8List bytes, ScreenshotSource source})?> _photographWhenSteady(
    VisualCheckConfig config,
    UiSnapshot snapshot, {
    int attempts = 3,
  }) async {
    ScreenshotSource? source;

    final bytes = await SteadyCapture(attempts: attempts).take(
      capture: () async {
        final taken = await session.capture(config.capture);
        source = taken.source;
        return taken.bytes;
      },
      tolerances: config.tolerances,
      // Whatever the comparison itself ignores - a clock that ticks once
      // a minute, and every permitted animation - because a screen must
      // not be called unsteady for the things already excused.
      ignore: _steadinessIgnores(config, snapshot.devicePixelRatio),
    );

    if (bytes == null || source == null) return null;
    return (bytes: bytes, source: source!);
  }

  /// Regions the steadiness check must not look at.
  ///
  /// Bottom-anchored entries (a negative `y`) are left out rather than
  /// resolved: doing so needs the image height, which would mean
  /// decoding the picture here purely to skip a static navigation bar.
  /// Omitting them only makes this check stricter, and a strict check
  /// retries rather than failing.
  List<PixelRegion> _steadinessIgnores(
    VisualCheckConfig config,
    double ratio,
  ) =>
      [
        for (final (index, rect) in config.ignoreRegions.indexed)
          if (rect.y >= 0)
            PixelRegion(
              label: 'ignore[$index]',
              x: (rect.x * ratio).round(),
              y: (rect.y * ratio).round(),
              width: (rect.width * ratio).round(),
              height: (rect.height * ratio).round(),
            ),
      ];

  /// Waits for the app to reach [screenId].
  ///
  /// Navigation events travel from the app over the VM Service, so a
  /// check made the instant a tap returns races the event it is
  /// asserting about.
  Future<void> _awaitScreen(String screenId, Duration timeout) =>
      awaitScreenEvidence(
        screenId: screenId,
        timeout: timeout,
        routerRoute: () => session.manager.currentScreenId,
        screensVisited: () => session.manager.screenHistory,
        capture: session.captureUiTree,
        liveness: () => session.transport.liveness,
        protocol: () => session.transport.protocol,
      );

  Future<void> _validate(ValidateScreenStep step) async {
    final screenId = session.manager.currentScreenId;
    if (screenId == null) {
      throw StateError('there is no current screen to validate');
    }

    // Capture the tree now, so validation sees the screen as it is at
    // this point in the flow.
    final snapshot = await session.captureUiTree();
    final correlation = session.correlate();

    // What is moving, and whether this screen said it would be. Read
    // here rather than inherited from an earlier step: a screen can
    // start animating after it arrives.
    //
    // Waited for rather than sampled once when a photograph is about to
    // be taken. A single reading a moment after a successful
    // `waitForSettle` can disagree with it - a network image arriving
    // is the screen settling, not a screen that will not - and turning
    // that into an error would make visual comparison flaky for the
    // opposite reason to the one this milestone is about.
    final hasBaseline = _hasBaseline(screenId);
    final willPhotograph = step.runsVisual(hasBaseline: hasBaseline);
    final quiescence = willPhotograph
        ? await session.awaitQuiescence(policy: () => _policyForScreen(screenId))
        : (await session.readSettle()).against(_policyForScreen(screenId));

    final screenSession = correlation.sessions.lastWhere(
      (s) => s.screenId == screenId,
      orElse: () => ScreenSession(
        screenId: screenId,
        enteredAt: DateTime.now().toUtc(),
      ),
    )..uiSnapshot = snapshot;

    // Capture first. A fetch is issued only when this comes back with
    // nothing, so a fully-instrumented run makes no outbound request of
    // its own - and an *ambiguous* capture never falls back at all.
    final acquired = await const ApiAcquirer().acquire(
      mappings: mappings[screenId],
      session: screenSession,
      history: correlation.sessions,
      fetcher: apiFetcher,
      secrets: secrets,
    );

    final context = ValidationContext(
      session: screenSession,
      acquired: acquired,
      // The whole run, so a screen that declares `usesResponseFrom:`
      // can be validated against a response captured before it was
      // entered. Nothing reads this unless a mappings file asks.
      sessionHistory: correlation.sessions,
      mappings: mappings[screenId],
      figmaSpec: figmaSpecs[screenId],
      figmaTolerances: mappings[screenId]?.figma,
    );

    // runValidator rather than validate: it stamps each validator's
    // dimension onto the results that do not name their own, so the
    // report never has to guess a dimension from a validator's name.
    final results = <ValidationResult>[
      if (step.runsUi) ...runValidator(const UiPresenceValidator(), context),
      if (step.runsApi) ...runValidator(const ApiToUiValidator(), context),
      if (step.runsRules) ...runValidator(const RulesValidator(), context),
      // A declared design that could not be loaded is an ERROR in the
      // figma dimension. Letting the structure validator skip here would
      // report "no design configured" about a design that is configured.
      if (step.runsFigma && figmaFailures.containsKey(screenId))
        ValidationResult.error(
          validatorId: 'figma-source',
          dimension: ValidationDimension.figma,
          message: figmaFailures[screenId]!,
        )
      else if (step.runsFigma)
        ...runValidator(const FigmaStructureValidator(), context),
    ];

    // Asynchronous, so it cannot join the list above: the comparison
    // decodes and diffs a few million pixels on a background isolate.
    //
    // Whether it runs at all depends on a baseline already existing,
    // because unlike every other check this one writes a file. See
    // ValidateScreenStep.runsVisual.
    if (willPhotograph) {
      results.addAll(await _compareVisually(screenId, snapshot, quiescence));
    } else if (step.visual == null && !hasBaseline) {
      // Say so rather than leaving the row out. Automatic mode declined
      // to record a baseline on its own, and a reader who sees no
      // visual row at all cannot tell that from the check having
      // quietly passed.
      results.add(
        ValidationResult.skip(
          validatorId: VisualValidator.id,
          dimension: ValidationDimension.visual,
          message: 'no screenshot baseline for "$screenId" yet. Automatic '
              'mode will not record one, because that writes a file into '
              'the repository. Run this step with `visual: true` once to '
              'record it.',
        ),
      );
    }

    final report = ValidationReport(results);

    _screens.add(
      ScreenResult(
        screenId: screenId,
        report: report,
        uiNodeCount: snapshot.retainedNodeCount,
        // Carried into the report, not only logged: a PASS that depended
        // on two excused animations should say so in the file people
        // read as well as in the terminal they did not watch.
        quiescence: QuiescenceSummary(
          ticking: quiescence.consideredCount,
          permitted: quiescence.permitted.length,
          unexpected: quiescence.unexpected.length,
          lines: quiescence.describeLines(),
        ),
        exchanges: [
          for (final exchange in screenSession.exchanges)
            ExchangeSummary(
              requestId: exchange.request.requestId,
              method: exchange.request.method,
              path: exchange.request.path,
              statusCode: exchange.response?.statusCode,
              error: exchange.response?.error,
              // Null, not 0, for a request nobody answered: a 0 is a
              // measurement, and none was made.
              durationMs: exchange.response?.durationMs,
            ),
        ],
      ),
    );

    // Said out loud whenever anything is moving at all, and before the
    // rows it affects. An exclusion nobody mentions is a hole in the
    // check; this is the difference between a report that says PASS and
    // one that says what PASS covered.
    if (quiescence.consideredCount > 0 || quiescence.belowTopRoute.isNotEmpty) {
      log('    quiescence:');
      for (final line in quiescence.describeLines()) {
        log('      $line');
      }
    }

    for (final result in results) {
      final mark = switch (result.status) {
        ValidationStatus.pass => '✓',
        ValidationStatus.fail => '✗',
        ValidationStatus.skip => '-',
        ValidationStatus.error => '!',
      };
      log('    $mark ${result.validatorId}'
          '${result.elementId == null ? '' : ' ${result.elementId}'}: '
          '${result.message}');
    }

    if (!report.passed) {
      throw StateError(
        'validation failed: ${report.failCount} failed, '
        '${report.errorCount} errored',
      );
    }
  }
}

/// How a step that threw [error] should be recorded.
///
/// The one place a run decides "the application did something wrong"
/// against "the engine could not look". Decided by type, through the
/// predicate the transport already owns, so there is no second list to
/// drift from the first and no message text to rephrase by accident.
///
/// Everything that is not one of the three infrastructure failures keeps
/// the behaviour it always had, including an unexpected programmer
/// error: a bug in this codebase must keep surfacing as a failing step
/// rather than being filed as a flaky device.
StepStatus stepStatusFor(Object error) => isInfrastructureFailure(error)
    ? StepStatus.observationFailed
    : StepStatus.failed;

/// The process exit code for a finished run.
///
/// The CI contract this repository already states on `SuiteVerdict`:
/// 0 passed, 1 something is wrong with the application, 2 something is
/// wrong with the run. `testsmith run` returned 1 for everything that did
/// not pass, so a device that went to sleep sent someone to read a
/// screen.
int exitCodeForRun(RunResult result) {
  // The run's own verdict, so `testsmith run`, `testsmith suite run` and both
  // reports cannot disagree about what kind of problem a run had. ERROR
  // covers a lost connection *and* a check that could not be
  // established - both mean nothing was shown about the application,
  // and exit 1 would send someone to read a screen nobody measured.
  return switch (result.overall) {
    ValidationStatus.error => 2,
    ValidationStatus.fail => 1,
    ValidationStatus.pass || ValidationStatus.skip => 0,
  };
}

/// Waits for the application to be on [screenId], and on failure says
/// what every available reading actually said.
///
/// There are two places a route name can be read, and it is worth being
/// exact about what they are, because it bounds what this can honestly
/// claim:
///
///   R1  [routerRoute] - `SessionManager.currentScreenId`, rebuilt by
///       the engine from the navigation events it has received over the
///       VM Service;
///   R2  `UiSnapshot.screenId` - the application's own
///       `_currentScreenId`, read live when the tree is captured.
///
/// Both trace to `TestNavigatorObserver.resolveScreenId`. They are the
/// same source sampled at two points through two transports, **not** two
/// independent witnesses, and nothing here pretends otherwise. The
/// captured tree cannot supply a third: `routeIndex` is an ordinal, so a
/// capture can say "two routes are built and the second is on top" and
/// can never say "the second one is /home".
///
/// What that leaves is still worth having. R2 is the *fresher* sample:
/// an event that has not arrived, or was dropped, makes R1 stale while
/// the application sits on exactly the screen that was asked for. So the
/// event stream decides, as it always did, and only when it has run out
/// of time is one capture taken - one, not one per poll, because walking
/// the element tree of a real application is not something to do every
/// 100ms for a route that has already arrived.
///
/// The number of routes the capture found built is reported and never
/// used for the verdict. It is the one thing the tree can say by itself,
/// and it says nothing about identity.
Future<void> awaitScreenEvidence({
  required String screenId,
  required Duration timeout,
  required String? Function() routerRoute,
  required List<String> Function() screensVisited,
  Future<UiSnapshot> Function()? capture,
  TransportLiveness Function()? liveness,
  ProtocolObservation Function()? protocol,
  Duration captureTimeout = const Duration(seconds: 5),
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);

  while (true) {
    // Liveness first, deliberately. Once the connection has gone, the
    // route reading is simply the last one that arrived before it went -
    // so answering from it would be exactly the mistake this checks
    // for: "the engine stopped receiving events" reported as "the
    // application navigated".
    //
    // Only an explicit failure stops the wait. A quiet healthy
    // connection is a healthy connection, and waits out its deadline
    // like any other.
    // Protocol before liveness. When an application dies mid-stream both
    // are true, and the decode failure happened while the connection was
    // still up - so it is the cause and the disconnect is the
    // consequence. Naming the cause sends a reader to the version skew
    // rather than to the cable.
    final readable = protocol?.call();
    if (readable != null && !readable.isIntact) {
      throw ProtocolObservationException(readable.failure!);
    }

    final state = liveness?.call();
    if (state != null && !state.isUsable) {
      throw TransportDisconnectedException(state);
    }

    if (routerRoute() == screenId) return;
    if (!DateTime.now().isBefore(deadline)) break;
    await Future<void>.delayed(pollInterval);
  }

  final router = routerRoute();

  // One capture, on the failing path only.
  UiSnapshot? snapshot;
  String? captureFailure;
  if (capture != null) {
    try {
      // Bounded by [captureTimeout]. `VmServiceTransport.invoke` has no
      // deadline of its own, so an application that has stopped
      // answering would otherwise hang here - on the diagnostic, which
      // is the least important part of the failure being reported.
      snapshot = await capture().timeout(captureTimeout);
    } catch (error) {
      // A broken capture is a footnote. The route that never arrived is
      // the finding, and replacing it with a transport error would hide
      // the thing being measured behind the thing measuring it.
      captureFailure = '$error';
    }
  }

  if (snapshot != null && snapshot.screenId == screenId) return;

  final routesBuilt = snapshot?.topRouteIndex;
  throw StateError(
    'expected to be on "$screenId" within ${timeout.inSeconds}s.\n'
    '  router (from navigation events): '
    '"${router ?? 'no screen yet'}"\n'
    '  application (read at capture): '
    '${snapshot == null ? (captureFailure == null ? 'not captured' : 'could not be captured: $captureFailure') : '"${snapshot.screenId}"'}\n'
    '  routes built in the captured tree: '
    '${snapshot == null ? 'unknown' : (routesBuilt == null ? 'the capture records no routes' : '$routesBuilt')}\n'
    '  screens visited: ${screensVisited().join(' -> ')}',
  );
}

/// What is wrong with [step]'s element on [snapshot], or null if nothing
/// is.
///
/// A pure function of a step and a capture, rather than a method on the
/// executor, so the rules can be pinned without a handset. The retry
/// around it belongs to the executor; the verdict belongs here.
///
/// `enabled` is read through [readPropertyOf] and the rest is read off
/// the named node. That split is not an oversight:
///
/// * `enabled` is derived per widget type, so every wrapper reports
///   null - "no such notion". On the ordinary shape
///   `TestId > AppSizedBox > ElevatedButton` the raw read always
///   answered null, which made the assertion unwritable against a real
///   application rather than merely awkward.
/// * `visible` describes one element. A hidden wrapper holding a
///   visible child is hidden, and borrowing the child's answer would be
///   a different claim.
/// * `text` already has its own resolution elsewhere, with rules about
///   icon glyphs this assertion has no business restating.
///
/// A property whose descendants disagree is reported as **ambiguous**
/// rather than compared: a verdict either way would be a guess
/// presented as a measurement.
String? elementAssertionProblem(ExpectElementStep step, UiSnapshot snapshot) {
  // On the screen, not merely in the tree.
  //
  // Flutter keeps a covered route built, so after a dialog or a push the
  // tree still holds the screen underneath at its old bounds, reporting
  // `visible: true`. This assertion's wording was always "on the
  // screen"; only its measurement was "in the tree", and the two part
  // company the moment anything is pushed.
  final onScreen = snapshot.nodesOnTopRoute(step.elementId);

  // Two of them on the screen in front of the reader. Asserting about
  // whichever copy a depth-first search reached first is a verdict with
  // no defensible basis - and "absent" is plainly false as well, so this
  // comes before `present` rather than after it.
  //
  // Counted on the visible route only. A copy left behind on a covered
  // screen is not a candidate for anything.
  if (onScreen.length > 1) {
    return '"${step.elementId}" matches ${onScreen.length} elements on '
        'route ${snapshot.topRouteIndex}, so an assertion about it has no '
        'single meaning. Give each element a distinct test id';
  }

  final node = onScreen.isEmpty ? null : onScreen.single;

  if (step.present == false) {
    // An element the flow navigated away from **satisfies** this. It is
    // not on the screen, which is what was asserted; that Flutter has
    // not disposed it is an implementation detail of Flutter.
    return node == null
        ? null
        : '"${step.elementId}" is on the screen and should not be';
  }

  if (node == null) {
    // Covered is a different disappointment from missing, and it sends
    // a reader somewhere different: to the thing in the way, rather
    // than to a typo. Said separately for that reason.
    final buried = snapshot.find(step.elementId);
    if (buried != null) {
      return '"${step.elementId}" is in the tree on route '
          '${buried.routeIndex}, but route ${snapshot.topRouteIndex} is on '
          'top, so it is not on the screen. Flutter keeps a covered route '
          'built - the element is still there, behind whatever was pushed '
          'over it. Dismiss what is on top, or assert about the screen '
          'that is';
    }
    return '"${step.elementId}" is not on the screen. Present: '
        '${(snapshot.topRouteTestIds.toList()..sort()).join(', ')}';
  }

  final expectedEnabled = step.enabled;
  if (expectedEnabled != null) {
    switch (readPropertyOf(node, 'enabled')) {
      case PropertyAmbiguous(:final reason):
        return '"${step.elementId}" cannot be judged: $reason';
      case PropertyValue(:final value) when value != expectedEnabled:
        return '"${step.elementId}" reports enabled = $value, '
            'expected $expectedEnabled';
      case PropertyValue():
        break;
    }
  }

  if (step.visible != null && node.visible != step.visible) {
    return '"${step.elementId}" reports visible = ${node.visible}, '
        'expected ${step.visible}';
  }
  if (step.text != null && node.text != step.text) {
    return '"${step.elementId}" reads "${node.text}", expected '
        '"${step.text}"';
  }
  final contains = step.textContains;
  if (contains != null && !(node.text ?? '').contains(contains)) {
    return '"${step.elementId}" reads "${node.text}", which does not '
        'contain "$contains"';
  }
  return null;
}

/// The resolver a run uses when none was supplied.
///
/// A class rather than a default argument so [FlowExecutor]'s
/// constructor stays const-friendly for callers that pass their own.
class _DefaultSecrets implements SecretResolver {
  const _DefaultSecrets();

  @override
  bool isPresent(SecretRef ref) => EnvSecretResolver().isPresent(ref);

  @override
  Secret resolve(SecretRef ref) => EnvSecretResolver().resolve(ref);
}
