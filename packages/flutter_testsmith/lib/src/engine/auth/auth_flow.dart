import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../dsl/steps.dart';
import '../dsl/suite_file.dart';
import '../validation/response_source.dart';
import '../secrets/secret_ref.dart';
import '../validation/quiescence.dart';

/// A malformed auth file.
@immutable
class AuthFormatException implements Exception {
  const AuthFormatException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => 'AuthFormatException in $source: $message';
}

/// A route the application shows, and something on it.
///
/// Used to declare what "that credential was wrong" looks like in *this*
/// application, because inferring it from an HTTP status would be a
/// guess about a convention neither this repository nor the application
/// controls: a rejected sign-in may be a 401, or a 200 carrying a
/// failure payload, and only the application knows which.
@immutable
final class AuthUiState {
  const AuthUiState({required this.route, required this.element});

  final String route;
  final String element;
}

/// What must be true for setup to have worked.
@immutable
final class AuthVerify {
  const AuthVerify({
    required this.route,
    required this.element,
    required this.timeout,
    this.request,
    this.notOn = const [],
    this.invalidCredentialOn,
  });

  /// The route the application's own router must have chosen.
  final String route;

  /// An element that must be present on it - so a route event without a
  /// rendered screen is not mistaken for a working dashboard.
  final String element;

  /// How long to wait for [route], from the last login step, or from
  /// launch on the already-authenticated path. It covers the real
  /// authentication request and whatever the application does behind it.
  final Duration timeout;

  /// The application's own authentication exchange. Asserted only when a
  /// login was actually performed.
  ///
  /// Declared with a status and no field expectations, so nothing of the
  /// body can ride into a report.
  final ExpectApiStep? request;

  /// Routes that mean setup did not work, named so the report can say
  /// which one.
  final List<String> notOn;

  /// How this application says the credential was wrong.
  final AuthUiState? invalidCredentialOn;
}

/// How to reach an authenticated state through the real login UI.
///
/// A file of its own, rather than a block in a suite, because setup runs
/// a *different build* from the tests: the UAT entry point against the
/// real backend, where the suite runs the mytest entry point against
/// loopback. A suite's single `app:` block cannot express two, and making
/// it able to would make a suite file two suites.
@immutable
final class AuthFile {
  const AuthFile({
    required this.name,
    required this.app,
    required this.appId,
    required this.deviceProfile,
    this.sdkAppId,
    required this.devicePermissions,
    required this.secrets,
    required this.signedOutOn,
    required this.onboarding,
    required this.login,
    required this.verify,
    this.quiescence = QuiescencePolicy.none,
  });

  final String name;
  final SuiteApp app;

  /// The Android package. What `pm grant` and `am force-stop` address.
  final String appId;

  /// The identity the application's own SDK reports, when it declares
  /// one - `TestSdk.initialize(appId: ...)`, read back over
  /// `ext.mytest.sessionInfo`.
  ///
  /// Separate from [appId] because they are genuinely different values:
  /// the package is what the operating system installed, and this is
  /// what the application says it is. In the application this was built
  /// against they differ, and conflating them would mean comparing a
  /// package name against something that was never going to equal it.
  ///
  /// Optional, and **skipped rather than assumed** when absent: an
  /// application that declares no identity has told the runner nothing,
  /// which is not the same as telling it the identity is right.
  ///
  /// It cannot distinguish one entry point from another - it is declared
  /// once, in shared bootstrap code, so every entry point reports it.
  /// What it establishes is that the application answering is the one
  /// the auth file meant. Which *build* is running is guaranteed instead
  /// by construction: the runner built and launched `app.target` itself.
  final String? sdkAppId;

  final String deviceProfile;
  final List<String> devicePermissions;

  /// Named references, never values.
  final Map<String, SecretRef> secrets;

  /// Routes this application's own router shows when it holds no
  /// session. Declared by a person, exactly as E-04's `unmetOn` is, and
  /// for the same reason: only a person knows that *this* application
  /// shows these routes.
  final List<String> signedOutOn;

  /// Steps from an onboarding route to the login form. Empty when this
  /// application has no onboarding.
  final List<Step> onboarding;

  /// Steps from the login form to submitted credentials.
  final List<Step> login;

  final AuthVerify verify;

  List<SecretRef> get declaredSecrets => secrets.values.toList();

  /// Animations this flow's screens are expected to run for ever.
  ///
  /// The same block, the same parser and the same semantics the suite
  /// DSL already uses - an auth screen with a perpetual Lottie is the
  /// same problem a product screen has, and solving it twice would make
  /// two dialects that disagree on their first refusal.
  ///
  /// Empty for every file that does not mention it, which is what makes
  /// this addition invisible to auth files that already settle.
  final QuiescencePolicy quiescence;

