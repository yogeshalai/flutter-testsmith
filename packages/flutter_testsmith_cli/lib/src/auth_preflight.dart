import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Answers "could this machine authenticate?" before it tries to.
///
/// Composed from E-04's pure check functions rather than inheriting
/// `PreflightRunner`, which is built around a `SuiteFile`. An auth file
/// is not a suite, and pretending it is would be worse than composing.
///
/// Two differences from a suite's preflight, both deliberate: there is
/// no mock API, because auth setup serves no fixtures and talks to the
/// real backend; and that backend is **deferred** rather than probed.
class AuthPreflightRunner {
  const AuthPreflightRunner({
    required this.file,
    required this.projectDirectory,
    required this.profile,
    required this.deviceEnvironment,
    required this.attachedDevices,
    required this.requestedSerial,
    required this.deviceFacts,
    required this.flutterOnPath,
    this.adbProblem,
    this.adbRemedy = '',
  });

  final AuthFile file;
  final Directory projectDirectory;
  final DeviceProfile profile;
  final DeviceEnvironment deviceEnvironment;
  final List<AdbDevice> attachedDevices;
  final String? requestedSerial;
  final DeviceFacts deviceFacts;
  final bool flutterOnPath;

  /// Why the device list could not be obtained, or null when it was.
  final String? adbProblem;

  /// What to do about [adbProblem].
  final String adbRemedy;

  Future<PreflightReport> run() async {
    final target = file.app.target;
    final targetExists =
        target == null || File('${projectDirectory.path}/$target').existsSync();

    final device = checkDeviceAttached(
      attached: attachedDevices,
      requested: requestedSerial,
      adbProblem: adbProblem,
      adbRemedy: adbRemedy,
    );
    final profileMatch =
        checkProfileMatch(profile: profile, facts: deviceFacts);

    // Only read the handset once it is established to be the right
    // handset. Reading the wrong one would answer a question nobody
    // asked, and the two checks above are pure, so the gate costs
    // nothing - E-04's rule for granting, applied to reading.
    final readable = !device.isBlocking && !profileMatch.isBlocking;

    final granted = readable
        ? await deviceEnvironment.runtimePermissions(file.appId)
        : const <String, bool>{};
    final network = readable
        ? await deviceEnvironment.networkInterface()
        : NetworkInterfaceState.unknown;

    return PreflightReport([
      checkAppBuild(
        target: target,
        targetExists: targetExists,
        flutterOnPath: flutterOnPath,
      ),
      device,
      profileMatch,
      checkPermissions(
        appId: file.appId,
        required: file.devicePermissions,
        granted: granted,
      ),
      checkNetworkInterface(network),
      _checkBackend(),
    ]);
  }

  /// The one external service this platform ever addresses.
  ///
  /// Deferred rather than probed. A probe from the host would be a
  /// network call the platform otherwise never makes, and it would
  /// establish only that the *host* can reach the backend - not the
  /// device, which is what matters. A backend that is not there surfaces
  /// as AUTH_REQUEST_FAILED, from the application's own attempt, which
  /// is the honest place for it to surface.
  PreflightCheck _checkBackend() => const PreflightCheck.deferred(
        'authentication backend',
        klass: PrerequisiteClass.externalService,
        detail: 'the build being launched signs in against a real backend; '
            'whether it answered is knowable only from the application own '
            'request, and is reported as the setup result',
      );
}
