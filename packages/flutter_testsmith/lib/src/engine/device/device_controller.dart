import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../secrets/secret_ref.dart';
import 'coordinates.dart';

/// What a device reports about itself.
@immutable
class DeviceInfo {
  const DeviceInfo({
    required this.serial,
    required this.model,
    required this.androidVersion,
    required this.screenWidth,
    required this.screenHeight,
    required this.density,
  });

  final String serial;
  final String model;
  final String androidVersion;
  final int screenWidth;
  final int screenHeight;

  /// Screen density in dpi. The Flutter device pixel ratio is roughly
  /// `density / 160`, but the authoritative value comes from the SDK
  /// handshake rather than from here.
  final int density;

  @override
  String toString() =>
      'DeviceInfo($model, Android $androidVersion, '
      '${screenWidth}x$screenHeight @ ${density}dpi)';
}

/// A command sent to a device failed.
@immutable
class DeviceCommandException implements Exception {
  const DeviceCommandException({
    required this.command,
    required this.exitCode,
    required this.stderr,
  });

  final String command;
  final int exitCode;
  final String stderr;

  @override
  String toString() => 'DeviceCommandException: `$command` exited with '
      '$exitCode${stderr.isEmpty ? '' : '\n$stderr'}';
}

/// The tool that drives devices could not be started at all.
///
/// Deliberately not [DeviceCommandException], which reports a command
/// that ran and came back non-zero. This one never ran: there is no exit
/// code and no stderr to quote, and only one of the two names something
/// to go and install. Collapsing them would report a missing adb as a
/// device that refused, which is a fact about somebody's handset rather
/// than about their machine.
@immutable
class DeviceUnavailableException implements Exception {
  const DeviceUnavailableException({required this.tool, this.hint = ''});

  /// The file name, never the directory it was looked for in.
  ///
  /// This message reaches `StepOutcome.detail`, and from there
  /// `result.json` and `report.html`, where an absolute path would put a
  /// fact about a workstation into a committed artefact. The rule
  /// `AdbDeviceController` already applies to its own failures.
  final String tool;

  final String hint;

  @override
  String toString() => '$tool could not be started: it is not installed, or '
      'not where it was looked for.${hint.isEmpty ? '' : '\n$hint'}';
}

/// A command sent to a device ran, and never finished.
///
/// The third way an adb command goes wrong, beside the two above: it
/// started, so adb is installed, and it never came back, so there is no
/// exit code to report. A wedged adb server and a handset in a bad USB
/// state both look like this, and both are remedied the same way.
@immutable
class DeviceTimeoutException implements Exception {
  const DeviceTimeoutException({
    required this.command,
    required this.timeout,
    required this.stopped,
  });

  /// As [DeviceCommandException.command]: the file name and the
  /// arguments the caller allowed to be shown, never a typed secret.
  final String command;

  final Duration timeout;

  /// Whether the command was seen to exit after it was killed.
  final bool stopped;

  @override
  String toString() => 'DeviceTimeoutException: `$command` did not finish '
      'within ${timeout.inSeconds} seconds'
      '${stopped ? ', and was stopped' : ', and could not be stopped'}.\n'
      'The device or the adb server stopped answering. Reconnect the '
      'device, or run `adb kill-server`, and try again.';
}

/// Controls a device or emulator.
///
/// An interface so that Android, iOS and in-process desktop or web
/// implementations can coexist. Nothing above this layer knows about adb.
abstract interface class DeviceController {
  Future<DeviceInfo> info();

  Future<void> terminateApp(String appId);

  Future<Uint8List> screenshot();

  Future<void> tap(PhysicalPoint point);

  /// Clears the application's stored state, as a fresh install would be.
  ///
  /// Only ever called because a suite declared it for a particular test.
  /// Nothing calls this between every test: that would make each test's
  /// preconditions invisible and would spend the suite's life
  /// re-signing-in.
  Future<void> clearAppState(String appId);

  /// Grants a runtime permission to the application.
  ///
  /// Needed after [clearAppState], which also revokes whatever the user
  /// had granted. The system's permission dialog is then drawn over the
  /// application, and a tap meant for a button lands on the dialog - a
  /// failure that looks like the application ignoring input.
  Future<void> grantPermission(String appId, String permission);

  Future<void> longPress(PhysicalPoint point, Duration hold);

  Future<void> swipe(PhysicalPoint from, PhysicalPoint to, Duration duration);

  Future<void> inputText(String text);

  /// Whether the platform is ready to receive typed text.
  ///
  /// Android raises its input method when a field takes focus, and
  /// reports that as `mInputShown` in `dumpsys input_method`. That is an
  /// *observable* condition, which is the whole point: a tap returns as
  /// soon as the event is dispatched, not when the field has focus, and
  /// text sent into that gap is partly swallowed.
  ///
  /// Measured on a Samsung SM-M127G against a real login screen: typing
  /// "9000000001" immediately after the tap put "000000001" in the
  /// field. One character, silently, every time.
  Future<bool> isTextInputReady();

  /// Types a credential into the focused field.
  ///
  /// Separate from [inputText] rather than a flag on it, because the
  /// value must not reach [DeviceCommandException], whose message
  /// renders the command it ran. A flag would leave the leaking path one
  /// forgotten `false` away.
  Future<void> inputSecret(Secret secret);

  Future<void> pressBack();

  /// Makes a host port reachable from the device.
  ///
  /// A physical device has no equivalent of the emulator's 10.0.2.2, so a
  /// mock API server running on the host is unreachable without this.
  Future<void> reversePort(int hostPort, int devicePort);

  /// Removes a mapping [reversePort] created.
  ///
  /// Symmetric with it, and called from the same place. Without this a
  /// finished run leaves the device forwarding a port to a host that has
  /// stopped listening - state one run leaves behind for the next, and a
  /// run whose behaviour depends on whether a previous run happened is
  /// not a deterministic run.
  Future<void> removeReversePort(int devicePort);

  /// Wakes and unlocks the screen.
  ///
  /// Physical devices sleep and lock mid-run; without this a test fails as
  /// an inscrutable tap timeout rather than as a locked device.
  Future<void> wake();
}
