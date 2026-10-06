import 'dart:io';

import 'package:flutter_testsmith/engine.dart';

import 'output.dart';

/// Every device adb can see, or null when adb could not be asked.
///
/// Null is "I could not ask", which is a different answer from "nothing
/// is attached" and is reported here rather than left to escape: a
/// missing adb used to leave `testsmith devices`, `run`, `smoke` and
/// `inspect` exiting 255 with a Dart stack trace.
///
/// Shared by the two questions below because the report has to be the
/// same sentence whichever of them asked it.
Future<List<AdbDevice>?> _attached(Output output) async {
  final adb = resolveAdb();
  if (!adb.isFound) {
    // "I could not ask", in the resolver's own words - the sentence
    // `doctor`, `preflight`, `suite run` and `auth setup` already say.
    // This used to cover only an explicit `MYTEST_ADB` that was not
    // there and launch the bare name for everything else, so a machine
    // with no adb heard "could not be started" from here and "could not
    // be found" from every other command. The bare launch finds nothing
    // the resolver misses: its PATH scan takes the runner's own names,
    // `adb.bat` and `adb.cmd` included.
    output
      ..line(output.red(adb.problem!))
      ..line(output.dim('  ${adb.hint}'));
    return null;
  }

  final ProcessResultData result;
  try {
    result = await const SystemProcessRunner(
      timeout: AdbDeviceController.commandTimeout,
    ).run(adb.executable!, const ['devices', '-l']);
  } on ProcessTimeoutException catch (error) {
    // Asked, and never answered: still "I could not ask", for a reason
    // with its own remedy. It used to be a command that never returned.
    output
      ..line(output.red(
        'adb did not answer within ${error.timeout.inSeconds} seconds.',
      ))
      ..line(output.dim(adbUnresponsiveHint));
    return null;
  } on ProcessException {
    // Found, and would not launch: the one case this sentence is for.
    output
      ..line(output.red('adb could not be started.'))
      ..line(output.dim('  ${adb.hint.isEmpty ? 'Install the Android '
          'platform-tools and put adb on PATH, or set MYTEST_ADB to the '
          'executable.' : adb.hint}'));
    return null;
  }
  return parseAdbDevices(result.stdout);
}

/// What to do about an adb that ran and never answered. One sentence,
/// for every command that asks adb which devices are attached.
const String adbUnresponsiveHint = '  Its server may be stuck: run '
    '`adb kill-server`, reconnect the device, and try again.';

/// Picks the device to drive when none was named.
///
/// Refuses to guess between several: silently choosing one leads to a run
/// that appears to work while testing the wrong device.
Future<String?> selectSoleDevice(Output output) async {
  final devices = await _attached(output);
  if (devices == null) return null;

  if (devices.isEmpty) {
    output.line(output.red('No usable device attached. Run: testsmith devices'));
    return null;
  }
  if (devices.length > 1) {
    output.line(
      output.red('Several devices attached; choose one with --device:'),
    );
    for (final device in devices) {
      output.line('  ${device.serial}  ${device.model}');
    }
    return null;
  }
  return devices.single.serial;
}

/// The Android package a command will target, or null with an explanation.
///
/// Required rather than derived, and that is a decision rather than a gap.
/// The package a `flutter run` installs is the `applicationId` of the
/// variant it built: a flavour, a build type and any `applicationIdSuffix`
/// all change it, and plenty of projects compute it in Gradle rather than
/// writing it down. Reading `defaultConfig.applicationId` out of
/// `build.gradle` would therefore be right for simple projects and quietly
/// wrong for exactly the flavoured ones this platform was validated
/// against - and quietly wrong is the whole failure being closed here.
///
/// Neither runtime source helps. `flutter run --machine` reports an
/// `appId` on `app.start`, but that is a freshly generated UUID naming the
/// daemon's app instance, not a package. `ext.mytest.sessionInfo` reports
/// what the application declares to its own SDK, which `AuthFile` already
/// models as a separate value because the two genuinely differ.
///
/// So it is asked for, once, plainly - and checked against the device
/// before anything is force-stopped.
String? requiredAppId(String? appId, Output output) {
  if (appId != null && appId.isNotEmpty) return appId;

  output
    ..line(output.red('--app-id is required.'))
    ..line(output.dim(
      '  It is the Android package this run drives, and the one it stops '
      'afterwards. `am force-stop` succeeds for a package that is not '
      'installed, so a wrong value leaves the real application running and '
      'breaks the next run.',
    ))
    ..line(output.dim(
      '  Find it with: adb shell pm list packages -3',
    ))
    ..line(output.dim(
      '  Or read applicationId in android/app/build.gradle[.kts], '
      'remembering any flavour or applicationIdSuffix the build adds.',
    ));
  return null;
}

/// Confirms a named device is actually attached.
///
/// Without this the first adb command fails deep inside a launch, and a
/// mistyped serial surfaces as a stack trace rather than as the simple
/// mistake it is.
Future<bool> verifyDevice(String serial, Output output) async {
  final devices = await _attached(output);
  if (devices == null) return false;

  if (devices.any((d) => d.serial == serial)) return true;

  output.line(output.red('No usable device with serial "$serial".'));
  if (devices.isEmpty) {
    output.line(output.dim('  Nothing is attached. Run: testsmith devices'));
  } else {
    output.line(output.dim('  Attached:'));
    for (final device in devices) {
      output.line(output.dim('    ${device.serial}  ${device.model}'));
    }
  }
  return false;
}
