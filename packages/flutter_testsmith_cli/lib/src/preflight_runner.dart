import 'dart:io';

import 'package:flutter_testsmith/engine.dart';

import 'mock_api_server.dart';
import 'project_config.dart';

/// Whether a host port can be bound.
///
/// Injected so the check is testable without racing a real socket.
typedef PortProbe = Future<bool> Function(int port);

/// Binds and immediately releases [port], to find out whether it is free.
Future<bool> hostPortIsFree(int port) async {
  try {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await server.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// How a duplicated screen is phrased, wherever it is found.
///
/// `suite run` reads the same project at its own step 5 and refuses
/// there rather than reaching preflight, so two commands report this one
/// finding. Composed here and only here, for the reason the check itself
/// gives: deciding *what counts as* a duplicate belongs to the loaders,
/// and describing one the same way twice is how two descriptions start
/// disagreeing about the same two files.
String duplicateScreenMessage(DuplicateScreenException error) =>
    'duplicate screen configuration for "${error.screen}": '
    '${error.paths.map(_fileName).join(', ')}';

/// The same, for a mapping file that would not parse at all.
String unreadableMappingMessage(MappingsFormatException error) =>
    '${_fileName(error.source)} could not be read: ${error.message}';

/// The same again, for a scenario file.
///
/// `ScenarioFormatException` keeps the file in `source` and the reason in
/// `message`, and only its `toString()` joins them. Both readers of this
/// condition took the reason alone, so a blocker said `invalid JSON: ...`
/// about a directory holding several scenarios and named none of them -
/// under a remedy reading "Fix the scenario file". `suite run` printed
/// the path to a terminal and left it out of `suite.json`, so the
/// operator was told which file and the CI gate reading the same run was
/// not; `preflight`, which has no terminal line of its own, lost it for
/// everyone.
///
/// The basename, for the reason [duplicateScreenMessage] gives: a report
/// row is one column-aligned line. It is also the shape
/// `checkMockApi`'s own unit test has always passed in.
String scenarioProblemMessage(ScenarioFormatException error) =>
    '${_fileName(error.source)}: ${error.message}';

String _fileName(String path) => path.split(RegExp(r'[/\\]')).last;

/// `  ! ignoring <path>: <why>` reduced to `<file>: <why>`.
///
/// `loadFigmaSpecs` composes that line for a terminal, where an absolute
/// path is fine. A preflight row is one column-aligned line, so the same
/// shortening [duplicateScreenMessage] does applies here. The backwards
/// search is bounded by the `.json` the loader only ever reports, so a
/// reason containing a separator cannot move it.
String skippedDesignMessage(String reported) {
  final json = reported.indexOf('.json');
  if (json == -1) return reported.trim();
  return reported
      .substring(reported.lastIndexOf(RegExp(r'[/\\]'), json) + 1)
      .trim();
}

/// Gathers every environment fact a suite depends on, and reports what it
/// found.
///
/// The facts come from here; the judgements come from `flutter_testsmith_engine`'s pure
/// check functions. That is the split `doctor` already uses, and it is why
/// the whole of E-04's decision-making is unit tested without a handset.
class PreflightRunner {
  const PreflightRunner({
    required this.suite,
    required this.projectDirectory,
    required this.profile,
    required this.deviceEnvironment,
    required this.attachedDevices,
    required this.requestedSerial,
    required this.deviceFacts,
    required this.portProbe,
    required this.flutterOnPath,
    required this.secrets,
    this.adbProblem,
    this.adbRemedy = '',
  });

  final SuiteFile suite;

  /// The application root, as the suite resolves it.
  final Directory projectDirectory;

  final DeviceProfile profile;
  final DeviceEnvironment deviceEnvironment;
  final List<AdbDevice> attachedDevices;
  final String? requestedSerial;

  /// What adb said about the device, for the static half of profile
  /// verification. The pixel ratio and build mode arrive in the handshake
  /// and are still checked on the first launch.
  final DeviceFacts deviceFacts;

  final PortProbe portProbe;
  final bool flutterOnPath;

  /// Why the device list could not be obtained, or null when it was.
  ///
  /// An empty [attachedDevices] means "adb answered, and nothing is
  /// plugged in" only while this is null.
  final String? adbProblem;

  /// What to do about [adbProblem].
  final String adbRemedy;

  /// How an `env:NAME` reference is looked up, for presence only.
  ///
  /// Injected rather than read from `Platform.environment` here, for the
  /// reason every other fact in this class is injected: the whole of
  /// E-04's decision-making is unit tested without a handset, and a
  /// check that reached for the process environment could not be.
  ///
  /// Presence, never a value. Nothing in preflight resolves a credential
  /// - resolving one would pull it into this process to answer a
  /// question that `isPresent` already answers.
  final SecretResolver secrets;

  Future<PreflightReport> run() async {
    final read = _readFlows();
    final flows = read.parsed;
    final checks = <PreflightCheck>[
      checkAppBuild(
        target: suite.app.target,
        targetExists: suite.app.target == null ||
            File('${projectDirectory.path}/${suite.app.target}').existsSync(),
        flutterOnPath: flutterOnPath,
      ),
    ];

    final device = checkDeviceAttached(
      attached: attachedDevices,
      requested: requestedSerial,
      adbProblem: adbProblem,
      adbRemedy: adbRemedy,
    );
    checks
      ..add(device)
      ..add(checkProfileMatch(profile: profile, facts: deviceFacts));

    final appId = _appId(flows);

    // The device is asked only once it is worth asking. With nothing
    // attached every answer would be "could not read", which says nothing
    // the device check has not already said - and would arrive as three
    // more blockers all pointing at one cause.
    if (device.outcome == PreflightOutcome.satisfied && appId != null) {
      // Null when the device would not answer. Carried as null rather
      // than collapsed to false: "not installed" and "could not ask" send
      // a reader to two different places.
      final installed = await deviceEnvironment.isInstalled(appId);

      checks.add(checkAppInstalled(
        appId: appId,
        installed: installed,
        neededBeforeLaunch: _touchesAppBeforeLaunch,
      ));

      checks.add(checkPermissions(
        appId: appId,
        required: suite.devicePermissions,
        granted: switch (installed) {
          true => await deviceEnvironment.runtimePermissions(appId),
          // Not installed, so nothing is granted - and saying so is
          // better than reporting a permission table nobody read.
          false => {for (final p in suite.devicePermissions) p: false},
          // Nothing was established about the application at all, so
          // nothing can be said about what it was granted.
          null => null,
        },
      ));

      checks.add(
        checkNetworkInterface(await deviceEnvironment.networkInterface()),
      );
    }

    // Read once, here: the check needs the loaders' verdict and the
    // figma prerequisites need what they loaded.
    final (screenConfiguration, mappings) = await _screenConfiguration();
    final figma = mappings == null
        // Nothing parsed, so nothing is known about what any screen
        // declares. The row above is already blocking.
        ? (required: <String>[], optional: <String>[], reachable: 0)
        : _figmaPrerequisites(flows, mappings);

    checks
      ..add(checkFlowsReadable(
        requiredTests: [
          for (final entry in read.unread)
            if (entry.test.required) entry.why,
        ],
        optionalTests: [
          for (final entry in read.unread)
            if (!entry.test.required) entry.why,
        ],
      ))
      ..add(checkFlowStatus(
        proposed: _proposed(flows),
        unread: read.unread.length,
      ))
      ..add(screenConfiguration)
      ..add(await _mockApi(flows))
      ..add(checkBaselines(missing: _missingBaselines(flows)))
      ..add(checkFigmaPrerequisites(
        missingRequired: figma.required,
        missingOptional: figma.optional,
        reachableSources: figma.reachable,
      ))
      ..add(checkAuthentication(
        requiredBy: [
          for (final name in suite.preconditions.keys)
            ...suite.testsRequiring(name),
        ],
      ));

    return PreflightReport(checks);
  }

  /// Whether anything happens to the installed application before the
  /// first launch would install it.
  bool get _touchesAppBeforeLaunch =>
      suite.devicePermissions.isNotEmpty ||
      suite.tests.any(
        (test) => test.reset != StateReset.none || test.grant.isNotEmpty,
      );

  /// Every flow the suite names: the ones that read, and the ones that
  /// would not.
  ///
  /// Both halves, because the second used to be dropped here. "It is
  /// already an ERROR when the suite reaches it" was true and beside the
  /// point: the suite reaches it after the device, the permissions and
  /// the launch of every test before it, which is the cost preflight
  /// exists to save. `testsmith run` refuses the same file before
  /// anything is launched.
  ///
  /// A flow that is not there at all is not counted: `resolveSuiteContext`
  /// refuses a suite naming one, with a list, before any of this runs.
  ///
  /// Each failure is named by the *test*, which the suite supplied - so
  /// nothing is guessed from a file that would not parse.
  ({Map<String, TestFlow> parsed, List<({SuiteTest test, String why})> unread})
      _readFlows() {
    final parsed = <String, TestFlow>{};
    final unread = <({SuiteTest test, String why})>[];

    for (final test in suite.tests) {
      final file = File('${projectDirectory.path}/${test.flow}');
      if (!file.existsSync()) continue;
      try {
        parsed[test.id] = TestFlow.parse(
          file.readAsStringSync(),
          source: file.path,
        );
      } on FlowFormatException catch (error) {
        unread.add((test: test, why: '${test.id}: ${error.message}'));
      } on Object catch (error) {
        // Anything else reading the file - a permission, an encoding.
        // Still a flow this suite cannot run, and still better said now.
        unread.add((test: test, why: '${test.id}: $error'));
      }
    }
    return (parsed: parsed, unread: unread);
  }

  /// The tests whose flows nobody has accepted yet.
  ///
  /// In the order the suite names them, which is the order somebody will
  /// read them in. A flow that will not parse is not here because it is
  /// not in [flows] at all - that gap belongs to the parse itself, and
  /// closing it is a separate question from this one.
  List<String> _proposed(Map<String, TestFlow> flows) => [
        for (final entry in flows.entries)
          if (entry.value.isProposed) entry.key,
      ];

  /// The application these flows drive.
  ///
  /// The first one declared. Every flow in a suite launches the same
  /// application in practice, and checking one that is not under test
  /// would be worse than checking none.
  String? _appId(Map<String, TestFlow> flows) =>
      flows.isEmpty ? null : flows.values.first.appId;

  /// Whether any screen is described twice.
  ///
  /// Asked through the same loaders `run` and `suite run` use, so the
  /// two cannot drift into disagreeing about what a duplicate is. The
  /// detection is theirs; this only reports it. Both calls are directory
  /// reads: nothing is launched, no port is bound, no design is fetched.
  ///
  /// The message is composed here rather than taken from the
  /// exception's own `toString()`, which is three lines - the report
  /// puts one detail on one column-aligned line. The screen and both
  /// file names survive, which is what a reader needs to find them.
  ///
  /// The mappings come back with the check because the figma
  /// prerequisites below need them and this is the one place that reads
  /// them. Null when the load failed, which is also when this check is
  /// blocking: nothing can say what a project configures until its
  /// configuration parses, so nothing downstream should guess.
  Future<(PreflightCheck, Map<String, MappingsFile>?)>
      _screenConfiguration() async {
    String? duplicate;
    String? unreadable;
    Map<String, MappingsFile>? mappings;
    // R16: the designs the loader skipped. `run` and `suite run` have
    // always printed these; preflight read the same directory and threw
    // the report away, so its row said "one configuration per screen"
    // about a directory holding a file nobody could read.
    final skipped = <String>[];
    try {
      mappings = await loadMappings(projectDirectory);
      await loadFigmaSpecs(
        projectDirectory,
        onProblem: (problem) => skipped.add(skippedDesignMessage(problem)),
      );
    } on DuplicateScreenException catch (error) {
      duplicate = duplicateScreenMessage(error);
    } on MappingsFormatException catch (error) {
      // Swallowed until now, on the grounds that reporting it would
      // widen preflight past the gap P-1 existed to close. What that
      // left behind was not silence but an affirmative: `[ok] one
      // configuration per screen`, about a file the loader could not
      // read, while `run` exited 1 and `suite run` exited 2 on it.
      //
      // A design spec that will not read stays advisory and is not
      // here: `loadFigmaSpecs` reports and skips one, because a file
      // describing no screen takes nothing away from another. A mapping
      // is fatal to a run, which is the whole difference.
      unreadable = unreadableMappingMessage(error);
    }

    return (
      checkScreenConfiguration(
        duplicate: duplicate,
        unreadable: unreadable,
        skipped: skipped,
      ),
      mappings,
    );
  }

  /// What a reachable declared design needs, and has not got.
  ///
  /// The screen a `validateScreen` compares is whichever one the
  /// application is on, which a file cannot say in general - so the
  /// nearest preceding `expectScreen` names it, exactly as
  /// [_missingBaselines] does for a photograph. Where there is none,
  /// nothing is reported: this walk decides whether to *refuse* a suite,
  /// and a refusal invented from a guess is worse than the late failure
  /// it would have replaced.
  ///
  /// Scoped to the suite rather than the project on purpose.
  /// `resolveFigmaSources` walks every mapping there is, which is right
  /// for it - it resolves what it can and reports each failure - and
  /// wrong here, where the answer stops a run. A design declared on a
  /// screen no test in this suite reaches is not a prerequisite of it.
  ///
  /// Local questions only: is the token *present*, and does the node
  /// mapping *exist*. Whether the token works needs a request, and
  /// whether the mapping parses is a file the run reads for itself.
  ({List<String> required, List<String> optional, int reachable})
      _figmaPrerequisites(
    Map<String, TestFlow> flows,
    Map<String, MappingsFile> mappings,
  ) {
    final required = <String>[];
    final optional = <String>[];
    final reachable = <String>{};
    final seen = <String>{};

    for (final entry in flows.entries) {
      String? screen;
      for (final step in entry.value.steps) {
        if (step is ExpectScreenStep) {
          screen = step.screenId;
          continue;
        }
        if (step is! ValidateScreenStep || !step.runsFigma) continue;
        if (screen == null) continue;

        final source = mappings[screen]?.figmaSource;
        if (source == null) continue;

        reachable.add(screen);
        final record = '${entry.key} -> $screen';
        if (!seen.add(record)) continue;

        final problems = <String>[
          if (!secrets.isPresent(source.token))
            '${source.token.name} is not set',
          if (!File('${projectDirectory.path}/${source.mappingPath}')
              .existsSync())
            '${source.mappingPath} does not exist',
        ];
        if (problems.isEmpty) continue;

        (_isRequired(entry.key) ? required : optional)
            .add('$record: ${problems.join(' and ')}');
      }
    }

    return (
      required: required,
      optional: optional,
      reachable: reachable.length,
    );
  }

  /// Whether the suite's verdict depends on this test.
  ///
  /// `optional:` is the suite's own word for a test whose result does
  /// not count, and `SuiteResult.verdict` honours it. A check that
  /// blocked over one would refuse a run that would have passed.
  bool _isRequired(String testId) =>
      suite.tests.any((test) => test.id == testId && test.required);

  Future<PreflightCheck> _mockApi(Map<String, TestFlow> flows) async {
    final port = suite.mockApiPort;
    if (port == null) {
      // Both halves of the relationship are already here - what each
      // flow declares, and what the suite provides - and the answer was
      // still "this suite declares no mock API", about a suite whose
      // flows declare one. Split by whether the suite requires the
      // test, which is the only thing that decides whether the run can
      // still pass.
      final unserved = [
        for (final entry in flows.entries)
          if (entry.value.fixture != null)
            (id: entry.key, named: '${entry.key} -> ${entry.value.fixture}'),
      ];

      return checkMockApi(
        port: null,
        portFree: true,
        scenarioProblem: null,
        unresolvableFixtures: const [],
        fixturesWithoutServer: [
          for (final test in unserved)
            if (_isRequired(test.id)) test.named,
        ],
        optionalFixturesWithoutServer: [
          for (final test in unserved)
            if (!_isRequired(test.id)) test.named,
        ],
      );
    }

    final free = await portProbe(port);

    String? problem;
    final unresolvable = <String>[];
    try {
      final library = ScenarioLibrary.load(
        Directory('${projectDirectory.path}/mock_api/scenarios'),
      );
      // The suite starts on the default state, so a suite whose default
      // does not resolve cannot start at all.
      library.resolve(ScenarioLibrary.defaultName);

      for (final entry in flows.entries) {
        final fixture = entry.value.fixture;
        if (fixture == null) continue;
        try {
          library.resolve(fixture);
        } on ScenarioFormatException {
          unresolvable.add('${entry.key} -> $fixture');
        }
      }
    } on ScenarioFormatException catch (error) {
      problem = scenarioProblemMessage(error);
    }

    return checkMockApi(
      port: port,
      portFree: free,
      scenarioProblem: problem,
      unresolvableFixtures: unresolvable,
    );
  }

  /// Screens a flow will photograph that have no baseline yet.
  ///
  /// The screen a `validateScreen` photographs is whichever one the
  /// application is on, which a file cannot say in general - but a flow
  /// that photographs a screen has almost always just asserted it is on
  /// it, so the nearest preceding `expectScreen` names it. Where there is
  /// none, nothing is reported: a notice invented from a guess is noise,
  /// and this check exists to be helpful rather than to be complete.
  ///
  /// Only an explicit `visual: true` counts. Automatic mode photographs
  /// only when a baseline already exists, so it can never be missing one.
  List<String> _missingBaselines(Map<String, TestFlow> flows) {
    final missing = <String>[];
    final directory = Directory('${projectDirectory.path}/visual_baselines');

    for (final entry in flows.entries) {
      final flow = entry.value;
      final store = BaselineStore(
        directory,
        variant: flow.fixture,
        profile: profile,
      );

      String? screen;
      for (final step in flow.steps) {
        if (step is ExpectScreenStep) {
          screen = step.screenId;
          continue;
        }
        if (step is! ValidateScreenStep || step.visual != true) continue;
        if (screen == null) continue;

        final present = store
            .candidatePaths(screen)
            .any((path) => File('$path.png').existsSync());
        final record = '${entry.key} -> $screen';
        if (!present && !missing.contains(record)) missing.add(record);
      }
    }
    return missing;
  }
}
