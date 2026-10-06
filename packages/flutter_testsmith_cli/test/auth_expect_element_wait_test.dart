// An auth flow's `expectElement` read the tree once and dropped its
// deadline.
//
// `timeoutMs` parsed, reached the step, and was never used: the runner
// called `hasElement`, a single read. That is the same race DEF-E05-05
// was - the route event arrives before the screen behind it renders -
// and it is worse here, because the failure is classified as
// LOGIN_UI_NOT_FOUND and blames the application's test ids for a screen
// that was simply still arriving.
//
// The fix is the bounded wait already on the interface. Nothing new: the
// runner asks for the element within the deadline the author declared,
// and gets an answer the moment it appears.
import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/auth_runner.dart';
import 'package:flutter_testsmith/engine.dart';

const String _yaml = '''
auth: t
app: {path: .}
appId: com.example.package
device: {profile: p}
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/login]
login:
  - expectScreen: {id: /login}
  - expectElement: {id: login.form, timeoutMs: 7000}
  - inputSecret: {id: login.pin, secret: pin}
verify:
  route: /home
  element: home.body
  timeoutMs: 30000
''';

final AuthFile _file = AuthFile.parse(_yaml, source: 'auth.yaml');

class _Resolver implements SecretResolver {
  @override
  bool isPresent(SecretRef ref) => true;

  @override
  Secret resolve(SecretRef ref) => const Secret('0000');
}

/// Records how each element was asked for, and when it appears.
class _Driver implements AuthDriver {
  _Driver({this.appearsAfter = 0, this.neverAppears = false});

  /// How many asks it takes before `login.form` is in the tree.
  final int appearsAfter;
  final bool neverAppears;

  final List<({String id, Duration? timeout})> asks = [];
  int _formAsks = 0;

  @override
  Future<String?> currentRoute() async => '/login';

  @override
  List<String> routeHistory() => const ['/login'];

  @override
  Future<void> tap(String elementId) async {}

  @override
  Future<void> inputSecret(String elementId, Secret secret) async {}

  @override
  Future<void> waitForSettle(Duration timeout, QuiescencePolicy policy) async {}

  @override
  Future<void> awaitRoute(String route, Duration timeout) async {}

  bool _present(String id) {
    if (id != 'login.form') return false;
    if (neverAppears) return false;
    return _formAsks++ >= appearsAfter;
  }

  @override
  Future<bool> hasElement(String elementId) async {
    asks.add((id: elementId, timeout: null));
    return _present(elementId);
  }

  @override
  Future<bool> awaitElement(String elementId, Duration timeout) async {
    asks.add((id: elementId, timeout: timeout));
    // The real waiter polls to the deadline; this one answers as the
    // real one would once the element has appeared.
    for (var attempt = 0; attempt <= appearsAfter; attempt++) {
      if (_present(elementId)) return true;
    }
    return false;
  }

  @override
  Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step) async => null;

  @override
  Future<({String? appId, String? version, String? buildMode})>
      identity() async => (appId: null, version: null, buildMode: null);

  @override
  Future<void> dispose() async {}
}

Future<AuthSetupResult> _run(_Driver driver) => AuthRunner(
      file: _file,
      secrets: _Resolver(),
      driver: driver,
      log: (_) {},
      routeSettleTimeout: const Duration(milliseconds: 20),
    ).run();

/// How `login.form` was asked for, ignoring the verify-block's own ask.
({String id, Duration? timeout}) _formAsk(_Driver driver) =>
    driver.asks.firstWhere((ask) => ask.id == 'login.form');

void main() {
  test('the step waits rather than reading the tree once', () async {
    final driver = _Driver();
    await _run(driver);

    expect(_formAsk(driver).timeout, isNotNull,
        reason: 'a single read races the screen it is asserting about');
  });

  test('the declared timeout is the one used', () async {
    final driver = _Driver();
    await _run(driver);

    expect(_formAsk(driver).timeout, const Duration(milliseconds: 7000));
  });

  test('an element that renders a moment late is still found', () async {
    final driver = _Driver(appearsAfter: 3);
    final result = await _run(driver);

    expect(result.failure, isNot(AuthSetupFailure.loginUiNotFound),
        reason: 'the element appeared within its deadline');
  });

  test('an element that never appears is still a missing login UI',
      () async {
    final driver = _Driver(neverAppears: true);
    final result = await _run(driver);

    expect(result.failure, AuthSetupFailure.loginUiNotFound);
    expect(result.detail, contains('login.form'));
  });

  test('a missing element stops the flow before a credential is typed',
      () async {
    final driver = _Driver(neverAppears: true);
    final result = await _run(driver);

    expect(result.secretsUsed, isEmpty,
        reason: 'the step after it types a PIN');
  });

  test('the verify block keeps its own element and its own deadline',
      () async {
    final driver = _Driver();
    await _run(driver);

    final verifyAsk = driver.asks.firstWhere((ask) => ask.id == 'home.body');
    expect(verifyAsk.timeout, const Duration(milliseconds: 30000));
  });
}
