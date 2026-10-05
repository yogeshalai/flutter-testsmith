// What "the application is not on this device" means, and what it must
// never be confused with.
//
// `testsmith run` and `testsmith suite run` ask the same question at different
// moments, and that difference is deliberate: a suite answers it in
// preflight, before anything is built, because it grants permissions and
// clears state before the first launch; a single run answers it after
// `flutter run` has installed the application, because before that point
// "not installed" is true of every first run and means nothing.
//
// What they share is the probe, and the probe was unsound. `adb shell pm
// list packages` against an offline or unauthorised handset exits
// non-zero with empty stdout, and the exit code was discarded - so a
// device that said nothing was read as a device that said "no such
// package". Preflight then told people to reinstall an application that
// was already there, and the launch-time check introduced in the previous
// milestone reported "the device has no package <id>" about a handset
// that had simply dropped.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/adb_device_environment.dart';
import 'package:flutter_testsmith_cli/src/commands/preflight_command.dart';
import 'package:flutter_testsmith_cli/src/flow_executor.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// An adb that answers the way a healthy device answers.
class _Adb implements ProcessRunner {
  _Adb(this.installed);

  final Set<String> installed;

  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) {
    final line = arguments.join(' ');
    if (line.contains('pm list packages')) {
      final query = arguments.last.split(' ').last;
      return Future.value(ProcessResultData(
        exitCode: 0,
        stdout: [
          for (final id in installed)
            if (id.startsWith(query)) 'package:$id',
        ].join('\n'),
        stderr: '',
      ));
    }
    return Future.value(
      const ProcessResultData(exitCode: 0, stdout: '', stderr: ''),
    );
  }
}

/// An adb whose commands fail the way a dropped device makes them fail:
/// non-zero, nothing on stdout, the reason on stderr.
class _UnreachableDevice implements ProcessRunner {
  _UnreachableDevice(this.reason);

  final String reason;

  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) =>
      Future.value(
        ProcessResultData(exitCode: 1, stdout: '', stderr: reason),
      );
}

/// No adb on the PATH at all.
class _NoAdb implements ProcessRunner {
  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) =>
      throw ProcessException('adb', arguments, 'No such file or directory', 2);
}

