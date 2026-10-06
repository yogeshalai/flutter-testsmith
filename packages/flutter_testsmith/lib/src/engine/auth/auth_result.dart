import 'package:meta/meta.dart';

import '../environment/prerequisite.dart';
import '../validation/api_expectation.dart';
import '../secrets/secret_ref.dart';

/// Whether setup established an authenticated state.
enum AuthSetupOutcome {
  succeeded('succeeded'),
  failed('failed');

  const AuthSetupOutcome(this.wire);

  final String wire;
}

/// Why setup did not establish one.
///
/// Distinct values rather than a message, because the whole point of
/// E-04's classification was that "the run failed" is not actionable.
/// Each carries the class that owns it, so the report says which person
/// to send it to.
enum AuthSetupFailure {
  /// A declared reference resolved to nothing. Nothing was launched and
  /// nothing was typed.
  secretMissing(
    'SECRET_MISSING',
    PrerequisiteClass.runnerControlled,
    'Set the environment variable the auth file names, or put it in a .env '
        'file that is not committed.',
  ),

  /// The application itself said the credential was wrong - it stayed on
  /// its own error state rather than moving on.
  invalidCredential(
    'INVALID_CREDENTIAL',
    PrerequisiteClass.humanAction,
    'Check the credential behind the secret reference. The application '
        'rejected it through its own login flow.',
  ),

  /// A declared element was not in the tree.
  loginUiNotFound(
    'LOGIN_UI_NOT_FOUND',
    PrerequisiteClass.applicationControlled,
    'The login UI does not carry the element the auth file names. Update the '
        'auth file, or restore the test id in the application.',
  ),

  /// The authentication exchange never happened, or did not answer as
  /// declared.
  authRequestFailed(
    'AUTH_REQUEST_FAILED',
    PrerequisiteClass.externalService,
    'The application could not complete its authentication request. Check '
        'that the backend the build points at is reachable from the device.',
  ),

  /// The application went somewhere that cannot be driven
  /// deterministically.
  authPathNotSupported(
    'AUTH_PATH_NOT_SUPPORTED',
    PrerequisiteClass.applicationControlled,
    'The application chose a one-time-code path, which needs a real message '
        'and cannot be automated without bypassing authentication. Use an '
        'account whose sign-in the auth file can drive.',
  ),

  /// A step of the declared flow did not complete - it timed out, or the
  /// device refused it.
  ///
  /// Ranked below [invalidCredential] and above [authRequestFailed].
  ///
  /// Below the first, because a rejected credential usually *also*
  /// stalls the flow - the application sits on its error state and never
  /// settles - and "that credential was wrong" is the useful sentence.
  /// Above the second, because a flow that stalled may never have made
  /// the authentication request at all, and reporting the missing
  /// request would name a consequence as though it were the cause.
  authFlowFailed(
    'AUTH_FLOW_FAILED',
    PrerequisiteClass.applicationControlled,
    'A step of the declared login flow did not complete. The detail names '
        'the step and what it was still waiting for.',
  ),

  /// Authentication worked and the authenticated route was not reached.
  authenticatedStateNotReached(
    'AUTHENTICATED_STATE_NOT_REACHED',
    PrerequisiteClass.applicationControlled,
    'Authentication succeeded and the application did not reach the route the '
        'auth file verifies. Check the device location service and the '
        'permissions the auth file declares.',
  ),

  /// The engine stopped being able to observe the application.
  ///
  /// Not a statement about authentication at all, which is exactly why
  /// it exists. A lost VM Service connection, an RPC that went
  /// unanswered, or an event stream this build could not read used to
  /// arrive as AUTH_FLOW_FAILED or AUTHENTICATED_STATE_NOT_REACHED
  /// depending only on *when* it happened - two different claims about
  /// the application's authentication, neither of which had been
  /// measured.
  ///
  /// [PrerequisiteClass.devicePrerequisite] for E-04's stated reason: a
  /// missing one "is a configuration result, never a product failure",
  /// which is precisely the property this needs.
  observationFailed(
    'OBSERVATION_FAILED',
    PrerequisiteClass.devicePrerequisite,
    'Testing Tool could not observe the application, so nothing was '
        'established about its authentication either way. The detail names '
        'what happened. Check that the device stayed connected and awake '
        'and that the application kept running, and that the app and this '
        'runner were built from the same version of the platform.',
  ),

