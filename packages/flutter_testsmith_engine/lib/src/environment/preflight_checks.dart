import '../config/doctor.dart';
import '../device/device_profile.dart';
import 'preflight.dart';
import 'prerequisite.dart';

/// Whether the handset has a network interface at all.
///
/// Deliberately *not* whether a backend is reachable. The application
/// under test watches `connectivity_plus`, which reads the platform's
/// active default network; no fixture server can answer that signal, and
/// nothing about it implies anything about a backend. Keeping the two
/// apart is what lets the platform say NETWORK_INTERFACE_REQUIRED
/// without saying BACKEND_ACCESS_REQUIRED.
///
/// [unknown] exists because a probe that failed has learned nothing,
/// which is not the same as learning that the interface is down.
enum NetworkInterfaceState { up, down, unknown }

/// A device is attached, usable, and unambiguous.
///
/// The serial is an address, not an identity: it is used to reach a
/// handset and never recorded, here or anywhere else a report can see.
///
/// [adbProblem] is set when the device list could not be obtained at all -
/// adb was not resolvable, would not launch, or failed while listing. It
/// is reported before anything else here, and that ordering is the whole
/// point: every sentence below is a claim about what adb *said*, and a
/// tool that never ran said nothing. "No usable device is attached" sent
/// people to plug in a handset that was already plugged in, over an
/// `ANDROID_HOME` pointing at the wrong directory.
PreflightCheck checkDeviceAttached({
  required List<AdbDevice> attached,
  required String? requested,
  String? adbProblem,
  String adbRemedy = '',
}) {
  const klass = PrerequisiteClass.devicePrerequisite;
  const name = 'device';

  if (adbProblem != null) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: adbProblem,
      // The caller's hint where there is one - it names the variable
      // that is wrong - and the same fallback `testsmith devices` gives
      // where there is not.
      remedy: adbRemedy.isEmpty
          ? 'Install the Android platform-tools and put adb on PATH, set '
              'ANDROID_HOME to the SDK, or set MYTEST_ADB to the executable.'
          : adbRemedy,
    );
  }

  if (attached.isEmpty) {
    return const PreflightCheck.blocked(
      name,
      klass: klass,
      detail: 'no usable device is attached',
      remedy: 'Attach a device with USB debugging enabled, then check it is '
          'visible: testsmith devices',
    );
  }

  if (requested == null) {
    if (attached.length > 1) {
      return PreflightCheck.blocked(
        name,
        klass: klass,
        detail: '${attached.length} devices are attached',
        remedy: 'Name one with --device. Choosing for you would produce a run '
            'that appears to work while testing the wrong device.',
      );
    }
    return PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: attached.single.model,
    );
  }

  final matches = attached.where((device) => device.serial == requested);
  if (matches.isEmpty) {
    return const PreflightCheck.blocked(
      name,
      klass: klass,
      detail: 'the named device is not attached',
      remedy: 'Check the serial, or list what is there: testsmith devices',
    );
  }
  return PreflightCheck.satisfied(
    name,
    klass: klass,
    detail: matches.first.model,
  );
}

/// The attached device is the one the profile describes.
///
/// Only the half adb can answer. The pixel ratio and the build mode
/// arrive in the handshake and are checked on the first launch, exactly
/// as E-03 already does - moving them here would mean claiming to have
/// checked something nobody has yet read.
PreflightCheck checkProfileMatch({
  required DeviceProfile profile,
  required DeviceFacts facts,
}) {
  const name = 'device profile';

  // No evidence is not evidence of a match. Every comparison below is
  // skipped when the device did not report the fact, so a device that
  // reported nothing produces no mismatches and used to come back
  // satisfied - a profile declared verified against a handset nothing
  // had been read from. Deferred says what actually happened, and
  // deliberately does not block: the device check above already names
  // the cause, and an admission is not a verdict.
  if (facts.reportedNothing) {
    return PreflightCheck.deferred(
      name,
      klass: PrerequisiteClass.devicePrerequisite,
      detail: 'the device reported nothing to check ${profile.id} against',
    );
  }

  final mismatches = profile.mismatchesAgainst(facts);

  if (mismatches.isEmpty) {
    return PreflightCheck.satisfied(
      name,
      klass: PrerequisiteClass.devicePrerequisite,
      detail: profile.model == null
          ? profile.id
          : '${profile.id} (${profile.model})',
    );
  }

  return PreflightCheck.blocked(
    name,
    klass: PrerequisiteClass.devicePrerequisite,
    detail: mismatches.join('; '),
    remedy: 'A baseline recorded under one profile cannot be compared against '
        'another. Pick the right profile, or record one for this device.',
  );
}

