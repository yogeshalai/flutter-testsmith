// The lifecycle, driven against a scripted application.
//
// The driver is a seam rather than a handset, so every branch - already
// authenticated, a wrong PIN, a missing element, a teardown after a
// failure - is a test that runs in milliseconds on any machine. The
// handset proves the wiring; this proves the decisions.

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/auth_runner.dart';
import 'package:flutter_testsmith/engine.dart';

const String _seededPin = 'SEEDED_PIN_9f2a41c8';
const String _seededMobile = '9876543210';

const String _yaml = '''
auth: t
app: {path: ., target: lib/main_uat.dart, flavor: f}
appId: com.example.package
sdkAppId: com.example.sdkidentity
device: {profile: p}
secrets:
  mobile: env:MYTEST_AUTH_MOBILE
  pin: env:MYTEST_AUTH_PIN
signedOutOn: [/onboarding, /login]
onboarding:
  - tap: {id: onboarding.get_started}
login:
  - expectScreen: {id: /login}
  - inputSecret: {id: login.mobile_field, secret: mobile}
  - tap: {id: login.continue_button}
  - expectScreen: {id: /secure-login}
  - inputSecret: {id: secure_login.pin_field, secret: pin}
  - tap: {id: secure_login.continue_button}
verify:
  route: /home
  element: home.body
  request: {endpoint: POST /login/consumer, status: 200}
  notOn: [/set-location, /otp-verification]
  invalidCredentialOn: {route: /secure-login, element: secure_login.pin_error}
''';

final AuthFile _file = AuthFile.parse(_yaml, source: 'auth.yaml');

class MapResolver implements SecretResolver {
  MapResolver(this._values);

  final Map<String, String> _values;

  @override
  bool isPresent(SecretRef ref) => (_values[ref.name] ?? '').isNotEmpty;

  @override
  Secret resolve(SecretRef ref) {
    final value = _values[ref.name];
    if (value == null || value.isEmpty) throw MissingSecretException(ref);
    return Secret(value);
  }
}

/// An application that follows a script of routes, one step per tap.
class ScriptedDriver implements AuthDriver {
  ScriptedDriver({
    required this.routes,
    this.missingElements = const {},
    this.presentElements = const {'home.body', 'secure_login.pin_error'},
    this.exchange,
    this.appId = 'com.example.sdkidentity',
    this.seededHistory = const [],
  });

  final List<String> routes;
  final Set<String> missingElements;
  final Set<String> presentElements;
  final ApiExpectationOutcome? exchange;
  final String? appId;

  /// Routes the application navigated through before the runner looked.
  ///
  /// The real driver reads history from the SDK's own navigation events,
  /// not from polling, so it can report routes the runner never
  /// observed - a cold start that passed /login on its way to /home
  /// being exactly the case the guest rule exists for.
  final List<String> seededHistory;

  int _index = 0;
  late final List<String> _history = [...seededHistory];
  final List<String> actions = [];
  bool disposed = false;

  @override
  Future<String?> currentRoute() async {
    final route = routes[_index.clamp(0, routes.length - 1)];
    if (_history.isEmpty || _history.last != route) _history.add(route);
    return route;
  }

  @override
  List<String> routeHistory() => List.unmodifiable(_history);

  @override
  Future<void> tap(String elementId) async {
    if (missingElements.contains(elementId)) {
      throw ElementNotFoundException(testId: elementId, available: const []);
    }
    actions.add('tap $elementId');
    if (_index < routes.length - 1) _index++;
    await currentRoute();
  }

  @override
  Future<void> inputSecret(String elementId, Secret secret) async {
    if (missingElements.contains(elementId)) {
      throw ElementNotFoundException(testId: elementId, available: const []);
    }
    // Deliberately records the rendering, not the value: if a Secret
    // ever starts rendering as its contents, the leakage group below
    // catches it here.
    actions.add('inputSecret $elementId $secret');
  }

  @override
  Future<void> waitForSettle(Duration timeout, QuiescencePolicy policy) async {}

  @override
  Future<void> awaitRoute(String route, Duration timeout) async {
    await currentRoute();
  }

