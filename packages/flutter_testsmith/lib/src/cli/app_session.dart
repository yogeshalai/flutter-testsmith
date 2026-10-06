import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/protocol.dart';

import 'adb_device_environment.dart';

/// `flutter run` could not be started at all.
///
/// Raised for a flutter that was found and that the operating system
/// would not run - a damaged install, a file without its executable bit.
/// Named by file only, as `DeviceUnavailableException` names adb: this
/// text reaches `suite.json`, `suite.html` and the auth artefact, where
/// the absolute path and command line the system's own exception carried
/// would put a workstation, and every `--dart-define`, into a committed
/// file.
class FlutterStartException implements Exception {
  const FlutterStartException({required this.tool, required this.reason});

  /// The file name, never the directory it was found in.
  final String tool;

  /// What the operating system said, without the VM's source location.
  final String reason;

  @override
  String toString() => '$tool could not be started: $reason\n'
      'Check that `flutter --version` runs from this shell.';
}

/// A launched, attached application, ready to be driven.
///
/// Extracted so `smoke` and `inspect` share one launch path: the launch,
/// attach and teardown sequence has enough sharp edges - a daemon that
/// survives kill, subscriptions that keep the event loop alive - that
/// having two copies of it would guarantee they drift.
class AppSession {
  AppSession._({
    required this.device,
    required this.transport,
    required this.manager,
    required this.handshake,
    required this._shutdown,
    required this._streamedCount,
  });

  final DeviceController device;
  final SdkTransport transport;
  final SessionManager manager;
  final HandshakeResponse handshake;
  final Future<void> Function() _shutdown;

  final int Function() _streamedCount;

  /// Events that arrived live, as opposed to via the handshake drain.
  int get streamedCount => _streamedCount();

