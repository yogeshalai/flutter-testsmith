import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith/engine.dart';

import '../adb_device_environment.dart';
import '../device_selection.dart';
import '../dotenv.dart';
import '../output.dart';
import '../preflight_runner.dart';
import '../project_config.dart';
import '../project_root.dart';
import '../secrets/env_secret_resolver.dart';
import '../suite_runner.dart';

/// A suite that could not be set up at all.
///
/// The same code an unevaluable required test produces, because it is the
/// same news: the run did not answer the question.
const int environmentExitCode = 2;

/// Everything both `testsmith preflight` and `testsmith suite run` must resolve
/// before either can do its job.
///
/// One function, so the two cannot drift into checking different things -
/// the same reason [FlowRunner] exists. Each failure prints and returns
/// null, so a caller's only decision is whether it got a context.
class SuiteContext {
  const SuiteContext({
    required this.suite,
    required this.project,
    required this.profile,
    required this.serial,
    required this.attached,
    required this.facts,
    this.adbProblem,
    this.adbRemedy = '',
  });

  final SuiteFile suite;

  /// The application root. Flows, mappings, designs, profiles and
  /// baselines are all resolved against it.
  final Directory project;

  final DeviceProfile profile;

  /// The device to drive. An address, not an identity: it reaches a
  /// handset and is never written into a report.
  ///
  /// Null when none could be chosen - nothing attached, several attached
  /// and none named, or an adb that would not answer. Carried rather
  /// than refused, so [checkDeviceAttached] reports the condition and
  /// the run leaves a result behind saying why it could not test
  /// anything. Null therefore always produces a blocking device check,
  /// which is what keeps every consumer below it unreachable.
  final String? serial;

  /// Every usable device adb can see, for the preflight check that has to
  /// say what *is* there.
  final List<AdbDevice> attached;

  /// What adb said about the chosen device. Empty when it could not be
  /// read, which is not the same as a disagreement.
  final DeviceFacts facts;

  /// Why the device list could not be obtained, or null when it was.
  ///
  /// Carried rather than collapsed into an empty [attached]: "adb would
  /// not run" and "adb ran and there is nothing plugged in" are different
  /// sentences with different remedies, and only one of them is about a
  /// device.
  final String? adbProblem;

  /// What to do about [adbProblem]. The resolver's own hint where it has
  /// one, because that is the part naming the variable that is wrong.
  final String adbRemedy;
}

/// Resolves a suite file into everything a run needs, or explains why not.
///
/// Stages, in the order E-03 established, each of which can end the run
/// before the next begins: suite syntax, then every flow it names, then
/// the device profile, then a device. Nothing is built or launched here,
/// because there is no point compiling an application to discover a path
/// typo.
Future<SuiteContext?> resolveSuiteContext({
  required File suiteFile,
  required String? requestedSerial,
  required Output output,
}) async {
  if (!suiteFile.existsSync()) {
    output.line(output.red('No such suite file: ${suiteFile.path}'));
    return null;
  }

  final SuiteFile suite;
  try {
    suite = SuiteFile.parse(
      await suiteFile.readAsString(),
      source: suiteFile.path,
    );
  } on SuiteFormatException catch (error) {
    output.line(output.red('$error'));
    return null;
  } on FileSystemException catch (error) {
    // The other way the read above fails, and the last of the four
    // readers these two commands share. `readAsString` decodes as well
    // as reads and reports a failure to decode as a
    // `FileSystemException` - not the exception in the clause above,
    // and caught nowhere over this function - so a suite saved in an
    // encoding this cannot read ended `preflight` and `suite run` at
    // 255.
    //
    // Restated into the same contract rather than given a second one:
    // the same sentence, the same `null`, and the same exit code from
    // both callers. `loadMappings` and `loadDeviceProfile` restate for
    // *their* callers; this one catches its own exception, so it says
    // it here. Built rather than written out so the wording stays in
    // one place.
    output.line(
      output.red('${SuiteFormatException(suiteFile.path, error.message)}'),
    );
    return null;
  }

  // Before the flows, because a root that is not there makes every one of
  // them look missing. That was the only symptom an absolute `app: path:`
  // ever produced: a list blaming the suite for a directory it had named
  // correctly.
  final root = resolveDeclaredProjectRoot(
    declaringFile: suiteFile,
    declaredPath: suite.app.path,
  );
  if (!root.isFound) {
    output
      ..line(output.red(root.problem!))
      ..line(output.dim('  ${root.hint}'));
    return null;
  }
  final project = root.directory!;

  final missing = suite.missingFlows(project);
  if (missing.isNotEmpty) {
    output.line(output.red('The suite names flows that are not there:'));
    for (final problem in missing) {
      output.line('  $problem');
    }
    return null;
  }

  final DeviceProfile? profile;
  try {
    profile = await loadDeviceProfile(project, suite.deviceProfile);
  } on ProfileFormatException catch (error) {
    output.line(output.red('$error'));
    return null;
  }
  if (profile == null) {
    final available = availableProfiles(project);
    output
      ..line(output.red('No device profile "${suite.deviceProfile}".'))
      ..line(output.dim(
        '  Looked in ${project.path}/device_profiles. '
        'Available: ${available.isEmpty ? '(none)' : available.join(', ')}',
      ));
    return null;
  }

  final probe = await attachedDevices();
  final attached = probe.devices;

  // A serial is needed to address the device even when preflight is about
  // to report that it is not there: the report is more useful than a
  // refusal, and checkDeviceAttached is what says so.
  final serial = requestedSerial ??
      (attached.length == 1 ? attached.single.serial : null);

  // Not a refusal, for the reason stated directly above: the report is
  // more useful, and `checkDeviceAttached` is what says so. That was
  // applied only when a serial had been named, so `-d no-such-device`
  // produced the whole report and a `suite.json` a gate could read,
  // while naming nothing produced one line and no result at all - the
  // same physical situation, and the more specific invocation got the
  // better answer. A gate reading the output directory could not tell
  // "nothing ran because there is no device" from "nothing ran".
  //
  // The serials are still listed, because that is the one part the
  // check does not carry: it reports how many are attached, not which.
  // Its detail and remedy already say everything the other two
  // sentences here said, so they are left to it.
  if (serial == null && probe.problem == null && attached.isNotEmpty) {
    output.line(output.dim(
      [for (final device in attached) '  ${device.serial}  ${device.model}']
          .join('\n'),
    ));
  }

  return SuiteContext(
    suite: suite,
    project: project,
    profile: profile,
    serial: serial,
    attached: attached,
    facts: await readDeviceFacts(serial, attached),
    adbProblem: probe.problem,
    adbRemedy: probe.remedy,
  );
}