  @override
  Future<bool> awaitElement(String id, Duration timeout) async =>
      hasElement(id);

  @override
  Future<bool> hasElement(String elementId) async =>
      presentElements.contains(elementId);

  @override
  Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step) async =>
      exchange;

  @override
  Future<({String? appId, String? version, String? buildMode})>
      identity() async =>
          (appId: appId, version: '1.0.6', buildMode: 'debug');

  @override
  Future<void> dispose() async => disposed = true;
}

/// An application that begins on a transient splash route, as the real
/// one does: "/" reads the session flag and only then routes onward.
class SplashDriver extends ScriptedDriver {
  SplashDriver({
    required super.routes,
    super.presentElements,
    super.exchange,
    this.splashReads = 3,
  });

  /// How many reads return "/" before the router settles.
  final int splashReads;
  int _reads = 0;

  @override
  Future<String?> currentRoute() async {
    if (_reads++ < splashReads) return '/';
    return super.currentRoute();
  }
}

/// An application that never leaves a route the auth file does not name.
class StuckDriver extends ScriptedDriver {
  StuckDriver({required this.stuckOn}) : super(routes: const ['/']);

  final String stuckOn;

  @override
  Future<String?> currentRoute() async => stuckOn;
}

/// An application that stalls once the credential has been submitted -
/// what a real one does when it sits on its own error state rather than
/// moving on.
class StallingDriver extends ScriptedDriver {
  StallingDriver({
    required super.routes,
    super.presentElements,
    super.exchange,
  });

  @override
  Future<void> awaitRoute(String route, Duration timeout) async {
    if (actions.any((a) => a.startsWith('tap'))) {
      throw StateError(
        'the screen did not settle within ${timeout.inSeconds}s. Still '
        'waiting on: frames still rendering',
      );
    }
    return super.awaitRoute(route, timeout);
  }
}

ApiExpectationOutcome _ok() => const ApiExpectationOutcome(
      endpoint: 'POST /login/consumer',
      status: 200,
      failures: [],
    );

Future<({AuthSetupResult result, ScriptedDriver driver, List<String> log})>
    _run(
  ScriptedDriver driver, {
  Map<String, String> secrets = const {
    'MYTEST_AUTH_MOBILE': _seededMobile,
    'MYTEST_AUTH_PIN': _seededPin,
  },
  // Short, so a test that deliberately never settles finishes in
  // milliseconds rather than in the production upper bound.
  Duration routeSettleTimeout = const Duration(milliseconds: 600),
}) async {
  final log = <String>[];
  final result = await AuthRunner(
    file: _file,
    secrets: MapResolver(secrets),
    driver: driver,
    log: log.add,
    deviceModel: 'SM-M127G',
    routeSettleTimeout: routeSettleTimeout,
  ).run();
  return (result: result, driver: driver, log: log);
}