/// The application is installed.
///
/// Blocking only when something has to touch the installed application
/// before the first launch would install it - granting a permission, or
/// clearing its state. A suite that does neither installs it on the way
/// past, and reporting "not installed" there would be true and useless.
/// [installed] is null when the device would not answer, which is a
/// deferral rather than a verdict: reported as "not installed" it sent
/// people to reinstall an application over a handset that was merely
/// offline.
PreflightCheck checkAppInstalled({
  required String appId,
  required bool? installed,
  required bool neededBeforeLaunch,
}) {
  const klass = PrerequisiteClass.runnerControlled;
  const name = 'application installed';

  if (installed == null) {
    return const PreflightCheck.deferred(
      name,
      klass: klass,
      detail: 'the device would not say; nothing was established either way',
    );
  }
  if (installed) {
    return const PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: 'present on the device',
    );
  }
  if (!neededBeforeLaunch) {
    return const PreflightCheck.notice(
      name,
      klass: klass,
      detail: 'not installed; the first launch will install it',
    );
  }
  return const PreflightCheck.blocked(
    name,
    klass: klass,
    detail: 'not installed, and this suite grants a permission or clears '
        'state before the first launch',
    remedy: 'Install it once - flutter run -t <target> --flavor <flavor> '
        '-d <serial> - then re-run.',
  );
}

/// Every permission the suite declares is granted.
///
/// [granted] is the application's runtime permission table as the device
/// reports it. A key that is *absent* means the application does not
/// declare that permission at all, which is a different problem from one
/// that is merely denied: `pm grant` fixes the second and cannot fix the
/// first, so offering it for both would be offering a remedy that does
/// not work.
/// [granted] is null when the table could not be read at all, which is a
/// deferral: every declared permission would otherwise look denied, and
/// the offered remedy would be a `pm grant` against a device that is not
/// answering.
PreflightCheck checkPermissions({
  required String appId,
  required List<String> required,
  required Map<String, bool>? granted,
}) {
  const klass = PrerequisiteClass.devicePrerequisite;
  const name = 'permissions';

  if (required.isEmpty) {
    return const PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: 'the suite declares none',
    );
  }

  if (granted == null) {
    return const PreflightCheck.deferred(
      name,
      klass: klass,
      detail: 'the device would not say what is granted',
    );
  }

  final undeclared = [
    for (final permission in required)
      if (!granted.containsKey(permission)) permission,
  ];
  if (undeclared.isNotEmpty) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: 'the application does not declare ${undeclared.join(', ')}',
      remedy: 'A permission the manifest never requests cannot be granted to '
          'it. Remove it from device.permissions, or add it to the '
          'application.',
    );
  }

  final denied = [
    for (final permission in required)
      if (granted[permission] != true) permission,
  ];
  if (denied.isNotEmpty) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: '${denied.join(', ')} denied',
      remedy: denied
          .map((permission) => 'adb shell pm grant $appId $permission')
          .join('; '),
    );
  }

  return PreflightCheck.satisfied(
    name,
    klass: klass,
    detail: '${required.length} granted',
  );
}

