import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// What the runner needs an application to do.
///
/// An interface rather than an `AppSession`, so every decision in
/// [AuthRunner] is testable without a handset - the same seam
/// `DeviceEnvironment` gives preflight, for the same reason. The adapter
/// onto a real session lives with the command.
abstract interface class AuthDriver {
  /// The route the application's own router has currently chosen.
  Future<String?> currentRoute();

  /// Every route it has passed through since launch.
  List<String> routeHistory();

  Future<void> tap(String elementId);

  /// Types a credential. The value reaches the device and nothing else.
  Future<void> inputSecret(String elementId, Secret secret);

  /// Waits for the screen to stop changing.
  ///
  /// [policy] is what the auth file declared about animations its screens
  /// are expected to run for ever. Without a declaration this is exactly
  /// the check it always was: an animation nobody named still holds the
  /// screen.
  Future<void> waitForSettle(Duration timeout, QuiescencePolicy policy);

  /// Waits for [route] to arrive, and **fails** when it does not.
  ///
  /// Returning quietly on a deadline was DEF-E05-03: a screen that never
  /// arrived went unreported, the flow carried on, and the run failed
  /// later on a missing element - blaming the application's test ids for
  /// what was a navigation that never happened.
  Future<void> awaitRoute(String route, Duration timeout);

  /// Whether [elementId] is on the screen right now.
  ///
  /// A single read, and it stays one: it answers "is the error showing
  /// *now*", where waiting would turn a screen that is fine into one
  /// that failed slowly.
  Future<bool> hasElement(String elementId);

  /// Whether [elementId] appears within [timeout].
  ///
  /// The landing screen of a real application renders after its route
  /// event, not with it: an application can reach /home and only then
  /// load the dashboard. Reading once turned that into
  /// AUTHENTICATED_STATE_NOT_REACHED on a session that was genuinely
  /// established - on both the login path and the already-authenticated
  /// one, which is why no auth-file declaration could have fixed it.
  Future<bool> awaitElement(String elementId, Duration timeout);

  /// The application's own exchange matching [step], or null.
  Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step);

  /// What the application says it is, when it says anything.
  Future<({String? appId, String? version, String? buildMode})> identity();

  Future<void> dispose();
}

/// Establishes an authenticated state through the real login UI.
///
/// Holds no adb and no `flutter run`: it decides, and [AuthDriver] acts.
class AuthRunner {
  AuthRunner({
    required this.file,
    required this.secrets,
    required this.driver,
    required this.log,
    this.deviceModel,
    this.routeSettleTimeout = const Duration(seconds: 30),
  });

  final AuthFile file;
  final SecretResolver secrets;
  final AuthDriver driver;
  final void Function(String) log;
  final String? deviceModel;

  /// How long to wait for the application's router to settle on a route
  /// this auth file recognises.
  ///
  /// A launch does not begin on a route the file names. This application
  /// begins on "/", a splash that reads its own session flag and only
  /// then routes to /onboarding, /login or the landing route. Sampling
  /// once at handshake reads the splash, which is neither signed-out nor
  /// authenticated - it is "not yet decided".
  final Duration routeSettleTimeout;