void main() {
  group('a signed-out device', () {
    test('drives the real login and succeeds', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/onboarding', '/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));

      expect(run.result.succeeded, isTrue);
      expect(run.result.exitCode, 0);
      expect(run.result.loginPerformed, isTrue);
      expect(run.result.route, '/home');
      expect(run.result.elementVerified, isTrue);
    });

    test('and enters at onboarding when that is where it landed', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/onboarding', '/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));
      expect(run.driver.actions.first, 'tap onboarding.get_started');
    });

    test('and skips onboarding when it landed on the login form', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));
      expect(run.driver.actions, isNot(contains('tap onboarding.get_started')));
      expect(run.result.succeeded, isTrue);
    });
  });

  group('an already-authenticated device', () {
    test('verifies without logging in again', () async {
      final run = await _run(ScriptedDriver(routes: ['/home']));

      expect(run.result.succeeded, isTrue);
      expect(run.result.loginPerformed, isFalse);
      expect(
        run.driver.actions,
        isEmpty,
        reason: 'no tap and no credential on an already-authenticated device',
      );
    });

    test('and no secret is resolved at all', () async {
      // The value must be in memory only for the interaction that needs
      // it, and on this path there is no such interaction.
      final run = await _run(ScriptedDriver(routes: ['/home']));
      expect(run.result.secretsUsed, isEmpty);
    });
  });

  group('failures', () {
    test('a missing secret stops before anything is driven', () async {
      final run = await _run(
        ScriptedDriver(routes: ['/login', '/home']),
        secrets: const {'MYTEST_AUTH_MOBILE': _seededMobile},
      );

      expect(run.result.failure, AuthSetupFailure.secretMissing);
      expect(run.result.exitCode, 2);
      expect(run.driver.actions, isEmpty);
    });

    test(
        'an invalid credential is classified from the application own error '
        'state', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/secure-login'],
        exchange: const ApiExpectationOutcome(
          endpoint: 'POST /login/consumer',
          status: 401,
          failures: ['expected 200, received 401'],
        ),
      ));

      expect(run.result.failure, AuthSetupFailure.invalidCredential);
    });

    test('a missing element is LOGIN_UI_NOT_FOUND', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/home'],
        missingElements: {'secure_login.pin_field'},
        exchange: _ok(),
      ));

      expect(run.result.failure, AuthSetupFailure.loginUiNotFound);
    });

    test('landing on /set-location is not called an auth failure', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/set-location'],
        exchange: _ok(),
      ));

      expect(run.result.failure, AuthSetupFailure.authenticatedStateNotReached);
      expect(run.result.remedy, isNotEmpty);
    });

    test('a different application is an environment failure', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/home'],
        appId: 'com.example.other',
      ));

      expect(run.result.failure, AuthSetupFailure.environmentPrerequisite);
    });
  });

  group('cleanup', () {
    test('the session is disposed after success', () async {
      final run = await _run(ScriptedDriver(routes: ['/home']));
      expect(run.driver.disposed, isTrue);
    });

    test('and after a failure', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/set-location'],
        exchange: _ok(),
      ));
      expect(run.driver.disposed, isTrue);
    });

    test('and after a missing secret, which never drove anything', () async {
      final run = await _run(
        ScriptedDriver(routes: ['/login']),
        secrets: const {},
      );
      expect(run.result.failure, AuthSetupFailure.secretMissing);
      expect(run.driver.disposed, isTrue);
    });
  });

  group('leakage', () {
    test('no credential reaches the log', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/onboarding', '/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));

      final text = run.log.join('\n');
      expect(text, isNot(contains(_seededPin)));
      expect(text, isNot(contains(_seededMobile)));
      expect(text, contains('env:MYTEST_AUTH_PIN'));
    });

    test('nor the recorded actions', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));

      final text = run.driver.actions.join('\n');
      expect(text, isNot(contains(_seededPin)));
      expect(text, contains(redactionMarker));
    });

    test('nor the result, on any path', () async {
      for (final driver in [
        ScriptedDriver(routes: ['/home']),
        ScriptedDriver(
          routes: ['/login', '/secure-login', '/home'],
          exchange: _ok(),
        ),
        ScriptedDriver(
          routes: ['/login', '/secure-login', '/secure-login'],
          exchange: _ok(),
        ),
      ]) {
        final run = await _run(driver);
        final text = run.result.toJson().toString();
        expect(text, isNot(contains(_seededPin)));
        expect(text, isNot(contains(_seededMobile)));
      }
    });
  });

  group('the reason a state was not reached names the term that failed', () {
    // Measured on a real device: a run that reached /home but whose
    // verify element was absent reported `ended on "/home" rather than
    // "/home"` - a sentence that names no defect and points nowhere.
    test('the right route without its element does not blame the route',
        () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/home'],
        exchange: _ok(),
        presentElements: const {'secure_login.pin_error'},
      ));

      expect(run.result.succeeded, isFalse);
      expect(run.result.detail, isNot(contains('"/home" rather than "/home"')));
      expect(run.result.detail, contains('home.body'));
      expect(run.result.detail, contains('without the screen behind it'));
    });

    test('a genuinely wrong route still names both routes', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/set-location'],
        exchange: _ok(),
      ));

      expect(run.result.succeeded, isFalse);
      expect(run.result.detail, contains('/set-location'));
      expect(run.result.detail, contains('/home'));
    });

    test('a guest who browsed to the authenticated route is named as one',
        () async {
      // Starts on /home, so no login is performed - but the
      // application's own navigation history passed /login on the way.
      // Reaching /home that way is a guest browsing, not a session.
      final run = await _run(ScriptedDriver(
        routes: ['/home'],
        seededHistory: const ['/login'],
      ));

      expect(run.result.succeeded, isFalse);
      expect(run.result.detail, contains('without signing in'));
      expect(run.result.detail, contains('/login'));
    });
  });

  group('a step that does not complete is a verdict, not an exception', () {
    // Measured on a real device against a backend that rejected the
    // login: the application sat on its error state, never settled, and
    // the StateError escaped the runner entirely - exit 255, a stack
    // trace, no classification, no remedy and no artefact.
    test('a stalled step is classified rather than raised', () async {
      final run = await _run(StallingDriver(
        routes: ['/login', '/secure-login', '/secure-login'],
        presentElements: const {},
      ));

      expect(run.result.succeeded, isFalse);
      expect(run.result.exitCode, 2);
      expect(run.result.failure, AuthSetupFailure.authFlowFailed);
      expect(run.result.detail, contains('did not settle'));
    });

    test('and the session is still disposed', () async {
      final run = await _run(StallingDriver(
        routes: ['/login', '/secure-login', '/secure-login'],
        presentElements: const {},
      ));
      expect(run.driver.disposed, isTrue);
    });

    test('a rejected credential outranks the stall it caused', () async {
      // The application said the credential was wrong *and* never
      // settled. "That credential was wrong" is the useful sentence.
      final run = await _run(StallingDriver(
        routes: ['/login', '/secure-login', '/secure-login'],
        presentElements: const {'secure_login.pin_error'},
      ));

      expect(run.result.failure, AuthSetupFailure.invalidCredential);
    });

    test('a stalled flow never reports success', () async {
      final run = await _run(StallingDriver(
        routes: ['/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));
      expect(run.result.succeeded, isFalse);
    });
  });

  group('DEF-E05-01 - a transient splash is not an authenticated state', () {
    // Measured twice on a Samsung SM-M127G against an external
    // application, on a device whose data had just been cleared: the runner
    // sampled the route at handshake, read the splash "/", concluded
    // "already authenticated; no credential will be used", and never
    // attempted a login. routeHistory was ["/", "/onboarding"],
    // loginPerformed false, secretsUsed [].
    test('the runner waits for the router to settle, then drives login',
        () async {
      final run = await _run(SplashDriver(
        routes: ['/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));

      expect(run.log.any((l) => l.contains('already authenticated')), isFalse,
          reason: 'a splash was read as a session');
      expect(run.result.loginPerformed, isTrue,
          reason: 'no credential was entered on a signed-out device');
      // The recorded action names the field and the marker, never the
      // value - asserted here as well as in the leakage group.
      expect(
        run.driver.actions,
        contains(startsWith('inputSecret login.mobile_field')),
      );
      expect(run.driver.actions.first, contains(redactionMarker));
      expect(run.result.succeeded, isTrue);
    });

    test('a splash that resolves to onboarding enters the onboarding block',
        () async {
      final run = await _run(SplashDriver(
        routes: ['/onboarding', '/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));

      expect(run.driver.actions.first, 'tap onboarding.get_started');
      expect(run.result.succeeded, isTrue);
    });

    test('the authenticated route is still recognised without a login',
        () async {
      final run = await _run(SplashDriver(routes: ['/home']));

      expect(run.result.succeeded, isTrue);
      expect(run.result.loginPerformed, isFalse);
      expect(run.result.secretsUsed, isEmpty);
    });

    test('a route the file does not recognise is a failure, not a session',
        () async {
      final run = await _run(StuckDriver(stuckOn: '/set-location'));

      expect(run.result.succeeded, isFalse,
          reason: 'an unrecognised route was accepted as authenticated');
      expect(run.result.loginPerformed, isFalse);
      expect(run.log.any((l) => l.contains('already authenticated')), isFalse);
      expect(run.result.detail, contains('/set-location'));
    });
  });
}