/// Every usable device adb can see, and why it could not be asked.
///
/// `problem` is null exactly when adb answered. An empty `devices` with a
/// null `problem` is adb saying "nothing is plugged in", which is a
/// successful query and keeps every word of the wording it always had.
///
/// It used to be a bare list, and three different failures - adb not
/// resolvable, adb not launchable, adb exiting non-zero - all became the
/// same empty list as that answer. Preflight then reported a machine with
/// no adb as a machine with no device, and sent people to plug in a
/// handset that was already plugged in. `device_selection.dart` has drawn
/// this distinction since 04d3696; `preflight` and `suite run` never
/// adopted it because they were not among the commands that crashed.
///
/// The resolution is inspected rather than flattened through
/// `executableOrBareName`: an adb that could not be located has not been
/// located, and running whatever the operating system finds instead is
/// how "MYTEST_ADB is wrong" became "there is no device".
Future<({List<AdbDevice> devices, String? problem, String remedy})>
    attachedDevices() async {
  const fallbackRemedy =
      'Install the Android platform-tools and put adb on PATH, set '
      'ANDROID_HOME to the SDK, or set MYTEST_ADB to the executable.';

  final located = resolveAdb();
  if (!located.isFound) {
    return (
      devices: const <AdbDevice>[],
      problem: located.problem!,
      remedy: located.hint.isEmpty ? fallbackRemedy : located.hint,
    );
  }

  final where = '${located.source!.label}: ${located.executable}';
  final ProcessResultData result;
  try {
    result = await const SystemProcessRunner(
      timeout: AdbDeviceController.commandTimeout,
    ).run(located.executable!, const ['devices', '-l']);
  } on ProcessTimeoutException catch (error) {
    return (
      devices: const <AdbDevice>[],
      problem: 'adb at $where did not answer within '
          '${error.timeout.inSeconds} seconds',
      remedy: adbUnresponsiveHint.trim(),
    );
  } on ProcessException catch (error) {
    // Located and unusable is its own answer, and the phrasing `doctor`
    // already uses for it: the file is exactly where it was configured
    // to be, and will not run.
    return (
      devices: const <AdbDevice>[],
      problem: 'adb is at $where, but it would not run: ${error.message}',
      remedy: fallbackRemedy,
    );
  }

  if (!result.succeeded) {
    return (
      devices: const <AdbDevice>[],
      problem: 'adb at $where exited with ${result.exitCode}',
      remedy: fallbackRemedy,
    );
  }

  return (
    devices: parseAdbDevices(result.stdout),
    problem: null,
    remedy: '',
  );
}

/// What adb says about [serial], for the static half of profile checking.
///
/// Empty when the device is not there or would not answer. An unreported
/// fact is not a mismatch, so an empty reading blocks nothing by itself -
/// the device check has already said what it needs to.
///
/// A null [serial] - no device was chosen at all - is the same answer
/// through the same guard below: nothing can be read from a handset
/// nobody is addressing.
Future<DeviceFacts> readDeviceFacts(
  String? serial,
  List<AdbDevice> attached,
) async {
  if (!attached.any((device) => device.serial == serial)) {
    return const DeviceFacts();
  }
  try {
    // Not null: the guard above passed, so this serial is one adb just
    // reported, and a null never matches a device it listed.
    final info = await AdbDeviceController(serial: serial!).info();
    return DeviceFacts(
      model: info.model,
      os: 'Android ${info.androidVersion}',
      physicalWidth: info.screenWidth,
      physicalHeight: info.screenHeight,
    );
  } on Object {
    return const DeviceFacts();
  }
}