  static Future<AppSession> launch({
    required Directory projectDirectory,
    required String deviceSerial,
    required String appId,
    required void Function(String) log,
    int? reversePort,
    List<String> dartDefines = const [],
    String? target,
    String? flavor,
    Duration launchTimeout = const Duration(minutes: 8),

    /// What the device is asked about itself. Injected only so the
    /// package check below can be driven without hardware.
    DeviceEnvironment? deviceEnvironment,

    /// Which flutter to launch with.
    ///
    /// Defaults to whatever [resolveFlutter] locates on PATH, so every
    /// production caller gets the same executable without threading one
    /// through four call sites. A test that names one still wins: the
    /// resolver is consulted only when nothing was passed. This is the
    /// same arrangement [AdbDeviceController] uses for adb.
    String? flutterExecutable,
  }) async {
    final flutter = flutterExecutable ?? resolveFlutter().executableOrBareName;
    final device = AdbDeviceController(serial: deviceSerial);
    final environment =
        deviceEnvironment ?? AdbDeviceEnvironment(serial: deviceSerial);

    /// Whether [appId] was confirmed to be on the device.
    ///
    /// Teardown force-stops only what this confirms. `am force-stop`
    /// succeeds for a package that is not installed, so issuing it
    /// unconfirmed produces a command that reports success, stops
    /// nothing, and leaves the real application running for the next run
    /// to inherit - which is E-03, exactly.
    var packageConfirmed = false;

    log('› waking device $deviceSerial');
    await device.wake();

    if (reversePort != null) {
      // A physical device has no equivalent of the emulator's 10.0.2.2,
      // so the host port is mapped into the device before launch.
      await device.reversePort(reversePort, reversePort);
      log('› adb reverse tcp:$reversePort -> host');
    }

    log('› launching app (this builds the APK on first run)');
    // The mapping above is undone by `shutdown`, which needs the process
    // and so does not exist until it has started. A start that throws -
    // a flutter that is there and will not run - used to leave the
    // device forwarding a port to a host that had stopped listening:
    // state on the handset, outliving this process, for the next run to
    // inherit. Undone here instead, and without letting a failure to
    // undo it replace the reason the start failed.
    var started = false;
    final Process process;
    try {
      process = await startProcess(
        flutter,
        [
          'run',
          '--machine',
          '-d',
          deviceSerial,
          // A real application is rarely `lib/main.dart` with no flavor.
          // The app this was first validated against externally has six
          // entry points and five Android product flavors, and without
          // these two the runner could not launch it at all.
          if (target != null) ...['-t', target],
          if (flavor != null) ...['--flavor', flavor],
          '--dart-define=TEST_MODE=true',
          for (final define in dartDefines) '--dart-define=$define',
        ],
        workingDirectory: projectDirectory.path,
      );
      started = true;
    } on ProcessException catch (error) {
      // The operating system's text is the executable's absolute path,
      // every argument and the VM's source location, and `suite run`
      // and `auth setup` record a launch's error in their artefacts. The
      // file name and the system's reason are what the reader needs.
      throw FlutterStartException(
        tool: flutter.substring(flutter.lastIndexOf(RegExp(r'[/\\]')) + 1),
        reason: error.message
            .replaceFirst(RegExp(r'\s*\(at [^)]*\)\s*$'), '')
            .trim(),
      );
    } finally {
      if (!started && reversePort != null) {
        try {
          await device.removeReversePort(reversePort);
        } catch (error) {
          log('  ! could not remove the adb reverse: $error');
        }
      }
    }

    final runSession = FlutterRunSession();
    // The newest lines only: a build can write to stderr for as long as
    // it runs, and only what came last is likely to be the reason.
    final stderrLines = <String>[];
    void keepStderr(String line) {
      stderrLines.add(line);
      if (stderrLines.length > 50) stderrLines.removeAt(0);
    }

    // Why the launch failed, from everything flutter said: its protocol
    // events first, where `--machine` puts most reasons, then any stderr
    // line they do not already say. A `--dart-define` value never
    // appears - this text reaches `suite.json` and the auth artefact, the
    // rule `FlutterStartException` keeps. Values under four characters
    // are left alone: scrubbing every `1` or `dev` would garble the
    // message and hide nothing anybody would call a secret.
    String failureDetail() {
      final reasons = runSession.failureReasons;
      final extra = [
        for (final line in stderrLines)
          if (line.trim().isNotEmpty &&
              !reasons.any((reason) => reason.contains(line.trim())))
            line,
      ];
      var text = [
        if (reasons.isNotEmpty)
          'flutter reported:\n${[for (final r in reasons) '  $r'].join('\n')}',
        if (extra.isNotEmpty) 'stderr:\n${extra.join('\n')}',
      ].join('\n');
      for (final define in dartDefines) {
        final cut = define.indexOf('=');
        final value = cut < 0 ? '' : define.substring(cut + 1);
        if (value.length >= 4) text = text.replaceAll(value, redactionMarker);
      }
      return text;
    }
    final stdoutDrained = Completer<void>();
    final stderrDrained = Completer<void>();

    // Watched from here on, because nothing else was. A `flutter run`
    // that ends before the app is ready - a Gradle failure, a flavour that
    // does not exist, an entry point that does not compile - used to be
    // waited on for the whole launch timeout and then reported as slow.
    int? exitedWith;
    final exited = process.exitCode.then((code) => exitedWith = code);

    // Held so they can be cancelled: an outstanding subscription on a
    // child's stdout keeps the Dart event loop alive indefinitely.
    final stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(runSession.consume, onDone: stdoutDrained.complete);
    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(keepStderr, onDone: stderrDrained.complete);

    // Teardown must never throw over the failure that caused it. When a
    // run fails because the device vanished, every cleanup step fails
    // too - and an exception from one of those replaces the real cause
    // with a confusing one. Each step is attempted, and any problem is
    // reported rather than raised.
    Future<void> shutdown() async {
      Future<void> attempt(String what, Future<void> Function() action) async {
        try {
          await action();
        } catch (error) {
          log('  ! could not $what during shutdown: $error');
        }
      }

      await attempt('stop reading stdout', stdoutSubscription.cancel);
      await attempt('stop reading stderr', stderrSubscription.cancel);
      await attempt('stop flutter run', () async {
        // Nothing to stop once it has exited - and on Windows its pid may
        // already name some other process, which a tree kill would end.
        if (exitedWith != null) return;
        // `flutter run` is a daemon with its own children; a plain kill
        // leaves it running and holding the device.
        //
        // On Windows the process started is `cmd.exe` running
        // `flutter.bat`, and flutter_tools is its child: there is no
        // `exec` to put it in the shell's place, as `bin/flutter` does
        // elsewhere. Killing the one process left `flutter run` running
        // with the device, so the tree is ended - the rule a bounded adb
        // call uses, from the same function.
        await killProcessTree(process);
        await process.exitCode
            .timeout(const Duration(seconds: 10), onTimeout: () => -1);
      });
      if (packageConfirmed) {
        await attempt('stop the app', () => device.terminateApp(appId));
      } else {
        // Deliberately not attempted. The command would report success
        // whatever it was aimed at, and a teardown that says it stopped
        // an application it never identified is worse than one that says
        // it did not.
        log('  ! not stopping "$appId": it was not confirmed on the device');
      }
      if (reversePort != null) {
        // Undone where it was done. A run that ends leaving the device
        // forwarding a port to a host that has stopped listening has
        // left state behind for the next run to inherit.
        await attempt(
          'remove the adb reverse',
          () => device.removeReversePort(reversePort),
        );
      }
    }

    final Uri? readyAt;
    try {
      // Whichever comes first: the app, or the end of the process that
      // was to start it. A later result from the other is ignored.
      //
      // An exit can be seen before the last of stdout has been read, and
      // that last line may be the one saying the app started. So the
      // exit is only an answer once stdout is drained - bounded, as a
      // grandchild holding the pipe could otherwise hold it for ever.
      readyAt = await Future.any<Uri?>([
        runSession.onReady,
        exited.then((_) async {
          await stdoutDrained.future
              .timeout(const Duration(seconds: 2), onTimeout: () {});
          return runSession.isReady ? runSession.vmServiceUri : null;
        }),
      ]).timeout(launchTimeout);
    } on TimeoutException {
      await shutdown();
      throw StateError(
        'The app did not start within ${launchTimeout.inMinutes} minutes.\n'
        '${failureDetail()}',
      );
    }
    if (readyAt == null) {
      // Its last words are on stderr, which may still be arriving: the
      // exit can be seen before the pipe is drained. Bounded, so a
      // grandchild holding the pipe open cannot hold this open.
      await stderrDrained.future
          .timeout(const Duration(seconds: 2), onTimeout: () {});
      await shutdown();
      throw StateError(
        'flutter run exited with code $exitedWith before the app started.\n'
        '${failureDetail()}',
      );
    }
    final vmServiceUri = readyAt;

    // `runSession.appId` is the flutter daemon's own identifier for this
    // app instance - a fresh UUID - and never the Android package, which
    // is why the package is a parameter and is checked separately below.
    log('› app started (${runSession.appId})');
    log('› vm service at $vmServiceUri');

    // Asked here and not earlier: `flutter run` installs the application
    // on its way past, so before the app started "not installed" would
    // have been true of every first run and meant nothing. It is the
    // same reasoning `checkAppInstalled` already applies to a suite.
    //
    // Asked at all because nothing downstream can tell a right package
    // from a wrong one: every command aimed at a package that is not
    // there succeeds.
    // Three outcomes, not two. "It is not there" is a finding; "I could
    // not look" is not, and collapsing them would either fail runs over a
    // flaky adb or pass them over a package that does not exist.
    //
    // The third arrives as null from the probe itself, and that is the
    // whole reason it does: this check first shipped assuming an
    // unreadable device would throw, while `pm list packages` against an
    // offline handset exits non-zero with empty stdout - so the probe
    // returned false and this said "the device has no package X" about a
    // device that had said nothing at all.
    bool? installed;
    try {
      installed = await environment.isInstalled(appId);
    } on Object catch (error) {
      log('  ! could not check whether "$appId" is installed: $error');
    }
    if (installed == null) {
      log('  ! the device would not say whether "$appId" is installed');
    }
    packageConfirmed = installed ?? false;

    if (installed == false) {
      await shutdown();
      throw StateError(
        'The device has no package "$appId".\n'
        'The application was launched and is running, but that id names '
        'nothing installed - so every command aimed at it, including the '
        '`am force-stop` this run ends with, would report success and do '
        'nothing.\n'
        'Check it against: adb -s $deviceSerial shell pm list packages -3\n'
        'A flavour or an applicationIdSuffix changes the installed id, so '
        'it is often not the applicationId written in build.gradle.',
      );
    }

    final transport = VmServiceTransport(uri: vmServiceUri);
    final manager = SessionManager();

    // A plain counter, not a field on the session being constructed: DDS
    // replays buffered events during connect(), so this listener fires
    // before the AppSession exists.
    var streamed = 0;

    final subscription = transport.events.listen(
      (event) {
        streamed++;
        manager.ingest(event);
      },
      onError: (Object error) => log('  ! malformed event: $error'),
    );

    final HandshakeResponse handshake;
    try {
      handshake = await transport.connect();
    } catch (error) {
      await subscription.cancel();
      await transport.close();
      await shutdown();
      rethrow;
    }
    log('› handshake complete for session ${handshake.sessionId}');

    manager.ingestAll(handshake.bufferedEvents);

    return AppSession._(
      device: device,
      transport: transport,
      manager: manager,
      handshake: handshake,
      streamedCount: () => streamed,
      shutdown: () async {
        await subscription.cancel();
        await transport.close();
        await shutdown();
      },
    );
  }

