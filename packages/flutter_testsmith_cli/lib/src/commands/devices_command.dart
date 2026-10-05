import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

import '../device_selection.dart';
import '../output.dart';

/// Lists devices that are actually usable for a test run.
class DevicesCommand extends Command<int> {
  @override
  String get name => 'devices';

  @override
  String get description => 'List attached Android devices and emulators.';

  @override
  Future<int> run() async {
    final output = Output();
    final adb = resolveAdb();
    if (!adb.isFound) {
      // Named and not there, or nothing runnable anywhere: the resolver's
      // own sentence either way, as `doctor` and `preflight` say it.
      // Running whatever the operating system finds instead would, for a
      // named adb, answer with a different adb's devices; for no adb at
      // all it finds nothing the resolver missed, and used to report the
      // failure as "could not be started". See `_attached` in
      // device_selection.dart.
      output
        ..line(output.red(adb.problem!))
        ..line(output.dim('  ${adb.hint}'));
      return 1;
    }

    final ProcessResultData result;
    try {
      result = await const SystemProcessRunner(
        timeout: AdbDeviceController.commandTimeout,
      ).run(
        adb.executable!,
        const ['devices', '-l'],
      );
    } on ProcessTimeoutException catch (error) {
      output
        ..line(output.red(
          'adb did not answer within ${error.timeout.inSeconds} seconds.',
        ))
        ..line(output.dim(adbUnresponsiveHint));
      return 1;
    } on ProcessException {
      // Found, and would not launch. "I could not ask" is not "nothing is
      // attached", and used to be an unhandled exception rather than
      // either.
      output
        ..line(output.red('adb could not be started.'))
        ..line(output.dim('  ${adb.hint.isEmpty ? 'Install the Android '
            'platform-tools and put adb on PATH, or set MYTEST_ADB to the '
            'executable.' : adb.hint}'));
      return 1;
    }

    final devices = parseAdbDevices(result.stdout);

    if (devices.isEmpty) {
      output
        ..line(output.yellow('No usable devices attached.'))
        ..line(
          output.dim(
            'Attach a device with USB debugging enabled, or start an '
            'emulator. Devices reported as unauthorized or offline are '
            'not listed here, because using one fails confusingly later.',
          ),
        );
      return 1;
    }

    output.line(output.bold('Devices'));
    for (final device in devices) {
      final kind = device.isEmulator ? 'emulator' : 'physical';
      output.line(
        '  ${output.green(device.serial)}  ${device.model} '
        '${output.dim('($kind)')}',
      );
    }
    return 0;
  }
}
