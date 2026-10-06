import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../adb_device_environment.dart';
import '../app_session.dart';
import '../auth_preflight.dart';
import '../auth_runner.dart';
import '../dotenv.dart';
import '../flow_executor.dart';
import '../secrets/env_secret_resolver.dart';
import '../output.dart';
import '../output_path.dart';
import '../project_config.dart';
import '../project_root.dart';
import '../suite_runner.dart';
import 'preflight_command.dart';

/// Adapts a launched application onto what [AuthRunner] needs.
///
/// Thin on purpose: every decision lives in [AuthRunner], which is
/// unit-tested against a scripted driver, and everything here is wiring
/// that only a handset can exercise.
class SessionAuthDriver implements AuthDriver {
  SessionAuthDriver(this.session);

  final AppSession session;

  @override
  Future<String?> currentRoute() async => session.manager.currentScreenId;

  @override
  List<String> routeHistory() => session.manager.screenHistory;

  @override
  Future<void> tap(String elementId) => session.tapById(elementId);

  @override
  Future<void> inputSecret(String elementId, Secret secret) async {
    // The same focus-then-verify path the product runner uses, so a
    // credential cannot arrive truncated where a plaintext value would
    // not have. The value reaches the device and nothing else: the
    // command string a failure would render is the redaction marker,
    // and the delivery check compares lengths, never contents.
    await session.enterSecretById(elementId, secret);
  }

  @override
  Future<void> waitForSettle(Duration timeout, QuiescencePolicy policy) async {
    // The declared animations stop blocking and nothing else does: an
    // animation nobody named still holds the screen, which is what keeps
    // this a check rather than a switch.
    await session.waitForSettle(timeout: timeout, policy: () => policy);
  }

  @override
  Future<void> awaitRoute(String route, Duration timeout) =>
      // The same wait `testsmith run` performs, from the same function, so
      // the two cannot drift: a screen that never arrived is the finding
      // in both, and it was already written twice.
      //
      // The capture is no new exposure on an authentication screen -
      // delivery verification already pulls the tree on every
      // `inputSecret` - and only the route name and the number of routes
      // built are read from it. Nothing of the tree reaches a report.
      awaitScreenEvidence(
        screenId: route,
        timeout: timeout,
        routerRoute: () => session.manager.currentScreenId,
        screensVisited: () => session.manager.screenHistory,
        capture: session.captureUiTree,
        liveness: () => session.transport.liveness,
        protocol: () => session.transport.protocol,
      );


  @override
  Future<bool> awaitElement(String elementId, Duration timeout) async {
    try {
      // The same waiter the platform already uses to find elements, with
      // its presence-only entry point.
      return await ElementWaiter(timeout: timeout)
          .awaitPresent(elementId, session.captureUiTree);
    } on Object catch (error) {
      // "Absent" is a conservative answer about an element. It is not an
      // answer at all when the engine has stopped being able to look:
      // reported as absent, a lost connection became "the app reached
      // the route and never rendered it", which is a claim about the
      // application nobody measured.
      if (isInfrastructureFailure(error)) rethrow;
      return false;
    }
  }

  @override
  Future<bool> hasElement(String elementId) async {
    try {
      return ElementLocator(await session.captureUiTree()).contains(elementId);
    } on Object catch (error) {
      if (isInfrastructureFailure(error)) rethrow;
      // A tree that could not be captured has said nothing about the
      // element. Reported as absent, which is the conservative
      // direction: it can fail a verification, never pass one.
      return false;
    }
  }

  @override
  Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step) async {
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
    return outcome;
  }

  /// What the application says it is.
  ///
  /// Read over `ext.mytest.sessionInfo` rather than from the handshake,
  /// because the handshake's `AppContext` carries a version and a build
  /// mode and no identity. Unreadable is null, never a guess: a runner
  /// that could not read something has learned nothing about it.
  @override
  Future<({String? appId, String? version, String? buildMode})>
      identity() async {
    try {
      final info = await session.transport.invoke('ext.mytest.sessionInfo');
      final app = info['app'];
      final context = app is Map
          ? AppContext.fromJson(app.cast<String, Object?>())
          : null;
      return (
        appId: info['appId'] as String?,
        version: context?.appVersion,
        buildMode: context?.buildMode.wire,
      );
    } on Object catch (error) {
      // An application that declares no identity has told the runner
      // nothing, and null says so. An application the runner could not
      // reach has also told it nothing - but reported as null it becomes
      // "the app reports null and this auth file declares X", which is
      // ENVIRONMENT_PREREQUISITE: a claim that the wrong application
      // answered, made about one that did not answer at all.
      if (isInfrastructureFailure(error)) rethrow;
      return (appId: null, version: null, buildMode: null);
    }
  }

  @override
  Future<void> dispose() => session.dispose();
}

/// `testsmith auth` - establish an authenticated application state.
class AuthCommand extends Command<int> {
  AuthCommand() {
    addSubcommand(AuthSetupSubcommand());
  }

  @override
  String get name => 'auth';

  @override
  String get description =>
      'Establish an authenticated application state through the real login UI.';
}

