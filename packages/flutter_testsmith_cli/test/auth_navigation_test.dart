// DEF-E05-03 - an expectScreen that never arrives must fail.
//
// Measured on a Samsung SM-M127G against an external application:
// `SessionAuthDriver.awaitRoute` looped to its deadline and returned
// quietly, so a screen that never arrived went unreported. The flow
// carried on, typed a PIN into a screen that was not there, and the run
// failed as LOGIN_UI_NOT_FOUND - blaming the application's test ids for
// a navigation that never happened. The application had the ids.
//
// DEF-E05-02 is covered here too, from the runner's side: the declared
// policy must actually reach the driver, not merely parse.
import 'package:flutter_testsmith_cli/src/auth_runner.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:test/test.dart';

const String _authYaml = '''
auth: test
app: {path: ., target: lib/main.dart}
appId: com.example.app
device: {profile: samsung-m127g}
secrets:
  mobile: env:MYTEST_AUTH_MOBILE
  pin: env:MYTEST_AUTH_PIN
signedOutOn: [/onboarding, /login]
onboarding:
  - expectScreen: {id: /onboarding}
  - waitForSettle: {timeoutMs: 1000}
  - tap: {id: onboarding.get_started}
login:
  - expectScreen: {id: /login}
  - waitForSettle: {timeoutMs: 1000}
  - inputSecret: {id: login.mobile_field, secret: mobile}
  - tap: {id: login.continue_button}
  - expectScreen: {id: /secure-login, timeoutMs: 1000}
  - waitForSettle: {timeoutMs: 1000}
  - inputSecret: {id: secure_login.pin_field, secret: pin}
  - tap: {id: secure_login.continue_button}
quiescence:
  allow:
    - element: onboarding.illustration
      widget: Lottie
      reason: the onboarding illustration loops for ever by design
verify:
  route: /home
  element: home.body
  timeoutMs: 1000
  request: {endpoint: POST /login/consumer, status: 200}
''';

final AuthFile _file = AuthFile.parse(_authYaml, source: 'uat.yaml');

class MapResolver implements SecretResolver {
  const MapResolver(this._values);
  final Map<String, String> _values;

  @override
  bool isPresent(SecretRef ref) => (_values[ref.name] ?? '').isNotEmpty;

  @override
  Secret resolve(SecretRef ref) {
    final v = _values[ref.name];
    if (v == null || v.isEmpty) throw MissingSecretException(ref);
    return Secret(v);
  }
}

/// A driver whose router goes exactly where the script says, and which
/// records the quiescence policy it was handed.
class NavDriver implements AuthDriver {
  NavDriver({
    required this.script,
    this.present = const {'home.body'},
    this.elementAppearsAfterReads = 0,
  });

  /// How many reads return absent before the element renders - a
  /// landing screen that loads its own content after the route event.
  final int elementAppearsAfterReads;
  int _elementReads = 0;

  /// Route per currentRoute() call; the last entry repeats.
  final List<String> script;
  final Set<String> present;

  int _i = 0;
  final List<String> history = [];
  final List<String> actions = [];
  final List<QuiescencePolicy> policies = [];
  bool disposed = false;

  String get _current => script[_i];

  @override
  Future<String?> currentRoute() async {
    if (history.isEmpty || history.last != _current) history.add(_current);
    return _current;
  }

  @override
  List<String> routeHistory() => List.unmodifiable(history);

  @override
  Future<void> tap(String id) async => actions.add('tap $id');

  @override
  Future<void> inputSecret(String id, Secret secret) async =>
      actions.add('inputSecret $id $secret');

  @override
  Future<void> waitForSettle(Duration timeout, QuiescencePolicy policy) async {
    policies.add(policy);
  }

  @override
  Future<void> awaitRoute(String route, Duration timeout) async {
    if (_current == route) return;
    // The application navigates only where its own script goes. A route
    // the script never reaches is one that never arrives.
    if (_i + 1 < script.length && script[_i + 1] == route) {
      _i++;
      if (history.isEmpty || history.last != _current) history.add(_current);
      return;
    }
    // The real driver's behaviour after DEF-E05-03: a route that never
    // arrives is the finding, named with expected and actual.
    throw StateError(
      'expected to be on "$route" within ${timeout.inSeconds}s but the '
      'app is on "$_current". Screens visited: ${history.join(' -> ')}',
    );
  }

  @override
  Future<bool> hasElement(String id) async {
    if (_elementReads++ < elementAppearsAfterReads) return false;
    return present.contains(id);
  }

  @override
  Future<bool> awaitElement(String id, Duration timeout) async {
    // The real driver polls the tree to a deadline; this models it
    // without a clock, returning the moment the element renders.
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await hasElement(id)) return true;
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  @override
  Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step) async =>
      const ApiExpectationOutcome(
        endpoint: 'POST /login/consumer',
        status: 200,
        failures: [],
      );

  @override
  Future<({String? appId, String? version, String? buildMode})>
      identity() async => (appId: null, version: '1.0.6', buildMode: 'debug');

  @override
  Future<void> dispose() async => disposed = true;
}

Future<({AuthSetupResult result, NavDriver driver, List<String> log})> _run(
  NavDriver driver,
) async {
  final log = <String>[];
  final result = await AuthRunner(
    file: _file,
    secrets: const MapResolver({
      'MYTEST_AUTH_MOBILE': 'FAKE_MOBILE',
      'MYTEST_AUTH_PIN': 'FAKE_PIN',
    }),
    driver: driver,
    log: log.add,
    deviceModel: 'SM-M127G',
    routeSettleTimeout: const Duration(milliseconds: 400),
  ).run();
  return (result: result, driver: driver, log: log);
}