  /// Device, build, profile, permissions, or the wrong application.
  environmentPrerequisite(
    'ENVIRONMENT_PREREQUISITE',
    PrerequisiteClass.devicePrerequisite,
    'The environment could not run auth setup. The preflight rows above say '
        'which prerequisite, and what to do about it.',
  );

  const AuthSetupFailure(this.wire, this.klass, this.remedy);

  final String wire;
  final PrerequisiteClass klass;

  /// What a person should do. Carried on the value rather than passed
  /// in, so a classification can never be reported without one - E-04's
  /// rule for a blocking preflight check, for E-04's reason.
  final String remedy;
}

/// What auth setup did, and what it can say about it.
///
/// Serialised through an **allow-list** of keys. That is E-04's pattern
/// and E-04's reasoning: a deny-list only ever catches the secrets
/// somebody remembered. Nothing here carries a URL, a body, a header, a
/// UI tree, an image, a device serial or a credential.
@immutable
final class AuthSetupResult {
  const AuthSetupResult({
    required this.outcome,
    required this.loginPerformed,
    this.failure,
    this.detail = '',
    this.remedy = '',
    this.route,
    this.routeHistory = const [],
    this.elementVerified = false,
    this.request,
    this.durationMs = 0,
    this.secretsUsed = const [],
    this.appId,
    this.appVersion,
    this.buildMode,
    this.deviceModel,
  });

  final AuthSetupOutcome outcome;
  final AuthSetupFailure? failure;

  /// What was found. Never a credential: every value that could carry
  /// one is a [Secret], whose `toString` is the marker.
  final String detail;

  final String remedy;

  /// The route the application's own router last chose.
  final String? route;

  /// Every route it passed through, which is what proves a cold start
  /// reached the authenticated route without going by way of the login
  /// screen.
  final List<String> routeHistory;

  /// False when the device was already authenticated. Recorded so nobody
  /// reads a skipped verification term as a satisfied one.
  final bool loginPerformed;

  final bool elementVerified;

  /// Endpoint, status and whether it held. `ApiExpectationOutcome`
  /// serialises no body, no headers and no URL query.
  final ApiExpectationOutcome? request;

  final int durationMs;

  /// References only.
  final List<SecretRef> secretsUsed;

  final String? appId;
  final String? appVersion;
  final String? buildMode;

  /// The model, never the serial.
  final String? deviceModel;

  bool get succeeded => outcome == AuthSetupOutcome.succeeded;

  /// 0 or 2, and never 1.
  ///
  /// Exit 1 means the application is wrong. Auth setup judges no screen,
  /// so it is never in a position to say that; every failure is "the run
  /// is wrong", which is what 2 has always meant here.
  int get exitCode => succeeded ? 0 : 2;

  Map<String, Object?> toJson() => {
        'outcome': outcome.wire,
        if (failure != null) 'classification': failure!.wire,
        if (detail.isNotEmpty) 'detail': detail,
        if (remedy.isNotEmpty) 'remedy': remedy,
        'route': route,
        'routeHistory': routeHistory,
        'loginPerformed': loginPerformed,
        'elementVerified': elementVerified,
        if (request != null) 'request': request!.toJson(),
        'durationMs': durationMs,
        'secretsUsed': [for (final ref in secretsUsed) ref.toString()],
        'appId': appId,
        'appVersion': appVersion,
        'buildMode': buildMode,
        'deviceModel': deviceModel,
      };
}