/// The device has an active network interface.
PreflightCheck checkNetworkInterface(NetworkInterfaceState state) {
  const klass = PrerequisiteClass.devicePrerequisite;
  const name = 'network interface';

  return switch (state) {
    NetworkInterfaceState.up => const PreflightCheck.satisfied(
        name,
        klass: klass,
        detail: 'an active default network is present',
      ),
    NetworkInterfaceState.down => const PreflightCheck.blocked(
        name,
        klass: klass,
        detail: 'NETWORK_INTERFACE_REQUIRED: the device has no active default '
            'network, and the application reads that platform signal '
            'directly rather than over HTTP',
        remedy: 'Turn on Wi-Fi or mobile data. No backend has to be '
            'reachable: test API traffic is served on loopback through adb '
            'reverse.',
      ),
    NetworkInterfaceState.unknown => const PreflightCheck.deferred(
        name,
        klass: klass,
        detail: 'the device did not say, which is not the same as saying no',
      ),
  };
}

/// The fixture server can start, and can arrange every state a flow names.
PreflightCheck checkMockApi({
  required int? port,
  required bool portFree,
  required String? scenarioProblem,
  required List<String> unresolvableFixtures,
  // Only ever non-empty when [port] is null: a suite that declares a
  // server can arrange every state, and which states resolve is the
  // question the parameters above already answer. Defaulted rather than
  // required so the four cases that cannot produce them read as they
  // always did.
  List<String> fixturesWithoutServer = const [],
  List<String> optionalFixturesWithoutServer = const [],
}) {
  const klass = PrerequisiteClass.runnerControlled;
  const name = 'mock API';

  if (port == null) {
    // "This suite declares no mock API" was said about suites whose
    // flows declare one. `testsmith run` refuses that pair before it
    // looks for a device - "a flow that names an API state is only a
    // test when that state is actually arranged" - while a suite
    // discovered it per test, after the device, the permissions and the
    // launch of everything before it.
    //
    // Blocked or noticed by whether the suite requires the test, because
    // `SuiteResult.verdict` counts only required ones: a suite whose
    // affected tests are all `optional:` can still pass, and blocking it
    // would refuse a run that would have succeeded.
    final unserved = [
      ...fixturesWithoutServer,
      ...optionalFixturesWithoutServer,
    ];
    if (fixturesWithoutServer.isNotEmpty) {
      return PreflightCheck.blocked(
        name,
        klass: klass,
        detail: 'no fixture server for ${unserved.join(', ')}',
        remedy: 'Add mockApi.port to the suite, or take the fixture off the '
            'flow. A flow that names an API state is only a test when that '
            'state is arranged.',
      );
    }
    if (optionalFixturesWithoutServer.isNotEmpty) {
      return PreflightCheck.notice(
        name,
        klass: klass,
        detail: 'no fixture server for ${unserved.join(', ')}; '
            'the suite does not require '
            '${optionalFixturesWithoutServer.length == 1 ? 'it' : 'them'}, so '
            'each will be an error of its own',
      );
    }
    return const PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: 'this suite declares no mock API',
    );
  }
  if (!portFree) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: 'port $port is in use',
      remedy: 'Stop whatever holds it, or change mockApi.port in the suite.',
    );
  }
  if (scenarioProblem != null) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: scenarioProblem,
      remedy: 'Fix the scenario file. A flow that asked for one API state and '
          'silently got another is exactly what this mechanism exists to '
          'prevent.',
    );
  }
  if (unresolvableFixtures.isNotEmpty) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: 'no scenario for ${unresolvableFixtures.join(', ')}',
      remedy: 'Add the scenario to mock_api/scenarios, or correct the flow.',
    );
  }
  return PreflightCheck.satisfied(
    name,
    klass: klass,
    detail: 'port $port, every declared API state resolves',
  );
}