void main() {
  const appId = 'com.acme.myapp';

  group('the probe', () {
    test('says yes when the package is there', () async {
      final environment = AdbDeviceEnvironment(
        serial: 'S',
        processRunner: _Adb({appId}),
      );

      expect(await environment.isInstalled(appId), isTrue);
    });

    test('says no when the device answered and did not list it', () async {
      final environment = AdbDeviceEnvironment(
        serial: 'S',
        processRunner: _Adb({'com.other.app'}),
      );

      expect(await environment.isInstalled(appId), isFalse);
    });

    test('says nothing at all when the device is offline', () async {
      // The regression. This used to be `false`, which is a claim about
      // somebody's application made from a question that was never asked.
      final environment = AdbDeviceEnvironment(
        serial: 'S',
        processRunner: _UnreachableDevice('error: device offline'),
      );

      expect(await environment.isInstalled(appId), isNull);
    });

    test('says nothing at all when the device is unauthorised', () async {
      final environment = AdbDeviceEnvironment(
        serial: 'S',
        processRunner: _UnreachableDevice('error: device unauthorized'),
      );

      expect(await environment.isInstalled(appId), isNull);
    });

    test('says nothing at all when adb is not installed', () async {
      // And does not throw: a preflight that crashes over a missing tool
      // reports a configuration mistake as a crash, which is the failure
      // mode E-04 exists to remove.
      final environment =
          AdbDeviceEnvironment(serial: 'S', processRunner: _NoAdb());

      expect(await environment.isInstalled(appId), isNull);
    });

    test('reads no permission table from a device that would not answer',
        () async {
      // Empty used to mean "the application declares none", which
      // `checkPermissions` reports as a blocker naming every declared
      // permission as undeclared.
      final environment = AdbDeviceEnvironment(
        serial: 'S',
        processRunner: _UnreachableDevice('error: device offline'),
      );

      expect(await environment.runtimePermissions(appId), isNull);
    });

    test('reports the network as unknown rather than down', () async {
      // Already the rule for this one probe, and asserted here so the
      // three cannot drift apart again.
      final environment = AdbDeviceEnvironment(
        serial: 'S',
        processRunner: _UnreachableDevice('error: device offline'),
      );

      expect(
        await environment.networkInterface(),
        NetworkInterfaceState.unknown,
      );
    });
  });

  group('what preflight makes of it', () {
    test('a package that is there is satisfied', () {
      final check = checkAppInstalled(
        appId: appId,
        installed: true,
        neededBeforeLaunch: true,
      );

      expect(check.outcome, PreflightOutcome.satisfied);
    });

    test('a package that is absent before a first launch is only a notice',
        () {
      // The lifecycle rule this milestone had to preserve. `flutter run`
      // installs the application on its way past, so a suite that touches
      // nothing beforehand must not be blocked for not having it yet.
      final check = checkAppInstalled(
        appId: appId,
        installed: false,
        neededBeforeLaunch: false,
      );

      expect(check.outcome, PreflightOutcome.notice);
      expect(check.isBlocking, isFalse);
    });

    test('a package that is absent and needed beforehand blocks', () {
      final check = checkAppInstalled(
        appId: appId,
        installed: false,
        neededBeforeLaunch: true,
      );

      expect(check.outcome, PreflightOutcome.blocked);
    });

    test('a device that would not answer defers, and blocks nothing', () {
      // Neither satisfied nor blocked. A deferral is printed as plainly
      // as a blocker, and it does not offer a remedy for a problem nobody
      // established.
      final check = checkAppInstalled(
        appId: appId,
        installed: null,
        neededBeforeLaunch: true,
      );

      expect(check.outcome, PreflightOutcome.deferred);
      expect(check.isBlocking, isFalse);
      expect(check.remedy, isEmpty);
      // The negative control: it must not read as the application's fault.
      expect(check.detail, isNot(contains('not installed')));
    });

    test('an unreadable permission table defers instead of denying', () {
      final check = checkPermissions(
        appId: appId,
        required: const ['android.permission.CAMERA'],
        granted: null,
      );

      expect(check.outcome, PreflightOutcome.deferred);
      expect(check.isBlocking, isFalse);
      // Never a `pm grant` against a device that is not answering.
      expect(check.remedy, isEmpty);
    });

    test('a genuinely denied permission still blocks', () {
      // The negative control for the deferral above: normalising the
      // unknown case must not soften the known one.
      final check = checkPermissions(
        appId: appId,
        required: const ['android.permission.CAMERA'],
        granted: const {'android.permission.CAMERA': false},
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.remedy, contains('pm grant'));
    });
  });

  group('run and suite classify an unusable environment alike', () {
    // The per-status codes are already pinned in step_classification_test;
    // what was not pinned is that the constant `testsmith run` returns when
    // it never reached a result agrees with them. It returned 1 - the
    // code reserved for "something is wrong with the application" - for
    // an application that never started, while `suite run` returned 2 for
    // the same condition.
    RunResult errored() => RunResult(
          flowName: 'f',
          appId: 'com.acme.myapp',
          device: 'S',
          startedAt: DateTime.utc(2026),
          duration: Duration.zero,
          steps: const [
            StepOutcome(
              description: 's',
              kind: StepKind.tap,
              status: StepStatus.observationFailed,
              durationMs: 0,
            ),
          ],
          screens: const [],
        );

    test('a run that never started is not an application failure', () {
      expect(
        environmentExitCode,
        exitCodeForRun(errored()),
        reason: 'one condition must not be two exit codes',
      );
    });

    test('and that code is still not the one a real verdict uses', () {
      // The negative control. Agreeing on 1 would also satisfy the test
      // above, and would be exactly the bug.
      expect(environmentExitCode, isNot(1));
      expect(environmentExitCode, 2);
    });
  });
}