void main() {
  group('DEF-E05-03 - a route that never arrives is reported', () {
    test('the expected route arriving is still a success', () async {
      final run = await _run(NavDriver(
        script: ['/login', '/secure-login', '/home'],
      ));

      expect(run.result.succeeded, isTrue);
      expect(run.result.route, '/home');
      expect(run.result.loginPerformed, isTrue);
    });

    test('a route that never arrives fails, and is not blamed on an element',
        () async {
      // The shape of the measured run: the app stayed on /login
      // after the mobile number, so /secure-login never arrived.
      final run = await _run(NavDriver(script: ['/login']));

      expect(run.result.succeeded, isFalse);
      expect(run.result.failure, isNot(AuthSetupFailure.loginUiNotFound),
          reason: 'a navigation failure was reported as a missing element');
      expect(run.result.failure, AuthSetupFailure.authFlowFailed);
    });

    test('the diagnostic names the expected route, the actual one, and the '
        'timeout', () async {
      final run = await _run(NavDriver(script: ['/login']));

      expect(run.result.detail, contains('/secure-login'));
      expect(run.result.detail, contains('/login'));
      expect(run.result.detail, contains('within'));
    });

    test('a navigation failure is never reported as authenticated', () async {
      final run = await _run(NavDriver(script: ['/login']));
      expect(run.result.outcome, AuthSetupOutcome.failed);
      expect(run.result.route, isNot('/home'));
    });

    test('the session is still disposed', () async {
      final run = await _run(NavDriver(script: ['/login']));
      expect(run.driver.disposed, isTrue);
    });
  });

  group('DEF-E05-02 - the declared policy reaches the driver', () {
    test('every settle is given the policy the auth file declared',
        () async {
      final run = await _run(NavDriver(
        script: ['/login', '/secure-login', '/home'],
      ));

      expect(run.driver.policies, isNotEmpty);
      for (final policy in run.driver.policies) {
        expect(policy.allow, hasLength(1));
        expect(policy.allow.single.element, 'onboarding.illustration');
        expect(policy.allow.single.widget, 'Lottie');
      }
    });

    test('an auth file declaring nothing hands over an empty policy',
        () async {
      final bare = AuthFile.parse(
        _authYaml.replaceFirst(
          RegExp(r'quiescence:\n(?:.*\n)*?verify:', multiLine: true),
          'verify:',
        ),
        source: 'bare.yaml',
      );
      final driver = NavDriver(script: ['/login', '/secure-login', '/home']);
      await AuthRunner(
        file: bare,
        secrets: const MapResolver({
          'MYTEST_AUTH_MOBILE': 'FAKE_MOBILE',
          'MYTEST_AUTH_PIN': 'FAKE_PIN',
        }),
        driver: driver,
        log: (_) {},
        routeSettleTimeout: const Duration(milliseconds: 400),
      ).run();

      expect(driver.policies, isNotEmpty);
      for (final policy in driver.policies) {
        expect(policy.allow, isEmpty,
            reason: 'a file that declared nothing permitted something');
      }
    });
  });

  group('DEF-E05-05 - verify.element is waited for, not sampled', () {
    // Measured on a Samsung SM-M127G: /home arrived and the login
    // request answered 200, but the dashboard loads its own content
    // after the route event, so one read found no home.body and the run
    // reported AUTHENTICATED_STATE_NOT_REACHED on a real session.
    test('an element that renders after the route still authenticates',
        () async {
      final run = await _run(NavDriver(
        script: ['/login', '/secure-login', '/home'],
        elementAppearsAfterReads: 3,
      ));

      expect(run.result.succeeded, isTrue,
          reason: 'a late-rendering landing screen failed verification');
      expect(run.result.elementVerified, isTrue);
      expect(run.result.route, '/home');
    });

    test('an element already present still passes immediately', () async {
      final run = await _run(NavDriver(
        script: ['/login', '/secure-login', '/home'],
      ));
      expect(run.result.succeeded, isTrue);
      expect(run.result.elementVerified, isTrue);
    });

    test('RUN 2 - the already-authenticated path waits too, and performs '
        'no login', () async {
      // The path that proved this could not be fixed by configuration:
      // the login block is never driven, so there is nowhere in the auth
      // file to put a settle.
      final run = await _run(NavDriver(
        script: ['/home'],
        elementAppearsAfterReads: 3,
      ));

      expect(run.result.succeeded, isTrue);
      expect(run.result.loginPerformed, isFalse);
      expect(run.result.secretsUsed, isEmpty);
      expect(run.result.elementVerified, isTrue);
    });

    test('an element that never appears is still a deterministic failure',
        () async {
      final run = await _run(NavDriver(
        script: ['/login', '/secure-login', '/home'],
        elementAppearsAfterReads: 1 << 30,
      ));

      expect(run.result.succeeded, isFalse);
      expect(run.result.failure,
          AuthSetupFailure.authenticatedStateNotReached);
      expect(run.result.elementVerified, isFalse);
    });

    test('the diagnostic names the element, the expected route, the actual '
        'route and the timeout', () async {
      final run = await _run(NavDriver(
        script: ['/login', '/secure-login', '/home'],
        elementAppearsAfterReads: 1 << 30,
      ));

      expect(run.result.detail, contains('home.body'));
      expect(run.result.detail, contains('/home'));
      expect(run.result.detail, contains('s,'),
          reason: 'the timeout is not named');
      expect(run.result.detail, contains('Current route'));
    });

    test('a route failure is still reported as a route failure', () async {
      // The distinction DEF-E05-03 established must survive: never
      // arriving is not the same as arriving without the screen.
      final run = await _run(NavDriver(script: ['/login']));
      expect(run.result.failure, AuthSetupFailure.authFlowFailed);
      expect(run.result.detail, contains('/secure-login'));
    });
  });
}