class AuthSetupSubcommand extends Command<int> {
  AuthSetupSubcommand() {
    argParser
      ..addOption('device', abbr: 'd', help: 'Device serial.')
      ..addOption(
        'out',
        help: 'Where to write auth.json. Relative to the application the '
            'auth file names; an absolute path is taken as written.',
      );
  }

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Sign in on the device by driving the real login UI, and verify it.';

  @override
  String get invocation => 'testsmith auth setup <auth.yaml>';

  static const int _usage = 64;

  /// Everything that is not success. Auth setup judges no screen, so it
  /// is never in a position to return 1.
  static const int _error = 2;

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    if (args.rest.length != 1) {
      output
        ..line(output.red('Expected exactly one auth file.'))
        ..line(output.dim('Usage: $invocation'));
      return _usage;
    }

    final authFile = File(args.rest.single);
    if (!authFile.existsSync()) {
      output.line(output.red('No such auth file: ${authFile.path}'));
      return _error;
    }

    final AuthFile file;
    try {
      file =
          AuthFile.parse(await authFile.readAsString(), source: authFile.path);
    } on AuthFormatException catch (error) {
      output.line(output.red('$error'));
      return _error;
    } on SecretRefFormatException catch (error) {
      output.line(output.red('$error'));
      return _error;
    } on FileSystemException catch (error) {
      // The other way this read fails: `readAsString` reports a file it
      // cannot decode this way, and nothing above caught it. Rendered as
      // the `AuthFormatException` an unparseable file already is, which
      // names the file once; the message is dart:io's and carries none
      // of the file's contents.
      output.line(
        output.red('${AuthFormatException(authFile.path, error.message)}'),
      );
      return _error;
    }

    // Resolved the same way a suite resolves its own: relative to the file
    // that declared it, and taken as written when it is absolute. Checked
    // here so a wrong root says so, rather than surfacing later as a
    // device profile that is somehow missing.
    final appRoot = resolveDeclaredProjectRoot(
      declaringFile: authFile,
      declaredPath: file.app.path,
    );
    if (!appRoot.isFound) {
      output
        ..line(output.red(appRoot.problem!))
        ..line(output.dim('  ${appRoot.hint}'));
      return _error;
    }
    final project = appRoot.directory!;

    // S8: `--out` names a place in the application the auth file points
    // at, not in whatever directory `testsmith` was launched from. Left
    // null when it was not given, which still means "write nothing".
    final requestedOut = args.option('out');
    final outputDirectory = requestedOut == null
        ? null
        : resolveOutputDirectory(project, requestedOut);
    // auth.json is written on every outcome, so an --out it can never go
    // into is refused now, before the device is asked anything.
    final outputProblem = outputDirectory == null
        ? null
        : outputDirectoryProblem(outputDirectory);
    if (outputProblem != null) {
      output
        ..line(output.red('--out cannot be used: $outputProblem'))
        ..line(output.dim(
          '  Name a directory, or remove what is in the way.',
        ));
      return _error;
    }

    // 1a. Every secret is *there*, before anything is built. A bool, and
    // never the value: a presence check must not pull a credential into
    // the process, and a typo in a variable name should cost a second
    // rather than a build.
    final DotEnv dotenv;
    try {
      dotenv = DotEnv.load([project.path, Directory.current.path]);
    } on FormatException catch (error) {
      // A `.env` that is there and cannot be decoded. Reported as itself,
      // not as the credentials below being unset - it may be exactly
      // where they are. Names the file, never what is in it.
      output.line(output.red('$error'));
      return _error;
    }
    final resolver = EnvSecretResolver(dotenv: dotenv);
    final missing = [
      for (final ref in file.declaredSecrets)
        if (!resolver.isPresent(ref)) ref,
    ];
    if (missing.isNotEmpty) {
      output
        ..line(output.red(
          'Missing credential${missing.length == 1 ? '' : 's'}:',
        ))
        ..line(output.dim(
          [for (final ref in missing) '  $ref is not set'].join('\n'),
        ))
        ..line(output.dim(
          '  Set them in the environment, or in a .env file that is not '
          'committed. The value is never read until the moment it is typed.',
        ));
      return _error;
    }

    // 1b. The device profile, and a device.
    final DeviceProfile? profile;
    try {
      profile = await loadDeviceProfile(project, file.deviceProfile);
    } on ProfileFormatException catch (error) {
      // The guard `preflight` already has. A profile that is present but
      // malformed is not "no such profile", so it is reported as itself
      // rather than through the list below.
      output.line(output.red('$error'));
      return _error;
    }
    if (profile == null) {
      final available = availableProfiles(project);
      output
        ..line(output.red('No device profile "${file.deviceProfile}".'))
        ..line(output.dim(
          '  Looked in ${project.path}/device_profiles. Available: '
          '${available.isEmpty ? '(none)' : available.join(', ')}',
        ));
      return _error;
    }

