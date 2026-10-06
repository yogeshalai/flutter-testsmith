import 'preflight_checks.dart';

/// What a device can be *asked about itself*, without being driven.
///
/// Separate from [DeviceController] on purpose: that interface exists to
/// make a device do something, and this one exists to read what is
/// already true. Preflight needs only the second, and keeping them apart
/// is what lets every orchestration test run against a fake that cannot
/// touch hardware at all.
///
/// Nothing here reads the application's own storage. Sign-in state is
/// deliberately absent: the only ways to learn it early are to read what
/// the application wrote - which proves merely that something was
/// written - or to write it, which is the bypass this platform refuses.
abstract interface class DeviceEnvironment {
  /// Whether [appId] is installed, or null when the device would not say.
  ///
  /// Three answers, and the third is not a shade of the second. "It is
  /// not there" is a finding about an application; "I could not ask" is a
  /// finding about a handset, and the remedies point in opposite
  /// directions - one says install your app, the other says your device
  /// is offline.
  ///
  /// Measured: an offline or unauthorised device makes `adb shell pm list
  /// packages` exit non-zero with empty stdout, which read as "no such
  /// package" for as long as the exit code was discarded.
  Future<bool?> isInstalled(String appId);

  /// The application's runtime permissions, and whether each is granted.
  ///
  /// A permission the application does not declare is **absent** from the
  /// map rather than present and false: `pm grant` fixes the second and
  /// cannot fix the first, so reporting them alike would offer a remedy
  /// that does not work.
  ///
  /// Null for the same reason [isInstalled] is: a table nobody could read
  /// is not a table of denials.
  Future<Map<String, bool>?> runtimePermissions(String appId);

  /// Whether the device has an active default network.
  Future<NetworkInterfaceState> networkInterface();
}

/// Reads the runtime permission lines out of `adb shell dumpsys package`.
///
/// Matches the `<permission>: granted=<bool>` form wherever it appears, so
/// it does not depend on the surrounding section headings, which differ
/// between Android versions.
Map<String, bool> parseRuntimePermissions(String dumpsys) {
  final permissions = <String, bool>{};
  final pattern = RegExp(
    r'^\s*([A-Za-z][\w.]*\.[A-Z_0-9]+)\s*:\s*granted=(true|false)',
  );

  for (final line in dumpsys.split('\n')) {
    final match = pattern.firstMatch(line);
    if (match == null) continue;
    permissions[match.group(1)!] = match.group(2) == 'true';
  }
  return permissions;
}

/// Reads `Active default network: <id>` as a connectivity state.
///
/// This is the signal `connectivity_plus` reads - the platform's active
/// default network - and not anything about a backend. A device with an
/// interface up and nothing reachable on it is `up` here, which is exactly
/// right: the application draws its no-connection view from this signal
/// and from nothing else.
///
/// Anything unreadable is [NetworkInterfaceState.unknown] rather than
/// down, for the same reason a device profile treats an unreported fact as
/// agreement: a probe that failed has learned nothing.
NetworkInterfaceState parseActiveDefaultNetwork(String output) {
  final match = RegExp(r'Active default network:\s*(\S+)').firstMatch(output);
  if (match == null) return NetworkInterfaceState.unknown;

  final value = match.group(1)!;
  if (value == 'null' || value == 'none') return NetworkInterfaceState.down;
  if (int.tryParse(value) != null) return NetworkInterfaceState.up;
  return NetworkInterfaceState.unknown;
}