  static const Set<String> _topLevelKeys = {
    'auth',
    'app',
    'appId',
    'sdkAppId',
    'device',
    'secrets',
    'signedOutOn',
    'onboarding',
    'login',
    'verify',
    'quiescence',
  };

  /// Steps an auth flow may contain, and what each takes.
  ///
  /// Everything absent from this map is refused by name.
  static const Map<String, Set<String>> _stepArguments = {
    'launchApp': {},
    'waitForSettle': {'timeoutMs'},
    'tap': {'id'},
    'back': {},
    'expectScreen': {'id', 'timeoutMs'},
    // A waypoint, not an assertion surface. See [_refusedElementArguments].
    'expectElement': {'id', 'timeoutMs'},
    'inputSecret': {'id', 'secret'},
  };

  /// `expectElement` arguments an auth flow refuses, and why.
  ///
  /// They used to parse and then be dropped: the runner read the id and
  /// nothing else, so `enabled: true` reported green from a check that
  /// had only asked whether the element was in the tree. `present:
  /// false` was worse than ignored - the runner raised "not found" for
  /// an element the author had said must be absent.
  ///
  /// Refused by name rather than quietly honoured, because honouring
  /// them would widen what an auth flow may read off a screen that is
  /// showing a credential. `verify:` is where assertions about state
  /// belong, and its shape is constrained so nothing of a body or a
  /// value can ride into a report.
  static const Set<String> _refusedElementArguments = {
    'present',
    'enabled',
    'visible',
    'text',
    'textContains',
  };

  /// Steps refused on purpose, each with the reason printed.
  ///
  /// A parse-time refusal rather than a convention, because a security
  /// property that depends on nobody writing the wrong line is not a
  /// security property.
  static const Map<String, String> _refusedSteps = {
    'screenshot': 'an authentication screen shows an unobscured mobile '
        'number, so auth setup photographs nothing',
    'validateScreen': 'it photographs the screen and writes a UI tree into a '
        'report, and an authentication screen may carry a credential',
    'input': 'a plaintext value. Every credential must go through a secret '
        'reference: use "inputSecret" with a name from the "secrets" block',
    'expectApi': 'an assertion belongs in the "verify" block, where its shape '
        'is constrained to an endpoint and a status',
  };