/// Arranges what the suite declares, before anything checks it.
///
/// Setup, then verification. A suite declares `device.permissions`
/// precisely so the runner will grant them, so a preflight that read the
/// device first would block every fresh run on a state the very next step
/// was about to establish - measured on hardware, where the four
/// signed-in tests were refused over two permissions the suite itself was
/// about to grant.
///
/// Gated on the device being the one the profile names. Granting a
/// permission to the wrong handset is a change nobody asked for, and the
/// device and profile checks are cheap and already pure.
///
/// Done by `testsmith preflight` too, and deliberately: the question it
/// answers is "can this suite run?", and what the suite arranges for
/// itself is part of the answer. Two commands that arranged differently
/// would give different answers to the same question.
Future<void> arrangeDeclaredPermissions(
  SuiteContext context,
  Output output,
) async {
  if (context.suite.devicePermissions.isEmpty) return;

  final device = checkDeviceAttached(
    attached: context.attached,
    requested: context.serial,
    adbProblem: context.adbProblem,
    adbRemedy: context.adbRemedy,
  );
  final profile = checkProfileMatch(
    profile: context.profile,
    facts: context.facts,
  );
  if (device.isBlocking || profile.isBlocking) return;

  await grantDeclaredPermissions(
    suite: context.suite,
    projectDirectory: context.project,
    // Not null: a context with no serial always blocks the check above.
    device: AdbDeviceController(serial: context.serial!),
    log: output.line,
  );
}

/// Builds the preflight report for a resolved suite.
///
/// Shared so `testsmith preflight` and `testsmith suite run` ask exactly the
/// same questions.
Future<PreflightReport> runPreflight(SuiteContext context) async {
  // The resolver every other command builds: the process environment
  // first, then a `.env` beside the application, then one beside the
  // caller. Built here so `testsmith preflight` and `suite run` ask the
  // same question of the same sources - a token preflight said was
  // missing and the run then found would be worse than not asking.
  final DotEnv dotenv;
  try {
    dotenv = DotEnv.load([context.project.path, Directory.current.path]);
  } on FormatException catch (error) {
    // A `.env` that is there and cannot be decoded. Not skipped - it may
    // hold the very credential a check below would then call missing -
    // so it is the one finding, the way `suite run` reports a blocker
    // found before preflight: a report, so `suite run` still writes its
    // result, and exit 2. The message names the file and nothing in it.
    return PreflightReport([
      PreflightCheck.blocked(
        'credentials',
        klass: PrerequisiteClass.runnerControlled,
        detail: error.message,
        remedy: 'Save the file as UTF-8. Nothing else can be checked '
            'until it can be read, because it may hold a credential this '
            'suite needs.',
      ),
    ]);
  }

  return PreflightRunner(
    suite: context.suite,
    projectDirectory: context.project,
    profile: context.profile,
    // Addressed only once the device check is satisfied, which a
    // context with no serial can never be - so the empty address
    // below is never the one anything is asked at.
    deviceEnvironment: AdbDeviceEnvironment(serial: context.serial ?? ''),
    attachedDevices: context.attached,
    requestedSerial: context.serial,
    deviceFacts: context.facts,
    portProbe: hostPortIsFree,
    flutterOnPath: resolveFlutter().isFound,
    adbProblem: context.adbProblem,
    adbRemedy: context.adbRemedy,
    secrets: EnvSecretResolver(dotenv: dotenv),
  ).run();
}

/// `testsmith preflight` - say whether this environment could test anything.
///
/// Separate from `suite run` so CI can gate on the environment without
/// paying for a suite, and so a person can ask "is this machine ready?"
/// and get an answer in a second rather than in eight minutes of launch
/// timeout.
class PreflightCommand extends Command<int> {
  PreflightCommand() {
    argParser.addOption('device', abbr: 'd', help: 'Device serial.');
  }

  @override
  String get name => 'preflight';

  @override
  String get description =>
      'Check that this environment can run a suite, before it runs one.';

  @override
  String get invocation => 'testsmith preflight <suite.yaml>';

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    if (args.rest.length != 1) {
      output
        ..line(output.red('Expected exactly one suite file.'))
        ..line(output.dim('Usage: $invocation'));
      return 64;
    }

    final context = await resolveSuiteContext(
      suiteFile: File(args.rest.single),
      requestedSerial: args.option('device'),
      output: output,
    );
    if (context == null) return environmentExitCode;

    await arrangeDeclaredPermissions(context, output);
    final report = await runPreflight(context);
    output.renderPreflight(report);

    return report.exitCode;
  }
}
