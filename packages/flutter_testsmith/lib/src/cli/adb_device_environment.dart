import 'dart:io';

import 'package:flutter_testsmith/engine.dart';

/// Reads an Android device's environment through adb.
///
/// Every probe is deliberately narrow. `dumpsys connectivity` prints the
/// SSID, the BSSID, the MAC address and the IP of whatever the handset is
/// attached to; the grep runs **on the device**, so exactly one line -
/// `Active default network: 152` - ever crosses to the host, and nothing
/// a report could leak is ever in this process to begin with. Filtering
/// after the fact would be strictly weaker, for the same reason the SDK
/// redacts at capture time rather than at report time.
class AdbDeviceEnvironment implements DeviceEnvironment {
  /// [adbExecutable] defaults to whatever [resolveAdb] locates, matching
  /// [AdbDeviceController]. The two must not disagree: they address the
  /// same handset, and two adb versions on one machine run two servers.
  AdbDeviceEnvironment({
    required this.serial,
    // Bounded as the controller's queries are: a probe that hangs has
    // learned nothing, and answers so below.
    this.processRunner =
        const SystemProcessRunner(timeout: AdbDeviceController.commandTimeout),
    String? adbExecutable,
  }) : adbExecutable = adbExecutable ?? resolveAdb().executableOrBareName;

  final String serial;
  final ProcessRunner processRunner;
  final String adbExecutable;

  /// The command's output, or null when the command did not run.
  ///
  /// The exit code used to be discarded, which turned every device fault
  /// into empty output - and empty output is a perfectly good answer to
  /// most of these questions. An offline or unauthorised handset made
  /// `pm list packages` exit 1 with `error: device offline` on stderr,
  /// and the probe read the empty stdout and reported that the
  /// application was not installed. A claim about somebody's application,
  /// made from a question that was never asked.
  Future<String?> _shell(String command) async {
    final ProcessResultData result;
    try {
      result = await processRunner.run(
        adbExecutable,
        ['-s', serial, 'shell', command],
      );
    } on ProcessException {
      // adb is not on the PATH. Still "could not ask", and still not
      // something to crash a preflight over.
      return null;
    } on ProcessTimeoutException {
      // Asked, and never answered: also "could not ask".
      return null;
    }
    return result.succeeded ? result.stdout : null;
  }

  @override
  Future<bool?> isInstalled(String appId) async {
    // `pm list packages <id>` matches on prefix, so a flavoured sibling
    // - com.example.app.business beside com.example.app - would answer
    // for it. The line is matched exactly instead.
    final output = await _shell('pm list packages $appId');
    if (output == null) return null;

    return output
        .split('\n')
        .map((line) => line.trim())
        .contains('package:$appId');
  }

  @override
  Future<Map<String, bool>?> runtimePermissions(String appId) async {
    final output = await _shell('dumpsys package $appId');
    return output == null ? null : parseRuntimePermissions(output);
  }

  @override
  Future<NetworkInterfaceState> networkInterface() async {
    try {
      final output = await _shell(
        "dumpsys connectivity | grep -E '^Active default network'",
      );
      // Already the rule here, and now it is the rule everywhere: a probe
      // that could not run has learned nothing.
      if (output == null) return NetworkInterfaceState.unknown;
      return parseActiveDefaultNetwork(output);
    } on Object {
      // Unknown, never down. A probe that could not run has learned
      // nothing about the interface, and blocking a suite over that
      // would be reporting a fact nobody established.
      return NetworkInterfaceState.unknown;
    }
  }
}
