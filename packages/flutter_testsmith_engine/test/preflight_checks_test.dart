// Every judgement preflight makes, as a pure function.
//
// Deliberately no device and no filesystem. What counts as blocked, what
// counts as merely worth saying, and what a runner is allowed to conclude
// from a fact it could not read are decisions, and decisions that can only
// be checked by somebody holding a handset are decisions nobody checks.
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

void main() {
  group('device', () {
    test('blocks when nothing is attached', () {
      final check = checkDeviceAttached(attached: const [], requested: null);

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.klass, PrerequisiteClass.devicePrerequisite);
      expect(check.remedy, contains('testsmith devices'));
    });

    test('blocks when the named device is not among those attached', () {
      final check = checkDeviceAttached(
        attached: const [
          AdbDevice(serial: 'A', model: 'SM-M127G', state: 'device'),
        ],
        requested: 'B',
      );

      expect(check.outcome, PreflightOutcome.blocked);
    });

    test('blocks when several are attached and none was named', () {
      final check = checkDeviceAttached(
        attached: const [
          AdbDevice(serial: 'A', model: 'SM-M127G', state: 'device'),
          AdbDevice(serial: 'B', model: 'SM-M127G', state: 'device'),
        ],
        requested: null,
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.remedy, contains('--device'));
    });

    test('accepts the sole attached device when none was named', () {
      final check = checkDeviceAttached(
        attached: const [
          AdbDevice(serial: 'A', model: 'SM-M127G', state: 'device'),
        ],
        requested: null,
      );

      expect(check.outcome, PreflightOutcome.satisfied);
    });

    test('records the model and never the serial', () {
      final check = checkDeviceAttached(
        attached: const [
          AdbDevice(
            serial: 'RZ8T11QETWM',
            model: 'SM-M127G',
            state: 'device',
          ),
        ],
        requested: 'RZ8T11QETWM',
      );

      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.detail, contains('SM-M127G'));
      expect(check.detail, isNot(contains('RZ8T11QETWM')));
      expect(check.remedy, isNot(contains('RZ8T11QETWM')));
    });
  });

  group('device, when adb itself could not answer', () {
    const device = AdbDevice(serial: 'S1', model: 'SM-M127G', state: 'device');

    test('an adb problem blocks, and says so instead of blaming the device',
        () {
      final check = checkDeviceAttached(
        attached: const [],
        requested: 'S1',
        adbProblem: 'adb could not be found.',
        adbRemedy: 'Install the Android platform-tools.',
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('adb'));
      expect(check.remedy, contains('platform-tools'));
      // The two sentences this exists to stop: neither is true when the
      // tool that would have answered never ran.
      expect(check.detail, isNot(contains('no usable device is attached')));
      expect(check.detail, isNot(contains('the named device is not attached')));
    });

    test('the adb problem is reported before anything about the serial', () {
      // Ordering, not preference. A stale device list with a broken adb
      // must not produce a verdict about the serial: nothing was read.
      final check = checkDeviceAttached(
        attached: const [device],
        requested: 'SOMETHING-ELSE',
        adbProblem: 'adb could not be found.',
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('adb'));
      expect(check.detail, isNot(contains('the named device is not attached')));
    });

    test('an adb problem with no hint still carries a remedy', () {
      final check = checkDeviceAttached(
        attached: const [],
        requested: null,
        adbProblem: 'adb could not be found.',
      );

      expect(check.remedy, isNotEmpty);
    });

    group('and when it could', () {
      test('zero devices is still an absent device, not an adb failure', () {
        // The control this whole change turns on: adb answering "none"
        // is a successful query, and must keep the wording it has.
        final check = checkDeviceAttached(
          attached: const [],
          requested: 'S1',
        );

        expect(check.outcome, PreflightOutcome.blocked);
        expect(check.detail, 'no usable device is attached');
      });

      test('a serial that is not there still names the serial', () {
        final check = checkDeviceAttached(
          attached: const [device],
          requested: 'SOMETHING-ELSE',
        );

        expect(check.outcome, PreflightOutcome.blocked);
        expect(check.detail, 'the named device is not attached');
        expect(check.remedy, contains('Check the serial'));
      });

      test('the named device being there is still satisfied', () {
        final check = checkDeviceAttached(
          attached: const [device],
          requested: 'S1',
        );

        expect(check.outcome, PreflightOutcome.satisfied);
      });
    });
  });

  group('device profile', () {
    final profile = DeviceProfile.parse(
      'id: samsung-m127g\n'
      'model: SM-M127G\n'
      'physical: {width: 720, height: 1600}\n',
      source: 'profile.yaml',
    );

    test('blocks when the device is not the one the profile names', () {
      final check = checkProfileMatch(
        profile: profile,
        facts: const DeviceFacts(model: 'Pixel 7'),
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('SM-M127G'));
      expect(check.detail, contains('Pixel 7'));
    });

    test('blocks on a resolution the baselines could not be compared at', () {
      final check = checkProfileMatch(
        profile: profile,
        facts: const DeviceFacts(
          model: 'SM-M127G',
          physicalWidth: 1080,
          physicalHeight: 2400,
        ),
      );

      expect(check.outcome, PreflightOutcome.blocked);
    });

    test('a fact the device did not report is not a mismatch', () {
      // The device answered, and agreed on everything it named. A
      // resolution it did not report is silence about the resolution,
      // not disagreement about it - so the comparison is skipped and
      // what was read still stands.
      final check = checkProfileMatch(
        profile: profile,
        facts: const DeviceFacts(model: 'SM-M127G'),
      );

      expect(check.outcome, PreflightOutcome.satisfied);
    });

    test('a device that reported nothing is deferred, not matched', () {
      // The false affirmative. `readDeviceFacts` answers with an empty
      // DeviceFacts when adb throws or the serial is not attached; every
      // comparison is then skipped for want of an actual value, and an
      // empty mismatch list used to come back as agreement - reported as
      // `[ok] device profile samsung-m127g (SM-M127G)` over a handset
      // nobody had managed to read a single fact from.
      final check = checkProfileMatch(
        profile: profile,
        facts: const DeviceFacts(),
      );

      expect(check.outcome, PreflightOutcome.deferred);
      expect(check.outcome, isNot(PreflightOutcome.satisfied));
      // Still not a blocker: nothing was learned, and an admission is
      // not a verdict.
      expect(check.isBlocking, isFalse);
      expect(check.detail, contains('samsung-m127g'));
    });

    test('accepts the device the profile describes', () {
      final check = checkProfileMatch(
        profile: profile,
        facts: const DeviceFacts(
          model: 'SM-M127G',
          physicalWidth: 720,
          physicalHeight: 1600,
        ),
      );

      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.detail, contains('samsung-m127g'));
    });
  });

  group('application installed', () {
    test('blocks when the suite touches the application before launching it',
        () {
      final check = checkAppInstalled(
        appId: 'com.example.app',
        installed: false,
        neededBeforeLaunch: true,
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.remedy, contains('flutter run'));
    });

    test('is only a notice when the first launch would install it anyway', () {
      final check = checkAppInstalled(
        appId: 'com.example.app',
        installed: false,
        neededBeforeLaunch: false,
      );

      expect(check.outcome, PreflightOutcome.notice);
      expect(check.isBlocking, isFalse);
    });

    test('is satisfied when it is there', () {
      final check = checkAppInstalled(
        appId: 'com.example.app',
        installed: true,
        neededBeforeLaunch: true,
      );

      expect(check.outcome, PreflightOutcome.satisfied);
    });
  });

  group('permissions', () {
    test('blocks on one the suite requires and the device denies', () {
      final check = checkPermissions(
        appId: 'com.example.app',
        required: const ['android.permission.ACCESS_FINE_LOCATION'],
        granted: const {'android.permission.ACCESS_FINE_LOCATION': false},
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('ACCESS_FINE_LOCATION'));
      expect(check.remedy, contains('pm grant'));
    });

    test('blocks differently on one the application never declared', () {
      // `pm grant` cannot grant a permission the manifest does not
      // request, so offering that remedy would be offering one that does
      // not work.
      final check = checkPermissions(
        appId: 'com.example.app',
        required: const ['android.permission.CAMERA'],
        granted: const {},
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('does not declare'));
      expect(check.remedy, isNot(contains('pm grant')));
    });

    test('is satisfied when every required permission is granted', () {
      final check = checkPermissions(
        appId: 'com.example.app',
        required: const [
          'android.permission.ACCESS_FINE_LOCATION',
          'android.permission.ACCESS_COARSE_LOCATION',
        ],
        granted: const {
          'android.permission.ACCESS_FINE_LOCATION': true,
          'android.permission.ACCESS_COARSE_LOCATION': true,
        },
      );

      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.detail, contains('2'));
    });

    test('a suite that requires none is satisfied without reading anything',
        () {
      final check = checkPermissions(
        appId: 'com.example.app',
        required: const [],
        granted: const {},
      );

      expect(check.outcome, PreflightOutcome.satisfied);
    });
  });

  group('network interface', () {
    test('blocks when the device has no active default network', () {
      final check = checkNetworkInterface(NetworkInterfaceState.down);

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.klass, PrerequisiteClass.devicePrerequisite);
    });

    test('says an interface is required without implying a backend is', () {
      final check = checkNetworkInterface(NetworkInterfaceState.down);

      expect(check.detail, contains('NETWORK_INTERFACE_REQUIRED'));
      expect(check.remedy, contains('No backend'));
      expect(check.detail, isNot(contains('BACKEND_ACCESS_REQUIRED')));
    });

    test('an unreadable state is deferred, not a failure', () {
      final check = checkNetworkInterface(NetworkInterfaceState.unknown);

      expect(check.outcome, PreflightOutcome.deferred);
      expect(check.isBlocking, isFalse);
    });

    test('is satisfied when an interface is up', () {
      final check = checkNetworkInterface(NetworkInterfaceState.up);

      expect(check.outcome, PreflightOutcome.satisfied);
    });
  });

  group('mock API', () {
    test('is satisfied, and says so, when the suite declares no mock API', () {
      final check = checkMockApi(
        port: null,
        portFree: true,
        scenarioProblem: null,
        unresolvableFixtures: const [],
      );

      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.detail, contains('no mock API'));
    });

    test('blocks when the port is already in use', () {
      final check = checkMockApi(
        port: 8080,
        portFree: false,
        scenarioProblem: null,
        unresolvableFixtures: const [],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('8080'));
      expect(check.remedy, contains('mockApi.port'));
    });

    test('blocks when a scenario file will not parse', () {
      final check = checkMockApi(
        port: 8080,
        portFree: true,
        scenarioProblem: 'default.json: "routes" must be a mapping',
        unresolvableFixtures: const [],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('routes'));
    });

    test('blocks when a flow names an API state no scenario provides', () {
      final check = checkMockApi(
        port: 8080,
        portFree: true,
        scenarioProblem: null,
        unresolvableFixtures: const ['home -> dashboard_populated'],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('dashboard_populated'));
    });

    test('is satisfied when the port is free and every state resolves', () {
      final check = checkMockApi(
        port: 8080,
        portFree: true,
        scenarioProblem: null,
        unresolvableFixtures: const [],
      );

      expect(check.outcome, PreflightOutcome.satisfied);
    });

    test('blocks when a required test needs a state and there is no server',
        () {
      // "This suite declares no mock API" was said about a suite whose
      // flow declares one: `run` refuses the same pair outright, and the
      // suite discovered it per test, after the device and the launch.
      final check = checkMockApi(
        port: null,
        portFree: true,
        scenarioProblem: null,
        unresolvableFixtures: const [],
        fixturesWithoutServer: const ['home -> signed_in'],
        optionalFixturesWithoutServer: const [],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('signed_in'));
      expect(check.remedy, contains('mockApi.port'));
    });

    test('is only a notice when every test that needs one is optional', () {
      // A suite whose verdict counts only its required tests can still
      // pass with these failing, and blocking it would refuse a run that
      // would have succeeded.
      final check = checkMockApi(
        port: null,
        portFree: true,
        scenarioProblem: null,
        unresolvableFixtures: const [],
        fixturesWithoutServer: const [],
        optionalFixturesWithoutServer: const ['extra -> signed_in'],
      );

      expect(check.outcome, PreflightOutcome.notice);
      expect(check.isBlocking, isFalse);
      expect(check.detail, contains('extra'));
    });

    test('and one required test is enough to block, optional ones or not', () {
      final check = checkMockApi(
        port: null,
        portFree: true,
        scenarioProblem: null,
        unresolvableFixtures: const [],
        fixturesWithoutServer: const ['home -> signed_in'],
        optionalFixturesWithoutServer: const ['extra -> signed_in'],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('home'));
      expect(check.detail, contains('extra'));
    });
  });

  group('flows', () {
    // A flow that will not parse was dropped before any check saw it:
    // `_flows()` skipped it, so preflight reported "nothing blocking"
    // about a suite one of whose tests cannot run. `testsmith run`
    // refuses the same file before anything is launched.
    test('blocks when a required test names one that will not parse', () {
      final check = checkFlowsReadable(
        requiredTests: const ['home: invalid YAML'],
        optionalTests: const [],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('home'));
    });

    test('is a notice when only optional tests name one', () {
      final check = checkFlowsReadable(
        requiredTests: const [],
        optionalTests: const ['extra: invalid YAML'],
      );

      expect(check.outcome, PreflightOutcome.notice);
      expect(check.isBlocking, isFalse);
      expect(check.detail, contains('extra'));
    });

    test('but an optional one is still reported, never dropped', () {
      final check = checkFlowsReadable(
        requiredTests: const [],
        optionalTests: const ['extra: invalid YAML'],
      );

      expect(check.outcome, isNot(PreflightOutcome.satisfied));
    });

    test('one required test is enough, whatever else is optional', () {
      final check = checkFlowsReadable(
        requiredTests: const ['home: invalid YAML'],
        optionalTests: const ['extra: invalid YAML'],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('home'));
      expect(check.detail, contains('extra'));
    });

    test('is satisfied when every flow the suite names could be read', () {
      final check = checkFlowsReadable(
        requiredTests: const [],
        optionalTests: const [],
      );

      expect(check.outcome, PreflightOutcome.satisfied);
    });
  });

  group('screen configuration', () {
    test('blocks when a mapping could not be read at all', () {
      // Distinct from two files describing one screen. Here the file
      // itself will not parse, so the question "is there one
      // configuration per screen?" was never answered - and answering
      // it affirmatively is the part that misleads.
      final check = checkScreenConfiguration(
        duplicate: null,
        unreadable: 'home.yaml could not be read: invalid YAML',
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('home.yaml'));
    });

    test('still blocks on two files for one screen', () {
      final check = checkScreenConfiguration(
        duplicate: 'duplicate screen configuration for "/home": a.yaml, z.yaml',
        unreadable: null,
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('/home'));
    });

    test('is satisfied only when the configuration was read and is one', () {
      final check =
          checkScreenConfiguration(duplicate: null, unreadable: null);

      expect(check.outcome, PreflightOutcome.satisfied);
    });
  });

  group('screen configuration, and a design that would not read', () {
    test('a skipped design is a notice, not a blocker', () {
      // R16. A design file that will not parse describes no screen, so
      // it takes nothing away from another and must not refuse the run.
      // What it must also not do is vanish: `[ok] one configuration per
      // screen` is an affirmative about a directory holding a file
      // nobody could read.
      final check = checkScreenConfiguration(
        duplicate: null,
        unreadable: null,
        skipped: const ['stray.json: "screen" is required'],
      );

      expect(check.outcome, PreflightOutcome.notice);
      expect(check.isBlocking, isFalse);
      expect(check.detail, contains('stray.json'));
      // The affirmative it replaces must not still be the whole story.
      expect(check.detail, isNot('one configuration per screen'));
    });

    test('nothing skipped is still the plain affirmative', () {
      final check = checkScreenConfiguration(
        duplicate: null,
        unreadable: null,
      );

      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.detail, 'one configuration per screen');
    });

    test('a duplicate still blocks even when a design was skipped', () {
      // Severity order: two readable files claiming one screen is fatal,
      // and a file nobody could read does not soften it.
      final check = checkScreenConfiguration(
        duplicate: 'duplicate screen configuration for "/home": a, b',
        unreadable: null,
        skipped: const ['stray.json: "screen" is required'],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('duplicate'));
    });

    test('an unreadable mapping still blocks even when a design was skipped',
        () {
      final check = checkScreenConfiguration(
        duplicate: null,
        unreadable: 'home.yaml could not be read: invalid YAML',
        skipped: const ['stray.json: "screen" is required'],
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('home.yaml'));
    });

    test('several skipped designs are all named', () {
      final check = checkScreenConfiguration(
        duplicate: null,
        unreadable: null,
        skipped: const ['a.json: bad', 'b.json: bad'],
      );

      expect(check.outcome, PreflightOutcome.notice);
      expect(check.detail, contains('a.json'));
      expect(check.detail, contains('b.json'));
    });
  });

  group('application build', () {
    test('blocks when the declared entry point is not in the project', () {
      final check = checkAppBuild(
        target: 'lib/main_mytest.dart',
        targetExists: false,
        flutterOnPath: true,
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('lib/main_mytest.dart'));
    });

    test('blocks when flutter is not on PATH', () {
      final check = checkAppBuild(
        target: null,
        targetExists: true,
        flutterOnPath: false,
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.remedy, contains('PATH'));
    });

    test('is satisfied with a target that exists and a toolchain present', () {
      final check = checkAppBuild(
        target: 'lib/main_mytest.dart',
        targetExists: true,
        flutterOnPath: true,
      );

      expect(check.outcome, PreflightOutcome.satisfied);
    });
  });

  group('baselines', () {
    test('a missing baseline is a notice, because E-03 records and skips', () {
      final check = checkBaselines(
        missing: const ['home -> /home@dashboard_populated'],
      );

      expect(check.outcome, PreflightOutcome.notice);
      expect(check.isBlocking, isFalse);
      expect(check.detail, contains('/home@dashboard_populated'));
    });

    test('is satisfied when every photographed screen has one', () {
      final check = checkBaselines(missing: const []);

      expect(check.outcome, PreflightOutcome.satisfied);
    });
  });

  group('flow status', () {
    // The invariant CLAUDE.md states as "generated flows are stamped
    // `status: proposed` by the generator - not by the model - and
    // refuse to run". `testsmith run` refused them from the start.
    // A suite did not: measured on one project, `suite run` reported
    // "nothing blocking" and launched a generated flow nobody had read,
    // then judged the application on it.
    test('blocks when a test names a flow nobody has accepted', () {
      final check = checkFlowStatus(proposed: const ['home']);

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('home'));
    });

    test('names every one of them, not the first', () {
      final check = checkFlowStatus(proposed: const ['home', 'checkout']);

      expect(check.detail, contains('home'));
      expect(check.detail, contains('checkout'));
    });

    test('is a human action, because accepting one is the review itself', () {
      // Automating acceptance would bypass the very thing the status
      // line establishes, which is what ADR-0009 exists to prevent.
      final check = checkFlowStatus(proposed: const ['home']);

      expect(check.klass, PrerequisiteClass.humanAction);
    });

    test('says how to accept it, in the words run already uses', () {
      final check = checkFlowStatus(proposed: const ['home']);

      expect(check.remedy, contains('status: proposed'));
      expect(check.remedy.toLowerCase(), contains('read'));
    });

    test('and offers no way to run it unreviewed', () {
      // A remedy that told CI how to proceed anyway would undo the
      // check. Trying one ad hoc is `testsmith run --allow-proposed`,
      // which is a person at a keyboard and one flow; a suite has no
      // such flag and must not learn one here.
      final check = checkFlowStatus(proposed: const ['home']);
      final text = '${check.detail} ${check.remedy}'.toLowerCase();

      expect(text, isNot(contains('--allow-proposed')));
      expect(text, isNot(contains('ignore')));
    });

    test('is satisfied when every flow has been accepted', () {
      final check = checkFlowStatus(proposed: const []);

      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.isBlocking, isFalse);
    });

    test('says nothing about a flow it could not read', () {
      // The affirmative this check must not make. A flow that will not
      // parse never reaches `isProposed`, so "every flow this suite
      // names has been accepted" was a claim about a file nobody read.
      final check = checkFlowStatus(proposed: const [], unread: 1);

      expect(check.outcome, PreflightOutcome.deferred);
      expect(check.isBlocking, isFalse);
    });

    test('and an unread flow never hides one that is proposed', () {
      final check = checkFlowStatus(proposed: const ['home'], unread: 1);

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('home'));
    });
  });

  group('authentication', () {
    test('is deferred, and names the tests that require it', () {
      final check = checkAuthentication(requiredBy: const ['home', 'orders']);

      expect(check.outcome, PreflightOutcome.deferred);
      expect(check.klass, PrerequisiteClass.humanAction);
      expect(check.detail, contains('home'));
      expect(check.detail, contains('orders'));
      expect(check.detail, contains('first launch'));
    });

    test('is never blocking, because it is never observable in advance', () {
      final check = checkAuthentication(requiredBy: const ['home']);

      expect(check.isBlocking, isFalse);
    });

    test('is satisfied when no test in the suite requires a session', () {
      final check = checkAuthentication(requiredBy: const []);

      expect(check.outcome, PreflightOutcome.satisfied);
    });

    test('mentions no credential and no storage key', () {
      // The two ways to learn sign-in state early are to read the
      // application's own storage or to write to it. The first proves
      // only that something was written; the second is the bypass this
      // platform refuses. Neither may appear even as a suggestion.
      final check = checkAuthentication(requiredBy: const ['home']);
      final text = '${check.detail} ${check.remedy}'.toLowerCase();

      expect(text, isNot(contains('is_logged_in')));
      expect(text, isNot(contains('token')));
      expect(text, isNot(contains('sharedpreferences')));
      expect(text, isNot(contains('run-as')));
    });
  });

  group('figma prerequisites', () {
    test('nothing declared is satisfied, and says so', () {
      final check = checkFigmaPrerequisites(
        missingRequired: const [],
        missingOptional: const [],
        reachableSources: 0,
      );

      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.detail, contains('no'));
    });

    test('a reachable source with everything present is satisfied', () {
      final check = checkFigmaPrerequisites(
        missingRequired: const [],
        missingOptional: const [],
        reachableSources: 2,
      );

      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.detail, contains('2'));
    });

    test('a required test missing its token blocks, and names it', () {
      final check = checkFigmaPrerequisites(
        missingRequired: const ['home -> /home: FIGMA_TOKEN is not set'],
        missingOptional: const [],
        reachableSources: 1,
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('FIGMA_TOKEN'));
      expect(check.detail, contains('home -> /home'));
      expect(check.remedy, isNotEmpty);
    });

    test('a required test missing its node mapping blocks', () {
      final check = checkFigmaPrerequisites(
        missingRequired: const [
          'home -> /home: figma/home.nodes.yaml does not exist',
        ],
        missingOptional: const [],
        reachableSources: 1,
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('figma/home.nodes.yaml'));
    });

    test('an optional test alone is a notice, not a blocker', () {
      // The rule `checkMockApi` and `checkFlowsReadable` already hold to:
      // `SuiteResult.verdict` counts only required tests, so a suite
      // whose affected tests are all `optional:` can still pass. Blocking
      // it would refuse a run that would have succeeded.
      final check = checkFigmaPrerequisites(
        missingRequired: const [],
        missingOptional: const ['extra -> /other: FIGMA_TOKEN is not set'],
        reachableSources: 1,
      );

      expect(check.outcome, PreflightOutcome.notice);
      expect(check.isBlocking, isFalse);
      expect(check.detail, contains('extra -> /other'));
    });

    test('a required and an optional one together block, and name both', () {
      final check = checkFigmaPrerequisites(
        missingRequired: const ['home -> /home: FIGMA_TOKEN is not set'],
        missingOptional: const ['extra -> /other: mapping does not exist'],
        reachableSources: 2,
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('home -> /home'));
      expect(check.detail, contains('extra -> /other'));
    });

    test('never suggests a network check or echoes a token value', () {
      // Locally knowable prerequisites only. Whether the token *works*
      // is a question for the run, and asking it here would make
      // preflight make a request.
      final check = checkFigmaPrerequisites(
        missingRequired: const ['home -> /home: FIGMA_TOKEN is not set'],
        missingOptional: const [],
        reachableSources: 1,
      );
      final text = '${check.detail} ${check.remedy}'.toLowerCase();

      expect(text, isNot(contains('http')));
      expect(text, isNot(contains('valid')));
    });
  });
}