/// The application can be built and launched.
PreflightCheck checkAppBuild({
  required String? target,
  required bool targetExists,
  required bool flutterOnPath,
}) {
  const klass = PrerequisiteClass.runnerControlled;
  const name = 'application build';

  if (!flutterOnPath) {
    return const PreflightCheck.blocked(
      name,
      klass: klass,
      detail: 'flutter is not on PATH',
      remedy: 'Install Flutter and add it to PATH: https://flutter.dev',
    );
  }
  if (!targetExists) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: 'the declared entry point $target is not in the project',
      remedy: 'Correct app.target in the suite, or add the entry point.',
    );
  }
  return PreflightCheck.satisfied(
    name,
    klass: klass,
    detail: target ?? 'the default entry point',
  );
}

/// A baseline exists for every screen a flow will photograph.
///
/// A **notice**, never a blocker. E-03 records a first baseline and skips
/// the comparison, and turning that into a refusal would change E-03's
/// behaviour rather than extend it.
PreflightCheck checkBaselines({required List<String> missing}) {
  const klass = PrerequisiteClass.runnerControlled;
  const name = 'baselines';

  if (missing.isEmpty) {
    return const PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: 'every photographed screen has one',
    );
  }
  return PreflightCheck.notice(
    name,
    klass: klass,
    detail: '${missing.length} without a baseline (${missing.join(', ')}); '
        'each will be recorded and its comparison skipped, as it always has '
        'been',
  );
}

/// Every flow this suite names can be read.
///
/// The suite names its flows and preflight parses them, because almost
/// every other check needs what is inside one. A flow that would not
/// parse was dropped there and never mentioned: with one good flow and
/// one broken one the report printed every row and said "nothing
/// blocking", and with no readable flow at all three device rows
/// disappeared with nothing to explain them.
///
/// `testsmith run` has always refused the same file before anything is
/// launched - "there is no point building an APK to discover a typo" -
/// and that is the reasoning this applies to a suite.
///
/// Blocked or noticed by whether the suite requires the test, because
/// `SuiteResult.verdict` counts only required ones. A suite whose broken
/// flows are all `optional:` can still pass, so blocking it would refuse
/// a run that would have succeeded - but it is reported either way,
/// which is the part that was missing.
///
/// Each entry names the test the suite gave the flow, so nothing has to
/// be guessed from a file that would not parse.
PreflightCheck checkFlowsReadable({
  required List<String> requiredTests,
  required List<String> optionalTests,
}) {
  const klass = PrerequisiteClass.runnerControlled;
  const name = 'flows';

  if (requiredTests.isEmpty && optionalTests.isEmpty) {
    return const PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: 'every flow this suite names could be read',
    );
  }

  final all = [...requiredTests, ...optionalTests];

  if (requiredTests.isEmpty) {
    return PreflightCheck.notice(
      name,
      klass: klass,
      detail: '${all.join('; ')}; the suite does not require '
          '${all.length == 1 ? 'it' : 'them'}, so each will be an error of '
          'its own',
    );
  }

  return PreflightCheck.blocked(
    name,
    klass: klass,
    detail: all.join('; '),
    remedy: 'Fix the flow. Run it on its own to see the parse error in full: '
        'testsmith run <flow>.',
  );
}

