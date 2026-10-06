import 'package:meta/meta.dart';

enum CheckStatus { pass, warn, fail }

/// One environment check.
///
/// A failure must carry a [remedy]. A doctor that reports "adb not found"
/// without saying what to do about it is only a slower error message.
@immutable
class DoctorCheck {
  const DoctorCheck._(
    this.name,
    this.status, {
    this.detail = '',
    this.remedy = '',
  });

  const DoctorCheck.pass(String name, {String detail = ''})
      : this._(name, CheckStatus.pass, detail: detail);

  const DoctorCheck.warn(String name, {String detail = '', String remedy = ''})
      : this._(name, CheckStatus.warn, detail: detail, remedy: remedy);

  const DoctorCheck.fail(
    String name, {
    String detail = '',
    required String remedy,
  }) : this._(name, CheckStatus.fail, detail: detail, remedy: remedy);

  final String name;
  final CheckStatus status;
  final String detail;
  final String remedy;

  /// Only a failure stops work. A warning is information, and treating it
  /// as an error trains people to ignore both.
  bool get isBlocking => status == CheckStatus.fail;
}

/// The outcome of every environment check.
@immutable
class DoctorReport {
  const DoctorReport(this.checks);

  final List<DoctorCheck> checks;

  List<DoctorCheck> get failures =>
      [for (final c in checks) if (c.status == CheckStatus.fail) c];

  int get passCount => _count(CheckStatus.pass);
  int get warnCount => _count(CheckStatus.warn);
  int get failCount => _count(CheckStatus.fail);

  bool get isHealthy => failCount == 0;

  int get exitCode => isHealthy ? 0 : 1;

  int _count(CheckStatus status) =>
      checks.where((c) => c.status == status).length;
}

/// A device visible to adb.
@immutable
class AdbDevice {
  const AdbDevice({
    required this.serial,
    required this.model,
    required this.state,
  });

  final String serial;
  final String model;
  final String state;

  bool get isEmulator => serial.startsWith('emulator-');

  @override
  String toString() => '$serial ($model)';
}

/// Parses `adb devices -l` output.
///
/// Devices that are not in the `device` state - unauthorised, offline,
/// still booting - are omitted, because attempting to use one produces a
/// confusing failure much later.
List<AdbDevice> parseAdbDevices(String output) {
  final devices = <AdbDevice>[];

  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('List of devices')) continue;

    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2 || parts[1] != 'device') continue;

    final modelToken = parts.firstWhere(
      (p) => p.startsWith('model:'),
      orElse: () => '',
    );

    devices.add(
      AdbDevice(
        serial: parts[0],
        model: modelToken.isEmpty
            ? 'unknown model'
            : modelToken.substring('model:'.length),
        state: parts[1],
      ),
    );
  }

  return devices;
}
