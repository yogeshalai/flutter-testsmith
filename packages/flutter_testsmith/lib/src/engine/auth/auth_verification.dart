import 'package:meta/meta.dart';

import '../validation/api_expectation.dart';
import 'auth_flow.dart';
import 'auth_result.dart';

/// Everything the runner saw, and nothing it inferred.
///
/// A plain record of observations, so the decision below is a pure
/// function: the whole state matrix is then testable without a handset,
/// which is the same split `doctor` and E-04's preflight already use -
/// facts from the CLI, judgements in the engine.
@immutable
final class AuthObservations {
  const AuthObservations({
    required this.route,
    required this.routeHistory,
    this.flowFailure,
    required this.loginPerformed,
    required this.elementPresent,
    this.request,
    this.invalidCredentialVisible = false,
    this.loginUiMissing = false,
    this.missingElementId,
    this.environmentBlocked = false,
    this.secretMissing = false,
    this.reportedAppId,
  });

  /// The route the application's own router last chose.
  final String? route;

  /// Every route it passed through since launch.
  final List<String> routeHistory;

  /// Why a step of the declared flow did not complete, or null when
  /// every step did.
  ///
  /// Carried as an observation rather than raised, for the reason
  /// `awaitRoute` already is: not getting there is a verdict, and a
  /// verdict that arrives as an unhandled exception has no
  /// classification, no remedy and no artefact.
  final String? flowFailure;

  final bool loginPerformed;

  /// Whether the verify block's element was on the final screen.
  final bool elementPresent;

  /// The application's own authentication exchange, when one happened.
  final ApiExpectationOutcome? request;

  /// Whether the application's own "that credential was wrong" state is
  /// showing, as the auth file declares it.
  final bool invalidCredentialVisible;

  /// Whether a step could not find the element it named.
  final bool loginUiMissing;
  final String? missingElementId;

  final bool environmentBlocked;
  final bool secretMissing;

  /// The identity the application's own SDK reported over
  /// `ext.mytest.sessionInfo`, when it declares one.
  final String? reportedAppId;
}

/// Why setup did not work, or null when it did.
///
/// The order is the specification's section 9.0 and is load-bearing:
/// more than one rule can be true at once, and the most specific answer
/// is the most useful one.
AuthSetupFailure? classifyAuthSetup({
  required AuthFile file,
  required AuthObservations seen,
}) {
  // 1. Nothing below it could be believed.
  if (seen.environmentBlocked) {
    return AuthSetupFailure.environmentPrerequisite;
  }
  // Compared only when both sides declared something. An application
  // that reports no identity has told the runner nothing, and an auth
  // file that names none has asked nothing - neither is evidence that
  // the identity is wrong, so neither blocks.
  //
  // Never compared against `file.appId`: that is the Android package,
  // and this is what the application says it is. They are different
  // values by design, and comparing them would fail every real run.
  if (file.sdkAppId != null &&
      seen.reportedAppId != null &&
      seen.reportedAppId != file.sdkAppId) {
    return AuthSetupFailure.environmentPrerequisite;
  }

  // 2. Nothing was ever typed.
  if (seen.secretMissing) return AuthSetupFailure.secretMissing;

  // 3. The flow could not be driven.
  if (seen.loginUiMissing) return AuthSetupFailure.loginUiNotFound;

  // 4. The application went somewhere we refuse rather than time out on.
  //
  // Both conditions together: the auth file has to have declared the
  // route unsupported, *and* it has to be a one-time-code screen. A
  // route that is merely in `notOn` is reported at step 7 instead, which
  // is the honest answer for a destination like /set-location that means
  // "authenticated, but not where we needed to be".
  final route = seen.route;
  if (route != null &&
      file.verify.notOn.contains(route) &&
      _isOneTimeCodeRoute(route)) {
    return AuthSetupFailure.authPathNotSupported;
  }

  // 5. The application itself said the credential was wrong.
  final invalid = file.verify.invalidCredentialOn;
  if (invalid != null &&
      seen.invalidCredentialVisible &&
      route == invalid.route) {
    return AuthSetupFailure.invalidCredential;
  }

  // 6. A declared step did not complete.
  //
  // Above the request term deliberately: when the flow stalled, the
  // authentication request may never have been made at all, and
  // "the request did not answer as declared" would report a consequence
  // as though it were the cause. Below `invalidCredential`, because a
  // rejected credential usually stalls the flow too and the
  // application's own verdict is the sharper one.
  if (seen.flowFailure != null) return AuthSetupFailure.authFlowFailed;

  // 7. The authentication request did not answer as declared.
  //
  // Only meaningful when a login was actually attempted: on the
  // already-authenticated path there is no request to judge, and a
  // skipped term must not read as a satisfied one.
  if (seen.loginPerformed && file.verify.request != null) {
    final request = seen.request;
    if (request == null || !request.satisfied) {
      return AuthSetupFailure.authRequestFailed;
    }
  }

  // 8. Everything worked, and the authenticated state did not arrive.
  if (route != file.verify.route) {
    return AuthSetupFailure.authenticatedStateNotReached;
  }
  if (!seen.elementPresent) {
    return AuthSetupFailure.authenticatedStateNotReached;
  }

  // A cold start that reached the authenticated route without passing a
  // signed-out route is the proof of a session, and it is the
  // application's own router that supplies it. A run that got there by
  // some other path - a guest browsing to a guest-browsable route - is
  // not accepted as evidence.
  if (!seen.loginPerformed &&
      seen.routeHistory.any(file.signedOutOn.contains)) {
    return AuthSetupFailure.authenticatedStateNotReached;
  }

  return null;
}

/// Whether a route is a one-time-code screen.
///
/// Named by substring rather than by an exact list, so an application
/// that spells its OTP route differently is still recognised. It only
/// ever *reclassifies* a route the auth file has already declared
/// unsupported, so a false positive here cannot turn a failure into a
/// pass - it can only change which failure is reported.
bool _isOneTimeCodeRoute(String route) =>
    route.contains('otp') || route.contains('one-time');