/// Every flow this suite names has been accepted by a person.
///
/// `status: proposed` is the generator's own stamp, applied by the
/// generator and never by the model, and the platform's rule for it is
/// that such a flow refuses to run until somebody has read it and taken
/// the line out. `testsmith run` has enforced that from the start.
///
/// A suite did not. `isProposed` was read by `run` and by the impact
/// index - which keeps proposals out of test selection - and nowhere
/// else, so `suite run` launched a flow a model had written and returned
/// a pass or a fail about the application from it. A verdict drawn from
/// a test nobody reviewed is the failure ADR-0009 exists to prevent, and
/// it is worse than a missing check because it looks like every other
/// verdict.
///
/// A [PrerequisiteClass.humanAction], and the first blocking one: what
/// is missing is the review itself, and a runner that supplied it would
/// be bypassing the thing the stamp establishes. Blocking regardless of
/// whether the test is `optional:` - that flag decides whether a result
/// counts towards the verdict, not whether unread generated code may
/// drive the application.
PreflightCheck checkFlowStatus({
  required List<String> proposed,
  int unread = 0,
}) {
  const klass = PrerequisiteClass.humanAction;
  const name = 'flow status';

  if (proposed.isEmpty) {
    // A flow that will not parse never reaches `isProposed`, so its
    // status is not known - and "every flow this suite names has been
    // accepted" would be an affirmative about a file nobody read. The
    // flows check is what reports the file itself.
    if (unread > 0) {
      return PreflightCheck.deferred(
        name,
        klass: klass,
        detail: '$unread flow${unread == 1 ? '' : 's'} could not be read, so '
            'whether ${unread == 1 ? 'it has' : 'they have'} been accepted is '
            'not known',
      );
    }
    return const PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: 'every flow this suite names has been accepted',
    );
  }

  final one = proposed.length == 1;

  return PreflightCheck.blocked(
    name,
    klass: klass,
    detail: '${proposed.join(', ')} ${one ? 'is' : 'are'} '
        'marked status: proposed',
    // The sentence `testsmith run` has always used for the same file, so
    // a person who has met one of these meets the same words again.
    remedy: 'Generated, and nobody has reviewed ${one ? 'it' : 'them'}. '
        '${one ? 'Read it' : 'Read each one'}, arrange whatever state it '
        'needs, then delete '
        '${one ? 'the' : 'its'} `status: proposed` line to accept it as a '
        'test.',
  );
}

/// Whether anything in this suite needs a signed-in device.
///
/// Always **deferred** when something does, and that is a finding rather
/// than a gap. Sign-in state is not knowable before the application runs.
/// The only ways to learn it earlier are to read the application's own
/// storage or to write to it: the first proves merely that something was
/// written, and the second is the bypass this platform refuses. It is
/// resolved instead by the launch every test has to perform anyway, from
/// the route the application itself chooses.
PreflightCheck checkAuthentication({required List<String> requiredBy}) {
  const klass = PrerequisiteClass.humanAction;
  const name = 'authentication';

  if (requiredBy.isEmpty) {
    return const PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: 'no test in this suite requires a session',
    );
  }
  return PreflightCheck.deferred(
    name,
    klass: klass,
    detail: 'required by ${requiredBy.join(', ')}; not observable before the '
        'application runs, so it is resolved at first launch from the route '
        'the application chooses',
  );
}

/// Every reachable declared design has what it needs to be fetched.
///
/// Locally knowable prerequisites only: the token is *present*, and the
/// node mapping *exists*. Whether the token works, and whether the
/// mapping parses, are questions this deliberately does not ask - the
/// first would make preflight issue a request, and the second is a file
/// the run reads and reports on its own.
///
/// Scoped by reachability rather than by the project. `resolveFigmaSources`
/// walks every mapping the project has, which is right for it and wrong
/// here: a design declared on a screen this suite never visits is not a
/// prerequisite of this run, and blocking on one would refuse a suite
/// that would have passed. The caller decides what is reachable; this
/// only reports what it was told.
///
/// Blocked or noticed by whether the suite requires the test, the rule
/// [checkMockApi] and [checkFlowsReadable] already hold to:
/// `SuiteResult.verdict` counts only required tests, so a suite whose
/// affected tests are all `optional:` can still pass.
PreflightCheck checkFigmaPrerequisites({
  required List<String> missingRequired,
  required List<String> missingOptional,
  required int reachableSources,
}) {
  const klass = PrerequisiteClass.runnerControlled;
  const name = 'figma sources';

  final all = [...missingRequired, ...missingOptional];

  if (missingRequired.isNotEmpty) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: all.join('; '),
      remedy: 'Set the variable, or add the node mapping, before the run. '
          'A declared design that cannot be loaded is an error in the figma '
          'dimension, so the screen is reached and then not compared.',
    );
  }

  if (missingOptional.isNotEmpty) {
    return PreflightCheck.notice(
      name,
      klass: klass,
      detail: '${all.join('; ')}; the suite does not require '
          '${missingOptional.length == 1 ? 'it' : 'them'}, so each will be an '
          'error of its own',
    );
  }

  if (reachableSources == 0) {
    return const PreflightCheck.satisfied(
      name,
      klass: klass,
      detail: 'no screen this suite reaches declares a design',
    );
  }

  return PreflightCheck.satisfied(
    name,
    klass: klass,
    detail: '$reachableSources declared design'
        '${reachableSources == 1 ? '' : 's'}, each with its token and node '
        'mapping',
  );
}