  Future<AuthSetupResult> run() async {
    final watch = Stopwatch()..start();

    var loginPerformed = false;
    var loginUiMissing = false;
    String? missingElementId;
    ApiExpectationOutcome? exchange;
    String? flowFailure;
    final used = <SecretRef>[];
    ({String? appId, String? version, String? buildMode})? identity;

    try {
      // Every declared secret is *there*, before anything is driven. A
      // bool, never the value: a presence check must not pull a
      // credential into the process.
      for (final ref in file.declaredSecrets) {
        if (!secrets.isPresent(ref)) throw MissingSecretException(ref);
      }

      identity = await driver.identity();

      final landed = await _awaitRecognisedRoute();
      log('› the application chose "$landed"');

      if (file.signedOutOn.contains(landed)) {
        // A session has to be established, so the real UI is driven.
        try {
          if (landed != null &&
              file.onboarding.isNotEmpty &&
              landed != _firstExpectedRoute(file.login)) {
            await _drive(file.onboarding, used);
          }
          await _drive(file.login, used);
          loginPerformed = true;
        } on ElementNotFoundException catch (error) {
          loginUiMissing = true;
          missingElementId = error.testId;
          log('  ✗ the login UI does not carry "${error.testId}"');
        } on Object catch (error) {
          // The engine going blind is not a step that did not complete.
          // Handled by the outer catch, which files it as what it is.
          if (isInfrastructureFailure(error)) rethrow;

          // A step that did not complete is a verdict, not an exception -
          // the same discipline `awaitRoute` below already follows.
          // Raising here produced exit 255 and a stack trace with no
          // classification, no remedy and no artefact, measured on a
          // real device against a backend that rejected the login.
          //
          // A credential was typed and submitted before this, so the
          // login counts as performed: the authentication request is
          // still worth judging, and the guest rule must not fire on a
          // run that did try to sign in.
          loginPerformed = true;
          flowFailure = '$error';
          log('  ✗ $error');
        }
      } else if (landed == file.verify.route) {
        log('› already authenticated; no credential will be used');
      } else {
        // Neither signed-out nor the authenticated route, after waiting
        // for the router to settle. Treating this as "already
        // authenticated" was how a freshly-cleared device reported that
        // no credential was needed - measured on a real handset, twice.
        // It is reported as not reaching the authenticated state, which
        // is what it is.
        log('› the application settled on "$landed", which this auth file '
            'neither lists in signedOutOn nor verifies as authenticated');
      }

      if (!loginUiMissing) {
        // Wait for the authenticated route, but never longer than
        // declared. Not reaching it is a verdict, not an exception.
        try {
          await driver.awaitRoute(file.verify.route, file.verify.timeout);
        } on Object catch (error) {
          // Letting the route decide is right for a route that did not
          // arrive, and wrong for a connection that did not survive: the
          // route reading after the engine stopped observing is simply
          // the last one that reached it. Classifying from it produced
          // "authentication succeeded and the app did not arrive" about
          // a run in which neither had been established.
          if (isInfrastructureFailure(error)) rethrow;
          // Otherwise classified below, from the route actually on.
        }
      }

      final route = await driver.currentRoute();
      final request = file.verify.request;
      if (loginPerformed && request != null) {
        exchange = await driver.readExchange(request);
      }

      final invalid = file.verify.invalidCredentialOn;
      final invalidVisible = invalid != null &&
          route == invalid.route &&
          await driver.hasElement(invalid.element);

      // Waited for, not sampled. Bounded by the file's own
      // verify.timeoutMs, and it returns the moment the element appears.
      final elementPresent = !loginUiMissing &&
          await driver.awaitElement(file.verify.element, file.verify.timeout);

      final failure = classifyAuthSetup(
        file: file,
        seen: AuthObservations(
          route: route,
          routeHistory: driver.routeHistory(),
          loginPerformed: loginPerformed,
          elementPresent: elementPresent,
          request: exchange,
          invalidCredentialVisible: invalidVisible,
          loginUiMissing: loginUiMissing,
          flowFailure: flowFailure,
          missingElementId: missingElementId,
          reportedAppId: identity.appId,
        ),
      );

      return _result(
        failure: failure,
        detail: _detailFor(
          failure,
          route,
          missingElementId,
          identity.appId,
          elementPresent: elementPresent,
          loginPerformed: loginPerformed,
          routeHistory: driver.routeHistory(),
          flowFailure: flowFailure,
        ),
        route: route,
        loginPerformed: loginPerformed,
        elementVerified: elementPresent,
        request: exchange,
        watch: watch,
        identity: identity,
        used: used,
      );
    } on MissingSecretException catch (error) {
      log('  ✗ ${error.ref} is not set');
      return _result(
        failure: AuthSetupFailure.secretMissing,
        detail: '${error.ref} resolved to nothing',
        route: null,
        loginPerformed: false,
        elementVerified: false,
        watch: watch,
        identity: identity,
        used: used,
      );
    } on Object catch (error) {
      // Only the typed infrastructure failures. Everything else keeps
      // propagating exactly as it did, so a bug in this codebase still
      // surfaces as a bug rather than being filed as a flaky device.
      if (!isInfrastructureFailure(error)) rethrow;

      // The cause is carried through verbatim - it already names the
      // operation, the deadline, the connection state or what could not
      // be read - rather than being flattened into "authentication
      // failed", which is the sentence this whole classification exists
      // to stop being printed.
      log('  ✗ $error');
      return _result(
        failure: AuthSetupFailure.observationFailed,
        detail: '$error',
        route: null,
        loginPerformed: loginPerformed,
        elementVerified: false,
        watch: watch,
        identity: identity,
        used: used,
      );
    } finally {
      // Always, and never raising over whatever caused it. Teardown must
      // not replace the real cause with a confusing one - E-04's rule.
      try {
        await driver.dispose();
      } catch (error) {
        log('  ! could not dispose the session: $error');
      }
    }
  }

