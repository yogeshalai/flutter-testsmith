import 'dart:io';

import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:flutter_testsmith/engine.dart';

import 'app_session.dart';
import 'flow_executor.dart';
import 'mock_api_server.dart';

/// Executes one flow and returns its result.
///
/// An interface so a suite's orchestration - ordering, fail-fast,
/// lifecycle, aggregation - can be tested without a device. The only
/// implementation that touches hardware is [FlowRunner].
abstract interface class FlowExecution {
  Future<RunResult> execute({
    required TestFlow flow,
    required Directory outputDirectory,
    String? fixture,
    void Function(BaselineEnvironment environment, DeviceFacts facts)?
        onDescribed,

    /// Every route the application entered, in order, read just before
    /// the session is torn down.
    ///
    /// Reported rather than asserted on. Saying where the application
    /// went is the runner's job; knowing what that means - that this
    /// application shows `/login` when it holds no session - belongs to
    /// whoever wrote the suite, because only they know it.
    ///
    /// It is what lets a suite tell "this screen is wrong" apart from
    /// "the device was never ready to be asked", without the runner
    /// reading a single byte of the application's own storage.
    void Function(List<String> screenHistory)? onScreensObserved,
  });
}

/// Runs one flow against one device, end to end.
///
/// This is the middle of what `testsmith run` has always done: point the
/// fixture server at the state the flow names, launch the application,
/// record what the run is happening on, execute the flow, and tear the
/// session down again.
///
/// It exists as its own unit so a suite can do it repeatedly without a
/// second execution engine. `testsmith run` and `testsmith suite run` call
/// exactly this, so "a flow behaves the same alone as in a suite" is a
/// property of the structure rather than a promise in a document.
class FlowRunner implements FlowExecution {
  const FlowRunner({
    required this.projectDirectory,
    required this.deviceSerial,
    required this.mappings,
    required this.figmaSpecs,
    required this.log,
    this.figmaFailures = const {},
    this.secrets,
    this.mockApi,
    this.target,
    this.flavor,
    this.dartDefines = const [],
    this.profile,
    this.updateBaselines = false,
  });

  final Directory projectDirectory;
  final String deviceSerial;
  final Map<String, MappingsFile> mappings;
  final Map<String, FigmaScreenSpec> figmaSpecs;

  /// Why a screen's declared `figmaSource:` could not be resolved.
  final Map<String, String> figmaFailures;

  /// Resolves `env:` references. Null uses the process environment and
  /// any `.env` file, which is what `testsmith run` wants.
  final SecretResolver? secrets;

  final void Function(String) log;

  /// The fixture server, when one is running. Its scenario is swapped to
  /// whatever each flow names before that flow runs.
  final MockApiServer? mockApi;

  final String? target;
  final String? flavor;
  final List<String> dartDefines;

  /// The profile this run is executing under, when a suite named one.
  ///
  /// Null for a plain `testsmith run`, and then baselines resolve exactly
  /// as they did before profiles existed.
  final DeviceProfile? profile;

  final bool updateBaselines;

  /// What the device and the application say about themselves.
  ///
  /// Read from the device and the handshake rather than typed into a
  /// file: a provenance note somebody maintains separately is a
  /// provenance note that goes stale. Used to record baselines, and by a
  /// suite to check that the device in front of it is the one its
  /// profile describes.
  Future<({BaselineEnvironment environment, DeviceFacts facts})> describe(
    AppSession session,
  ) async {
    try {
      final info = await session.device.info();
      final app = session.handshake.app;
      return (
        environment: BaselineEnvironment(
          device: deviceSerial,
          deviceModel: info.model,
          osVersion: 'Android ${info.androidVersion}',
          appVersion: app.appVersion,
          buildMode: app.buildMode.wire,
          devicePixelRatio: app.devicePixelRatio,
        ),
        facts: DeviceFacts(
          model: info.model,
          os: 'Android ${info.androidVersion}',
          devicePixelRatio: app.devicePixelRatio,
          buildMode: app.buildMode.wire,
        ),
      );
    } catch (error) {
      // Never fatal. Failing a run because the device would not say what
      // model it is would be absurd; the baseline simply records less.
      log('  ! could not read the device for the baseline record: $error');
      return (
        environment: const BaselineEnvironment(),
        facts: const DeviceFacts(),
      );
    }
  }

  /// Executes [flow] and returns its result.
  ///
  /// The session is launched and disposed here, so each flow starts from
  /// a freshly launched application - which is what `testsmith run` does,
  /// and therefore what a suite must do for its results to mean the same
  /// thing.
  @override
  Future<RunResult> execute({
    required TestFlow flow,
    required Directory outputDirectory,
    String? fixture,
    void Function(BaselineEnvironment environment, DeviceFacts facts)?
        onDescribed,
    void Function(List<String> screenHistory)? onScreensObserved,
  }) async {
    final session = await AppSession.launch(
      projectDirectory: projectDirectory,
      deviceSerial: deviceSerial,
      appId: flow.appId,
      reversePort: mockApi?.port,
      dartDefines: dartDefines,
      target: target,
      flavor: flavor,
      log: log,
    );

    try {
      final described = await describe(session);
      onDescribed?.call(described.environment, described.facts);

      return await FlowExecutor(
        flow: flow,
        session: session,
        mappings: mappings,
        figmaSpecs: figmaSpecs,
        figmaFailures: figmaFailures,
        secrets: secrets,
        baselines: BaselineStore(
          Directory('${projectDirectory.path}/visual_baselines'),
          // A screen looks different under a different API state, and
          // that is not a regression. Baselines are therefore recorded
          // per fixture; the default state keeps the plain file name, so
          // every baseline recorded before this existed still resolves.
          variant: fixture,
          profile: profile,
          environment: described.environment,
        ),
        updateBaselines: updateBaselines,
        outputDirectory: outputDirectory,
        // The run's preconditions, from the two values already in hand:
        // the scenario this execution was told to run against - the
        // effective one, so a `--fixture` override is recorded as what
        // actually ran - and what the application said about itself at
        // the handshake. The same `described.environment` the suite
        // records, so the two artefacts cannot disagree about the build.
        fixture: fixture,
        appVersion: described.environment.appVersion,
        buildMode: described.environment.buildMode,
        log: log,
      ).run(device: deviceSerial);
    } finally {
      // Read before the session goes away, and on every path out - a
      // flow that threw is exactly the case where where it got to is
      // worth knowing.
      onScreensObserved?.call(session.manager.screenHistory);
      await session.dispose();
    }
  }
}