  factory AuthFile.parse(String yamlText, {required String source}) {
    Never bad(String message) => throw AuthFormatException(source, message);

    final Object? loaded;
    try {
      loaded = loadYaml(yamlText);
    } on YamlException catch (error) {
      bad('invalid YAML: ${error.message}');
    }
    if (loaded is! Map) {
      bad('expected a mapping at the root with auth, app, device and verify');
    }

    Map<String, Object?> asMap(Object? node, String what) {
      if (node is! Map) bad('"$what" must be a mapping');
      return node
          .cast<Object?, Object?>()
          .map((key, value) => MapEntry(key.toString(), value));
    }

    void checkKeys(Map<String, Object?> map, Set<String> known, String what) {
      for (final key in map.keys) {
        if (known.contains(key)) continue;
        bad('unknown $what key "$key". Known: ${known.join(', ')}.');
      }
    }

    List<String> asStringList(Object? node, String what) {
      if (node == null) return const [];
      if (node is! List) bad('"$what" must be a list');
      return [for (final item in node) item.toString()];
    }

    final root = asMap(loaded, 'root');
    checkKeys(root, _topLevelKeys, 'top-level');

    final name = root['auth'];
    if (name is! String || name.isEmpty) {
      bad('an auth file needs an "auth" name');
    }

    final appId = root['appId'];
    if (appId is! String || appId.isEmpty) {
      bad(
        'an auth file needs an "appId" - the Android package, which is what '
        'permissions are granted to and what is stopped at teardown',
      );
    }

    final sdkAppId = root['sdkAppId']?.toString();

    // ── app ──────────────────────────────────────────────────────────
    final appNode = root['app'];
    if (appNode == null) {
      bad('an auth file needs an "app" block naming the build to launch');
    }
    final appMap = asMap(appNode, 'app');
    checkKeys(appMap, const {'path', 'target', 'flavor', 'dartDefines'}, 'app');
    final defines = appMap['dartDefines'];
    if (defines != null && defines is! List) {
      bad('"app.dartDefines" must be a list');
    }
    final app = SuiteApp(
      path: appMap['path']?.toString() ?? '.',
      target: appMap['target']?.toString(),
      flavor: appMap['flavor']?.toString(),
      dartDefines: asStringList(defines, 'app.dartDefines'),
    );

    // ── device ───────────────────────────────────────────────────────
    final device = asMap(root['device'] ?? const {}, 'device');
    checkKeys(device, const {'profile', 'permissions'}, 'device');
    final profile = device['profile'];
    if (profile is! String || profile.isEmpty) {
      bad(
        'an auth file needs "device: profile:" - the id of a device profile, '
        'not a device serial',
      );
    }
    final permissions =
        asStringList(device['permissions'], 'device.permissions');

    // ── secrets ──────────────────────────────────────────────────────
    final secrets = <String, SecretRef>{};
    final rawSecrets = root['secrets'];
    if (rawSecrets != null) {
      final map = asMap(rawSecrets, 'secrets');
      for (final entry in map.entries) {
        try {
          secrets[entry.key] =
              SecretRef.parse(entry.value.toString(), source: source);
        } on SecretRefFormatException catch (error) {
          bad('secret "${entry.key}": ${error.message}');
        }
      }
    }

    // ── signedOutOn ──────────────────────────────────────────────────
    final signedOutOn = asStringList(root['signedOutOn'], 'signedOutOn');
    if (signedOutOn.isEmpty) {
      bad(
        '"signedOutOn" must name at least one route. It is what tells the '
        'runner the application is holding no session; with none, an '
        'unauthenticated launch could never be recognised as one.',
      );
    }

    // ── steps ────────────────────────────────────────────────────────
    Step step(Object? node, String block) {
      final map = asMap(node, '$block step');
      if (map.length != 1) {
        bad('every $block step is one key, such as "tap:". Found: '
            '${map.keys.join(', ')}');
      }
      final stepName = map.keys.single;

      final refusal = _refusedSteps[stepName];
      if (refusal != null) {
        bad('"$stepName" is not allowed in an auth flow: $refusal');
      }

      final known = _stepArguments[stepName];
      if (known == null) {
        bad('unknown step "$stepName". Known: '
            '${_stepArguments.keys.join(', ')}.');
      }

      final args = map[stepName] == null
          ? <String, Object?>{}
          : asMap(map[stepName], '"$stepName" arguments');

      // Named before the generic unknown-key check, so the reason is the
      // real one - "this belongs in verify" rather than "no such key".
      if (stepName == 'expectElement') {
        final refused = [
          for (final key in _refusedElementArguments)
            if (args.containsKey(key)) key,
        ];
        if (refused.isNotEmpty) {
          bad(
            '"expectElement" in an auth flow takes an "id" and a '
            '"timeoutMs", and ${refused.join(', ')} '
            '${refused.length == 1 ? 'is' : 'are'} refused. Here the step '
            'waits for an element on the way to the login form; it does '
            'not assert state. Put the assertion in "verify", whose shape '
            'is constrained so that nothing of a credential reaches a '
            'report.',
          );
        }
      }

      checkKeys(args, known, '"$stepName"');

      String requireString(String key) {
        final value = args[key];
        if (value is! String || value.isEmpty) {
          bad('"$stepName" needs a "$key"');
        }
        return value;
      }

      /// `timeoutMs`, whose absence means the step's own default.
      ///
      /// Written as a cast until now, so `timeoutMs: soon` left the
      /// parser as a `TypeError` rather than an [AuthFormatException] -
      /// which is what the caller guards - and `auth setup` exited 255
      /// with a stack trace and an absolute path. `requireString` beside
      /// it has always checked. Absent and an explicit `null` still both
      /// mean the default, exactly as the cast did.
      Duration timeout(int fallback) {
        final value = args['timeoutMs'];
        if (value == null) return Duration(milliseconds: fallback);
        if (value is! num) {
          bad('"$stepName" needs a whole number of milliseconds for '
              '"timeoutMs", not "$value"');
        }
        return Duration(milliseconds: value.toInt());
      }

      switch (stepName) {
        case 'launchApp':
          return const LaunchAppStep();
        case 'back':
          return const BackStep();
        case 'waitForSettle':
          return WaitForSettleStep(timeout: timeout(10000));
        case 'tap':
          return TapStep(requireString('id'));
        case 'expectScreen':
          return ExpectScreenStep(requireString('id'), timeout: timeout(5000));
        case 'expectElement':
          // Presence and a deadline. Everything else is refused above.
          return ExpectElementStep(
            elementId: requireString('id'),
            timeout: timeout(5000),
          );
        case 'inputSecret':
          final key = requireString('secret');
          final ref = secrets[key];
          if (ref == null) {
            bad(
              '"inputSecret" names the secret "$key", which the "secrets" '
              'block does not declare. Known: '
              '${secrets.isEmpty ? '(none)' : secrets.keys.join(', ')}.',
            );
          }
          return SecretInputStep(elementId: requireString('id'), ref: ref);
        default:
          bad('unhandled step "$stepName"');
      }
    }

    List<Step> block(String key) {
      final node = root[key];
      if (node == null) return const [];
      if (node is! List) bad('"$key" must be a list of steps');
      return [for (final entry in node) step(entry, key)];
    }

    final onboarding = block('onboarding');
    final login = block('login');
    if (login.isEmpty) {
      bad('an auth file needs a non-empty "login" block');
    }

    // ── verify ───────────────────────────────────────────────────────
    final verifyNode = root['verify'];
    if (verifyNode == null) {
      bad(
        'an auth file needs a "verify" block. Without one, setup could only '
        'report that it tapped a button, which is not evidence of a session.',
      );
    }
    final verifyMap = asMap(verifyNode, 'verify');
    checkKeys(
      verifyMap,
      const {
        'route',
        'element',
        'timeoutMs',
        'request',
        'notOn',
        'invalidCredentialOn',
      },
      'verify',
    );

    final route = verifyMap['route'];
    if (route is! String || route.isEmpty) {
      bad('"verify" needs a "route" - the authenticated route to reach');
    }
    final element = verifyMap['element'];
    if (element is! String || element.isEmpty) {
      bad(
        '"verify" needs an "element" present on that route, so a route event '
        'without a rendered screen is not mistaken for a working one',
      );
    }

    ExpectApiStep? request;
    final requestNode = verifyMap['request'];
    if (requestNode != null) {
      final map = asMap(requestNode, 'verify.request');
      checkKeys(map, const {'endpoint', 'status'}, 'verify.request');
      final raw = map['endpoint'];
      if (raw is! String || raw.isEmpty) {
        bad('"verify.request" needs an "endpoint", as in '
            '`endpoint: POST /login/consumer`');
      }
      final endpoint = ApiEndpoint.tryParse(raw);
      if (endpoint == null) {
        bad('"$raw" is not an endpoint. Write METHOD /path, as in '
            '`POST /login/consumer`');
      }
      final status = map['status'];
      if (status is! int || status < 100 || status > 599) {
        bad('"verify.request" needs a "status" - the HTTP status the '
            'application must have received');
      }
      // No field expectations, deliberately and not by omission: the
      // authentication exchange's body carries the credential that was
      // just typed, and a field assertion is how a body reaches a report.
      request = ExpectApiStep(endpoint: endpoint, status: status);
    }

    // The same field as the steps above, in the `verify` block and so
    // out of reach of their closure. Guarded the same way, and read here
    // rather than in the constructor below because a check is a
    // statement.
    final rawVerifyTimeout = verifyMap['timeoutMs'];
    if (rawVerifyTimeout != null && rawVerifyTimeout is! num) {
      bad('"verify" needs a whole number of milliseconds for "timeoutMs", '
          'not "$rawVerifyTimeout"');
    }
    final verifyTimeout = Duration(
      milliseconds: (rawVerifyTimeout as num?)?.toInt() ?? 60000,
    );

    AuthUiState? invalidCredentialOn;
    final invalidNode = verifyMap['invalidCredentialOn'];
    if (invalidNode != null) {
      final map = asMap(invalidNode, 'verify.invalidCredentialOn');
      checkKeys(map, const {'route', 'element'}, 'verify.invalidCredentialOn');
      final invalidRoute = map['route'];
      final invalidElement = map['element'];
      if (invalidRoute is! String || invalidRoute.isEmpty) {
        bad('"verify.invalidCredentialOn" needs a "route"');
      }
      if (invalidElement is! String || invalidElement.isEmpty) {
        bad('"verify.invalidCredentialOn" needs an "element"');
      }
      invalidCredentialOn =
          AuthUiState(route: invalidRoute, element: invalidElement);
    }

    return AuthFile(
      name: name,
      // The same block, parser and semantics the suite DSL uses.
      quiescence: QuiescencePolicy.parse(
        root['quiescence'],
        bad: (message) => throw AuthFormatException(source, message),
      ),
      app: app,
      appId: appId,
      sdkAppId: sdkAppId,
      deviceProfile: profile,
      devicePermissions: permissions,
      secrets: secrets,
      signedOutOn: signedOutOn,
      onboarding: onboarding,
      login: login,
      verify: AuthVerify(
        route: route,
        element: element,
        timeout: verifyTimeout,
        request: request,
        notOn: asStringList(verifyMap['notOn'], 'verify.notOn'),
        invalidCredentialOn: invalidCredentialOn,
      ),
    );
  }
}