/// One screen is described by one configuration.
///
/// A project may name a screen in more than one kind of file - a mapping
/// and a design - but not twice in either kind. Since `6749e7f` that is
/// refused outright: `run` and `suite run` both stop rather than let
/// `Directory.listSync()` order decide which file wins.
///
/// Preflight did not ask, and so answered "nothing blocking" for a suite
/// that could not start - the one question this layer exists to get
/// right. It is asked here and nowhere else in the engine, because
/// deciding *what counts as* a duplicate belongs to the loaders the run
/// itself uses; this only reports what they said.
///
/// [duplicate] is that report, already phrased, or null when every
/// screen is described once.
///
/// [skipped] is the designs the loader could not read. A **notice**, and
/// deliberately not a blocker: a design that will not parse describes no
/// screen, so it takes nothing away from another and a run is still
/// answerable without it - the severity `figma_spec_reading_test.dart`
/// has pinned since c9c4532. What it must not be is invisible. Reported
/// as `[ok] one configuration per screen`, this row made an affirmative
/// about a directory holding a file nobody could read, which is the same
/// shape of wrongness as the unreadable mapping above and the empty
/// device facts in `checkProfileMatch`.
PreflightCheck checkScreenConfiguration({
  required String? duplicate,
  required String? unreadable,
  List<String> skipped = const [],
}) {
  const klass = PrerequisiteClass.runnerControlled;
  const name = 'screen configuration';

  // Before the duplicate, because a file that will not parse describes
  // no screen and the loader stops at it: the two cannot both be true.
  //
  // This is not the same defect as two files for one screen, and the
  // difference is what makes it worth a branch of its own. There the
  // configuration was read and was ambiguous; here it was not read at
  // all - so "one configuration per screen" was an answer to a question
  // nobody asked, printed as `[ok]` while `run` exited 1 and `suite run`
  // exited 2 on the same project.
  if (unreadable != null) {
    return PreflightCheck.blocked(
      name,
      klass: klass,
      detail: unreadable,
      remedy: 'Fix the file. Until it parses, nothing can say which screens '
          'this project configures, and a run refuses it outright.',
    );
  }

  if (duplicate == null) {
    if (skipped.isEmpty) {
      return const PreflightCheck.satisfied(
        name,
        klass: klass,
        detail: 'one configuration per screen',
      );
    }
    return PreflightCheck.notice(
      name,
      klass: klass,
      detail: 'one configuration per screen; '
          '${skipped.length} design${skipped.length == 1 ? '' : 's'} could '
          'not be read and ${skipped.length == 1 ? 'was' : 'were'} skipped '
          '(${skipped.join('; ')})',
    );
  }

  return PreflightCheck.blocked(
    name,
    klass: klass,
    detail: duplicate,
    remedy: 'Remove or rename one of them, or give them different screens. '
        'A run refuses this rather than choosing between them, so the suite '
        'cannot start until it is resolved.',
  );
}
