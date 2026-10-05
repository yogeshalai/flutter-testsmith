import 'dart:async';
import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'app_session.dart';
import 'mock_api_server.dart';

/// The fixture server could not take the port it was asked for.
///
/// Its own type so the command can say what `suite run` says. Left as a
/// bare `SocketException` it was reported as "Smoke run failed:", and
/// the command could not tell it apart from a socket error the VM
/// service connection raises later in the same run.
class FixtureServerException implements Exception {
  const FixtureServerException(this.reason);

  /// What the bind said, rendered as detail rather than as the headline.
  final String reason;

  @override
  String toString() => 'FixtureServerException: $reason';
}

/// Result of a smoke run, so the command reports rather than asserts.
class SmokeResult {
  SmokeResult({
    required this.handshake,
    required this.manager,
    required this.recoveredCount,
    required this.streamedCount,
    this.settledApp,
    this.snapshot,
    this.tappedPoint,
    this.tapError,
    this.correlation,
  });

  final HandshakeResponse handshake;
  final SessionManager manager;

  /// Events recovered from the SDK ring buffer via the handshake.
  final int recoveredCount;

  /// Events that arrived live on the VM Service stream.
  final int streamedCount;

  /// App context re-read once the UI settled.
  ///
  /// The handshake happens before the first frame, when the Android view
  /// still reports a placeholder devicePixelRatio. See risk R3b.
  final AppContext? settledApp;

  /// The UI tree captured before the interaction.
  final UiSnapshot? snapshot;

  final PhysicalPoint? tappedPoint;
  final Object? tapError;

  /// Per-screen sessions with their API exchanges attributed.
  final CorrelationResult? correlation;
}

/// Exercises the full channel against a real device.
class SmokeRunner {
  SmokeRunner({
    required this.projectDirectory,
    required this.outputDirectory,
    required this.deviceSerial,
    required this.stdout,
    required this.appId,
    this.tapId,
    this.tapPoint,
    this.mockApiPort,
    this.mockApiScenario,
    this.target,
    this.flavor,
  });

  final Directory projectDirectory;

  /// Where the screenshots go.
  ///
  /// Passed in already resolved. It used to be the literal `out/`, which
  /// meant a smoke run scattered `smoke-*.png` into whichever directory
  /// it happened to be started from - the only output path in the CLI
  /// that could not even be redirected.
  final Directory outputDirectory;

  final String deviceSerial;
  final void Function(String) stdout;

  /// Semantic id to tap. Preferred over [tapPoint].
  final String? tapId;

  /// Raw physical point, for driving a screen with no test ids.
  final PhysicalPoint? tapPoint;

  /// The Android package. What `am force-stop` addresses at teardown.
  ///
  /// Required, and deliberately not defaulted. It used to default to this
  /// repository's own example, `com.example.ecommerce_app`, which meant a
  /// run against anybody else's application force-stopped a package that
  /// was not installed - an operation Android reports as success - and
  /// left the real application running for the next run to inherit.
  final String appId;

  /// Port to serve the fixture API on, mapped into the device.
  final int? mockApiPort;

  /// What that port serves, already read and resolved. Required with
  /// [mockApiPort].
  ///
  /// Passed in rather than read here, because reading it here came after
  /// the device and Flutter checks: a scenario that would not parse was
  /// hidden behind whatever the machine lacked, then reported as a smoke
  /// run that had failed. The command resolves it first, as `run` does.
  final ApiScenario? mockApiScenario;

  /// Entry point, when the app is not `lib/main.dart`.
  final String? target;

  /// Build flavor, for an app that has them.
  final String? flavor;

  Future<void> _saveScreenshot(DeviceController device, String label) async {
    try {
      final bytes = await device.screenshot();
      final file = File('${outputDirectory.path}/smoke-$label.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      stdout('  saved ${file.path} (${bytes.length} bytes)');
    } catch (error) {
      stdout('  ! could not capture $label screenshot: $error');
    }
  }

  Future<SmokeResult> run() async {
    MockApiServer? mockApi;
    final port = mockApiPort;
    if (port != null) {
      final scenario = mockApiScenario;
      if (scenario == null) {
        throw StateError('mockApiPort was given without mockApiScenario.');
      }

      // Only the bind is in question here: the scenario was resolved
      // before anything was started.
      try {
        mockApi = await MockApiServer.start(scenario: scenario, port: port);
      } on Object catch (error) {
        // Typed, because the command above renders it and a bare
        // SocketException there would be indistinguishable from one the
        // VM service connection raised later in the same run. The
        // runner does not format: that is the command's job.
        //
        // Nothing to close - the server never started - and the
        // `finally` that closes a running one is below, guarding the
        // session it is paired with.
        throw FixtureServerException('$error');
      }
      stdout('› mock API on http://127.0.0.1:${mockApi.port}');
    }

    // The server is this runner's: it started it, so it closes it, on
    // every way out - including a launch that throws, which used to leave
    // it listening. The session is the session's own: a launch that
    // throws has already torn down what it set up, so there is nothing
    // of it to dispose here, and it is disposed only once it exists.
    AppSession? session;
    try {
      session = await AppSession.launch(
        projectDirectory: projectDirectory,
        deviceSerial: deviceSerial,
        appId: appId,
        // The port the server bound, as `FlowRunner` maps it: `port` is
        // only what was asked for, and `0` asks the host to choose. The
        // session removes this same mapping at teardown.
        reversePort: mockApi?.port,
        target: target,
        flavor: flavor,
        log: stdout,
      );

      final recovered = session.handshake.bufferedEvents.length;

      // Let the first frame settle before touching anything: tapping a
      // half-built screen lands on nothing and reads as a broken tap.
      await Future<void>.delayed(const Duration(seconds: 3));

      UiSnapshot? snapshot;
      try {
        snapshot = await session.captureUiTree();
        stdout('› captured UI tree: ${snapshot.retainedNodeCount} nodes '
            'from ${snapshot.totalElementsWalked} elements');
      } catch (error) {
        stdout('  ! could not capture the UI tree: $error');
      }

      await _saveScreenshot(session.device, 'before-tap');

      PhysicalPoint? tapped;
      Object? tapError;
      try {
        final id = tapId;
        final point = tapPoint;
        if (id != null) {
          stdout('› tapping "$id"');
          tapped = await session.tapById(id);
          stdout('  resolved to $tapped');
        } else if (point != null) {
          stdout('› tapping $point');
          await session.device.tap(point);
          tapped = point;
        }
      } catch (error) {
        tapError = error;
        stdout('  ! tap failed: $error');
      }

      if (tapped != null) {
        await Future<void>.delayed(const Duration(seconds: 3));
        await _saveScreenshot(session.device, 'after-tap');
      }

      return SmokeResult(
        handshake: session.handshake,
        manager: session.manager,
        recoveredCount: recovered,
        streamedCount: session.streamedCount,
        settledApp: await session.readSettledContext(),
        snapshot: snapshot,
        tappedPoint: tapped,
        tapError: tapError,
        correlation: session.correlate(),
      );
    } finally {
      await session?.dispose();
      await mockApi?.close();
    }
  }
}