    final probe = await attachedDevices();
    final attached = probe.devices;
    final serial = args.option('device') ??
        (attached.length == 1 ? attached.single.serial : null);
    if (serial == null) {
      // A tool that never ran said nothing about any device, so neither
      // sentence below would be true.
      if (probe.problem != null) {
        output
          ..line(output.red(probe.problem!))
          ..line(output.dim('  ${probe.remedy}'));
        return _error;
      }
      output.line(output.red(
        attached.isEmpty
            ? 'No usable device attached. Run: testsmith devices'
            : 'Several devices attached; choose one with --device.',
      ));
      return _error;
    }
    final facts = await readDeviceFacts(serial, attached);

    // 2. Arrange, then verify - E-04's ordering, and gated on the device
    // being the profile's, so no unrelated handset is modified.
    final deviceOk = checkDeviceAttached(
      attached: attached,
      requested: serial,
      adbProblem: probe.problem,
      adbRemedy: probe.remedy,
    );
    final profileOk = checkProfileMatch(profile: profile, facts: facts);
    if (file.devicePermissions.isNotEmpty &&
        !deviceOk.isBlocking &&
        !profileOk.isBlocking) {
      await grantPermissions(
        appId: file.appId,
        permissions: file.devicePermissions,
        device: AdbDeviceController(serial: serial),
        log: output.line,
      );
    }

    // 3. Preflight.
    final preflight = await AuthPreflightRunner(
      file: file,
      projectDirectory: project,
      profile: profile,
      deviceEnvironment: AdbDeviceEnvironment(serial: serial),
      attachedDevices: attached,
      requestedSerial: serial,
      deviceFacts: facts,
      adbProblem: probe.problem,
      adbRemedy: probe.remedy,
      flutterOnPath: resolveFlutter().isFound,
    ).run();
    output.renderPreflight(preflight);

    if (preflight.isBlocked) {
      return _finish(
        AuthSetupResult(
          outcome: AuthSetupOutcome.failed,
          failure: AuthSetupFailure.environmentPrerequisite,
          detail: preflight.blockers.map((c) => c.name).join(', '),
          remedy: AuthSetupFailure.environmentPrerequisite.remedy,
          loginPerformed: false,
          secretsUsed: file.declaredSecrets,
          deviceModel: facts.model,
        ),
        outputDirectory,
        output,
      );
    }

    // 4. Launch the declared build. No reverse port and no fixture
    // server: this build talks to the real backend.
    final AppSession session;
    try {
      session = await AppSession.launch(
        projectDirectory: project,
        deviceSerial: serial,
        appId: file.appId,
        log: output.line,
        target: file.app.target,
        flavor: file.app.flavor,
        dartDefines: file.app.dartDefines,
      );
    } catch (error) {
      output.line(output.red('Could not launch the application: $error'));

      // "The application did not start" is right for a build that failed
      // or a device that refused it, and wrong for an application that
      // started and then could not be reached - the attach timing out is
      // the engine failing to observe, not the app failing to run. The
      // cause is carried into the artefact either way; it used to reach
      // only the console, so the recorded detail named a cause nobody
      // had established.
      final infrastructure = isInfrastructureFailure(error);
      final failure = infrastructure
          ? AuthSetupFailure.observationFailed
          : AuthSetupFailure.environmentPrerequisite;

      return _finish(
        AuthSetupResult(
          outcome: AuthSetupOutcome.failed,
          failure: failure,
          detail: infrastructure
              ? '$error'
              : 'the application did not start: $error',
          remedy: failure.remedy,
          loginPerformed: false,
          secretsUsed: file.declaredSecrets,
          deviceModel: facts.model,
        ),
        outputDirectory,
        output,
      );
    }

    // 5-7. Observe, verify, tear down.
    final result = await AuthRunner(
      file: file,
      secrets: resolver,
      driver: SessionAuthDriver(session),
      log: output.line,
      deviceModel: facts.model,
    ).run();

    return _finish(result, outputDirectory, output);
  }

  Future<int> _finish(
    AuthSetupResult result,
    Directory? directory,
    Output output,
  ) async {
    output.line();
    if (result.succeeded) {
      output.line(output.green(
        result.loginPerformed
            ? 'AUTHENTICATED  signed in through the real login UI, and '
                'reached "${result.route}"'
            : 'AUTHENTICATED  already signed in; "${result.route}" verified '
                'without using a credential',
      ));
    } else {
      output.line(output.red('NOT AUTHENTICATED  ${result.failure!.wire}'));
      if (result.detail.isNotEmpty) {
        output.line(output.dim('  ${result.detail}'));
      }
      output.line(output.dim('  -> ${result.remedy}'));
    }

    // Written on every outcome, including a blocked one, because CI
    // wants an answer either way and "we could not authenticate" is an
    // answer.
    //
    // A write that fails is said, and is 2 whatever the outcome: the
    // answer CI asked for is not there to read. Unguarded, it ended at
    // 255 with a stack trace after the verdict above had been printed.
    if (directory != null) {
      final file = File('${directory.path}/auth.json');
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(result.toJson()),
        );
      } on FileSystemException catch (error) {
        output
          ..line(output.red('  auth.json could not be written:'))
          ..line(output.dim('  ${describeWriteFailure(error)}'));
        return _error;
      }
      output.line(output.dim('  wrote ${file.path}'));
    }

    return result.exitCode;
  }
}