  /// Re-reads the app context now that the UI has rendered.
  ///
  /// The handshake happens before the first frame, so its devicePixelRatio
  /// can be a placeholder. See risk R3b.
  Future<AppContext?> readSettledContext() async {
    try {
      final info = await transport.invoke('ext.mytest.sessionInfo');
      final raw = info['app'];
      if (raw is Map) return AppContext.fromJson(raw.cast<String, Object?>());
    } catch (_) {
      // Reported by the caller as "unavailable" rather than fatal.
    }
    return null;
  }

  /// One reading of what the screen is doing right now.
  Future<SettleReading> readSettle() async =>
      SettleReading.fromJson(await transport.invoke('ext.mytest.settle'));

  /// Waits until the screen has stopped changing.
  ///
  /// Polls rather than sleeping, and on timeout reports every condition
  /// that never became true - "not settled" alone leaves the author
  /// guessing. See risk R4b.
  ///
  /// [policy] is what the screen declared about animations it expects to
  /// run for ever. Without one this is exactly the check it always was.
  /// With one, the declared animations stop blocking and **nothing
  /// else** does: an animation nobody named still holds the screen, and
  /// the timeout now says which widget it is. See STOP-2.
  Future<QuiescenceVerdict> waitForSettle({
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 250),
    QuiescencePolicy Function()? policy,
  }) async {
    final verdict = await awaitQuiescence(
      timeout: timeout,
      pollInterval: pollInterval,
      policy: policy,
    );
    if (verdict.isSettled) return verdict;

    throw StateError(
      'the screen did not settle within ${timeout.inSeconds}s. Still '
      'waiting on: ${verdict.blockers.join('; ')}',
    );
  }

  /// The same wait, returning the last reading instead of throwing.
  ///
  /// For a caller that has something better to say than "timed out" -
  /// the visual comparison reports *why* it could not photograph the
  /// screen, on its own row, rather than aborting the flow.
  ///
  /// Polls rather than sampling once. A single reading taken a moment
  /// after a successful wait can disagree with it: measured on a real
  /// dashboard, `waitForSettle` returned and the very next read said a
  /// frame had rendered 335ms ago, because a network image had just
  /// arrived. That is the screen settling, not a screen that will not.
  Future<QuiescenceVerdict> awaitQuiescence({
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 250),
    QuiescencePolicy Function()? policy,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var last = (await readSettle()).against(
      policy?.call() ?? QuiescencePolicy.none,
    );

    while (!last.isSettled && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      // Re-read each time rather than once: the screen may still be
      // arriving, and the policy belongs to whichever screen is on.
      last = (await readSettle()).against(
        policy?.call() ?? QuiescencePolicy.none,
      );
    }

    return last;
  }

  /// Correlates everything seen so far into per-screen sessions.
  CorrelationResult correlate() =>
      const SessionCorrelator().correlateAll(manager);

  /// Captures the current screen's UI tree.
  Future<UiSnapshot> captureUiTree() async {
    final result = await transport.invoke('ext.mytest.uiTree');
    final raw = result['snapshot'];
    if (raw is! Map) {
      throw StateError('ext.mytest.uiTree returned no snapshot: $result');
    }
    return UiSnapshot.fromJson(raw.cast<String, Object?>());
  }

  /// Whether the application offers to rasterise its own surface.
  ///
  /// Read from the handshake rather than assumed: an older SDK, or one
  /// built with `enableScreenshots: false`, serves no such RPC and the
  /// runner must fall back rather than fail.
  bool get canCaptureSurface =>
      handshake.capabilities.contains('screenshot');

  /// Rasterises the Flutter surface, in the application's own process.
  ///
  /// Not the same picture as [DeviceController.screenshot]: no system
  /// bars, no platform views, exact logical geometry. See ADR-0010.
  Future<SurfaceScreenshot> captureSurface() async {
    final result = await transport.invoke('ext.mytest.screenshot');
    return SurfaceScreenshot.fromRpc(result);
  }

  /// Takes whichever picture [path] names.
  Future<({Uint8List bytes, ScreenshotSource source})> capture(
    CapturePath path,
  ) async {
    switch (path) {
      case CapturePath.screencap:
        return (bytes: await device.screenshot(), source: path.source);
      case CapturePath.surface:
        if (!canCaptureSurface) {
          throw StateError(
            'This build does not serve ext.mytest.screenshot, so a '
            '"surface" capture is not available. The app reports: '
            '${handshake.capabilities.join(', ')}. Rebuild with a '
            'flutter_testsmith that supports it, or set `capture: screencap`.',
          );
        }
        return (bytes: (await captureSurface()).bytes, source: path.source);
    }
  }

  /// Taps the element with [testId].
  ///
  /// Captures a fresh tree first, so bounds and pixel ratio come from the
  /// same read and cannot be stale after an animation.
  ///
  /// Retries until the element is actually tappable. On a cold start it
  /// is in the tree before it has been laid out, so its bounds are zero
  /// for a moment; a single capture turns that into a failure on
  /// whichever machine happens to be slowest.
  /// Focuses [testId] and returns only once text can actually be typed.
  ///
  /// A tap returns when the event is dispatched, not when the field has
  /// focus and the platform is ready to receive characters. Typing into
  /// that gap loses the leading characters - measured on a Samsung
  /// SM-M127G, where "9000000001" arrived as "000000001".
  ///
  /// The wait is on an observable condition, never a fixed sleep: the
  /// platform is polled until it reports itself ready. A field that
  /// never becomes ready is a deterministic error naming the element,
  /// not a silently truncated value.
  Future<void> focusForInput(
    String testId, {
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 100),
  }) async {
    await tapById(testId, timeout: timeout);

    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await device.isTextInputReady()) return;
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError(
          'tapped "$testId" but the platform never became ready to accept '
          'text within ${timeout.inSeconds}s. Text sent now would arrive '
          'incomplete, so none was sent. Check that "$testId" is a text '
          'field that takes focus.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// The character count inside an obscured field's marker, or null when
  /// [text] is not one.
  ///
  /// The SDK renders a field the application chose to obscure as
  /// `[REDACTED]:n` - contents masked, count preserved. Reading `n` is
  /// how a credential can be shown to have arrived whole without any
  /// part of it being read: a count is a number, and a number is not a
  /// credential.
  ///
  /// Note the shape. It is the marker, a colon, then the count - not
  /// `[REDACTED:n]`, which is how a comment in the application describes
  /// it. Parsing the documented spelling rather than the emitted one
  /// would silently match nothing.
  static int? obscuredLength(String text) {
    const separator = ':';
    final prefix = '$redactionMarker$separator';
    if (!text.startsWith(prefix)) return null;

    final digits = text.substring(prefix.length);
    if (digits.isEmpty) return null;
    for (final unit in digits.codeUnits) {
      // Anything but a plain count means this is not the marker, and
      // guessing at it would turn an unrecognised field into a number.
      if (unit < 0x30 || unit > 0x39) return null;
    }
    return int.tryParse(digits);
  }

  /// How many characters [testId] currently holds, or null when the
  /// field reports no text at all.
  ///
  /// Length only, deliberately. This is used to prove a credential
  /// arrived whole, and a check that read the value back would be the
  /// leak it exists to prevent. An obscured field is measured through
  /// its marker; a plaintext one through its own text.
  Future<int?> textLengthOf(String testId) async {
    final snapshot = await captureUiTree();
    // The field on the screen, not any copy of that id left behind on a
    // covered route. Two screens sharing a field id would otherwise let
    // a stale copy answer for the one just typed into - and a length
    // that happened to match would report a credential as delivered
    // whole without having looked at it at all.
    final root = snapshot.findOnTopRoute(testId);
    if (root == null) return null;

    // The id names a wrapper more often than it names the field: in the
    // real application `TestId(login.mobile_field)` sits above
    // `AppSizedBox`, which sits above the `TextField` that actually
    // holds the text. Searching the wrapper's own subtree reaches it
    // without ever reading text belonging to a different element.
    final bearer = root.nearestWhere((node) => node.text != null);
    final text = bearer?.text;
    if (text == null) return null;

    return obscuredLength(text) ?? text.length;
  }

  /// Types [text] into [testId], and proves every character arrived.
  ///
  /// The verification is what turns a lost character from a wrong
  /// screenshot into a named failure.
  Future<void> enterTextById(
    String testId,
    String text, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await focusForInput(testId, timeout: timeout);
    await device.inputText(text);
    await _verifyDelivered(testId, text.length);
  }

  /// Types a credential into [testId], and proves every character
  /// arrived without ever reading the value back.
  Future<void> enterSecretById(
    String testId,
    Secret secret, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await focusForInput(testId, timeout: timeout);
    // The value reaches the device and nothing else.
    await device.inputSecret(secret);
    await _verifyDelivered(testId, secret.expose().length);
  }

  /// Fails unless the field holds exactly as many characters as were
  /// sent.
  ///
  /// A field that reports no text at all is a **named failure**, not a
  /// pass. Skipping silently there is what let a possibly truncated PIN
  /// through unexamined: a check that quietly declines to check is not a
  /// check, and reads in a report exactly like one that succeeded.
  Future<void> _verifyDelivered(String testId, int expected) async {
    final actual = await textLengthOf(testId);

    if (actual == null) {
      throw StateError(
        '"$testId" reports no text of its own, so it cannot be shown that '
        'all $expected characters arrived. An obscured field normally '
        'reports "$redactionMarker:<count>"; one that reports nothing '
        'cannot be verified, and this is reported rather than assumed.',
      );
    }
    if (actual == expected) return;

    throw StateError(
      '"$testId" received $actual of $expected characters. The value was '
      'delivered incompletely, which is a lost-input defect rather than '
      'anything the application did.',
    );
  }

  Future<PhysicalPoint> tapById(
    String testId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final point = await ElementWaiter(timeout: timeout).pointWhenTappable(
      testId,
      captureUiTree,
    );
    await device.tap(point);
    return point;
  }

  Future<void> dispose() => _shutdown();
}