  /// Waits for the router to settle on a route this auth file recognises.
  ///
  /// Recognised means signed-out, or the authenticated route. Anything
  /// else - a splash, a transient redirect - is "not yet decided", and
  /// deciding from it is how a signed-out device gets read as a signed-in
  /// one.
  ///
  /// Returns as soon as a recognised route appears, so the timeout is an
  /// upper bound rather than a wait. On expiry it returns whatever the
  /// application is actually on, which the verification then classifies.
  Future<String?> _awaitRecognisedRoute() async {
    final deadline = DateTime.now().add(routeSettleTimeout);
    while (true) {
      final route = await driver.currentRoute();
      if (route != null &&
          (file.signedOutOn.contains(route) || route == file.verify.route)) {
        return route;
      }
      if (!DateTime.now().isBefore(deadline)) return route;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// The route the first `expectScreen` of [steps] names, or null.
  ///
  /// Used to tell "landed on onboarding" from "landed on the login form"
  /// without a conditional step: the login block says where it starts,
  /// so the runner enters at whichever block matches.
  String? _firstExpectedRoute(List<Step> steps) {
    for (final step in steps) {
      if (step is ExpectScreenStep) return step.screenId;
    }
    return null;
  }

  /// Runs a block, resolving each credential immediately before it is
  /// typed and holding none of them afterwards.
  Future<void> _drive(List<Step> steps, List<SecretRef> used) async {
    for (final step in steps) {
      log('  › ${step.describe()}');
      switch (step) {
        case SecretInputStep(:final elementId, :final ref):
          // Resolved here and nowhere earlier. Nothing retains the
          // Secret once this call returns.
          await driver.inputSecret(elementId, secrets.resolve(ref));
          if (!used.contains(ref)) used.add(ref);
        case TapStep(:final elementId):
          await driver.tap(elementId);
        case ExpectScreenStep(:final screenId, :final timeout):
          await driver.awaitRoute(screenId, timeout);
        case WaitForSettleStep(:final timeout):
          await driver.waitForSettle(timeout, file.quiescence);
        case ExpectElementStep(:final elementId, :final timeout):
          // Waited for, within the deadline the step declares. A single
          // read here raced the screen it was asserting about - the same
          // shape as DEF-E05-05 - and classified a login form that was
          // still arriving as one the application does not have.
          //
          // `AuthFile.parse` admits an id and a timeout and refuses
          // every state argument by name, so presence is the whole of
          // what this step claims.
          if (!await driver.awaitElement(elementId, timeout)) {
            throw ElementNotFoundException(
              testId: elementId,
              available: const [],
            );
          }
        case LaunchAppStep():
        case BackStep():
        case InputStep():
        case ScreenshotStep():
        case ExpectApiStep():
        case ValidateScreenStep():
          // `AuthFile.parse` admits only the steps handled above and
          // refuses the rest by name. Reaching here would mean the
          // parser and this switch had drifted.
          throw StateError(
            '"${step.describe()}" is not a step an auth flow may run',
          );
      }
    }
  }

  /// Which term of the conjunction failed, in the words of that term.
  ///
  /// [AuthSetupFailure.authenticatedStateNotReached] covers three
  /// different disappointments - the wrong route, the right route
  /// without its element, and the right route reached as a guest - and
  /// they send a reader to three different places. Rendering the route
  /// wording for all of them produced `ended on "/home" rather than
  /// "/home"`, measured on a real device: a sentence that names no
  /// defect and points nowhere.
  String _detailFor(
    AuthSetupFailure? failure,
    String? route,
    String? missingElementId,
    String? reportedAppId, {
    required bool elementPresent,
    required bool loginPerformed,
    required List<String> routeHistory,
    String? flowFailure,
  }) =>
      switch (failure) {
        null => '',
        AuthSetupFailure.loginUiNotFound =>
          'the login UI does not carry "$missingElementId"',
        AuthSetupFailure.authenticatedStateNotReached =>
          _stateNotReached(route, elementPresent, loginPerformed, routeHistory),
        AuthSetupFailure.authPathNotSupported =>
          'the application went to "$route", which needs a one-time code',
        AuthSetupFailure.invalidCredential =>
          'the application rejected the credential and stayed on "$route"',
        AuthSetupFailure.authRequestFailed =>
          'the authentication request did not answer as declared',
        AuthSetupFailure.environmentPrerequisite =>
          'the application reports "$reportedAppId", and this auth file '
              'declares "${file.sdkAppId}"',
        AuthSetupFailure.authFlowFailed => flowFailure ?? '',
        AuthSetupFailure.secretMissing => '',
        // Never reaches here: an observation failure short-circuits to
        // its own result, carrying the transport's own words, rather
        // than being described in the vocabulary of authentication.
        AuthSetupFailure.observationFailed => '',
      };

  /// The specific reason the authenticated state was not reached.
  ///
  /// Ordered as the classifier orders the terms, so the sentence names
  /// the first thing that actually failed rather than the last thing
  /// that was checked.
  String _stateNotReached(
    String? route,
    bool elementPresent,
    bool loginPerformed,
    List<String> routeHistory,
  ) {
    if (route != file.verify.route) {
      return 'the application ended on "$route" rather than '
          '"${file.verify.route}"';
    }
    if (!elementPresent) {
      return 'the application reached "${file.verify.route}" - the route '
          'this file verifies - but "${file.verify.element}" was still not '
          'on it after ${file.verify.timeout.inSeconds}s, so a route event '
          'arrived without the screen behind it. Current route: '
          '"${route ?? 'none'}"';
    }
    final passed = [
      for (final seen in routeHistory)
        if (file.signedOutOn.contains(seen)) seen,
    ];
    if (!loginPerformed && passed.isNotEmpty) {
      return 'the application reached "${file.verify.route}" without '
          'signing in, having passed ${passed.map((r) => '"$r"').join(', ')} '
          'on the way - which is a guest browsing to it, not a session';
    }
    return 'the application did not reach "${file.verify.route}"';
  }

  AuthSetupResult _result({
    required AuthSetupFailure? failure,
    required String detail,
    required String? route,
    required bool loginPerformed,
    required bool elementVerified,
    required Stopwatch watch,
    required ({String? appId, String? version, String? buildMode})? identity,
    required List<SecretRef> used,
    ApiExpectationOutcome? request,
  }) =>
      AuthSetupResult(
        outcome: failure == null
            ? AuthSetupOutcome.succeeded
            : AuthSetupOutcome.failed,
        failure: failure,
        detail: detail,
        remedy: failure?.remedy ?? '',
        route: route,
        routeHistory: driver.routeHistory(),
        loginPerformed: loginPerformed,
        elementVerified: elementVerified,
        request: request,
        durationMs: watch.elapsedMilliseconds,
        secretsUsed: used,
        appId: identity?.appId,
        appVersion: identity?.version,
        buildMode: identity?.buildMode,
        deviceModel: deviceModel,
      );
}
