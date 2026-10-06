// Auth setup blamed the application for the engine going blind.
//
// `AuthRunner` wrapped both of its driving phases in `on Object`. The
// login block turned everything into AUTH_FLOW_FAILED; the `verify.route`
// wait swallowed everything and let the route decide, which reads as
// AUTHENTICATED_STATE_NOT_REACHED. Both sentences are claims about the
// application's authentication: one says a login step did not complete,
// the other says the app authenticated and then failed to arrive.
//
// Neither is true when the device went to sleep, the app was killed, the
// VM Service stopped answering, or the two sides were built from
// different versions of this platform. In every one of those the honest
// statement is that Testing Tool could not observe the application - the
// same thing E-04 exists to say, and the same distinction the normal run
// path has drawn since the transport gained typed failures.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/auth_runner.dart';
import 'package:flutter_testsmith/engine.dart';

/// The driver adapter's source, wherever the suite was launched from.
String adapterSource() {
  for (final candidate in [
    'lib/src/cli/commands/auth_command.dart',
    'packages/flutter_testsmith/lib/src/cli/commands/auth_command.dart',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find auth_command.dart');
}

const String _seededPin = 'SEEDED_PIN_9f2a41c8';

const String _yaml = '''
auth: t
app: {path: .}
appId: com.example.package
device: {profile: p}
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/login]
login:
  - expectScreen: {id: /login}
  - inputSecret: {id: login.pin, secret: pin}
  - tap: {id: login.submit}
verify:
  route: /home
  element: home.body
  timeoutMs: 200
''';

final AuthFile _file = AuthFile.parse(_yaml, source: 'auth.yaml');

class _Resolver implements SecretResolver {
  @override
  bool isPresent(SecretRef ref) => true;

  @override
  Secret resolve(SecretRef ref) => const Secret(_seededPin);
}

/// Where in the lifecycle the driver should fail.
enum FailAt { never, loginRoute, verifyRoute, verifyElement }

class _Driver implements AuthDriver {
  _Driver({
    this.failAt = FailAt.never,
    this.error,
    this.route = '/login',
    this.arrivesAt = '/home',
    this.elementPresent = true,
  });

  final FailAt failAt;
  final Object? error;
  final String route;
  final String arrivesAt;
  final bool elementPresent;

  bool _loggedIn = false;

  @override
  Future<String?> currentRoute() async => _loggedIn ? arrivesAt : route;

  @override
  List<String> routeHistory() => [route, if (_loggedIn) arrivesAt];

  @override
  Future<void> tap(String elementId) async {
    _loggedIn = true;
  }

  @override
  Future<void> inputSecret(String elementId, Secret secret) async {}

  @override
  Future<void> waitForSettle(Duration timeout, QuiescencePolicy policy) async {}

  @override
  Future<void> awaitRoute(String wanted, Duration timeout) async {
    if (failAt == FailAt.loginRoute && wanted == '/login') throw error!;
    if (failAt == FailAt.verifyRoute && wanted == '/home') throw error!;
  }

  @override
  Future<bool> hasElement(String elementId) async => elementPresent;

  @override
  Future<bool> awaitElement(String elementId, Duration timeout) async {
    if (failAt == FailAt.verifyElement) throw error!;
    return elementPresent;
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

/// Every infrastructure failure the transport can now raise.
final List<({String name, Object error})> _infrastructure = [
  (
    name: 'an unanswered RPC',
    error: const TransportTimeoutException(
      operation: 'ext.mytest.uiTree',
      timeout: Duration(seconds: 30),
    ),
  ),
  (
    name: 'a lost connection',
    error: const TransportDisconnectedException(
      TransportLiveness.disconnected,
    ),
  ),
  (
    name: 'an unreadable event stream',
    error: const ProtocolObservationException('protocol 2.0 is incompatible'),
  ),
  // Not the transport, and the same answer: the handset stopped
  // answering adb (132d8cd bounded the wait), so nothing about the login
  // was established. Of the three phases below, only logging in drives
  // adb for real - taps go through it. The verify waits read the VM
  // service, so the "while verifying" and "waiting for the element"
  // cases prove the runner's classification, not that a real session can
  // raise this there.
  (
    name: 'a device that stopped answering',
    error: const DeviceTimeoutException(
      command: 'adb -s S1 shell input tap 1 2',
      timeout: Duration(seconds: 30),
      stopped: true,
    ),
  ),
];

void main() {
  group('an infrastructure failure is never an authentication verdict', () {
    for (final failure in _infrastructure) {
      test('${failure.name}, while verifying, is not a state failure',
          () async {
        final result = await _run(
          _Driver(failAt: FailAt.verifyRoute, error: failure.error),
        );

        expect(result.failure,
            isNot(AuthSetupFailure.authenticatedStateNotReached));
        expect(result.failure, AuthSetupFailure.observationFailed);
      });

      test('${failure.name}, while logging in, is not a flow failure',
          () async {
        final result = await _run(
          _Driver(failAt: FailAt.loginRoute, error: failure.error),
        );

        expect(result.failure, isNot(AuthSetupFailure.authFlowFailed));
        expect(result.failure, AuthSetupFailure.observationFailed);
      });

      test('${failure.name}, while waiting for the element, is the same '
          'classification', () async {
        final result = await _run(
          _Driver(failAt: FailAt.verifyElement, error: failure.error),
        );

        expect(result.failure, AuthSetupFailure.observationFailed);
      });
    }

    test('both phases now classify it the same way', () async {
      // The inconsistency the audit found: the same disconnect produced
      // two different application claims depending on when it happened.
      const error =
          TransportDisconnectedException(TransportLiveness.disconnected);
      final login =
          await _run(_Driver(failAt: FailAt.loginRoute, error: error));
      final verify =
          await _run(_Driver(failAt: FailAt.verifyRoute, error: error));

      expect(login.failure, verify.failure);
    });
  });

  group('the original cause survives into the report', () {
    test('a timeout keeps its operation and deadline', () async {
      final result = await _run(
        _Driver(
          failAt: FailAt.verifyRoute,
          error: const TransportTimeoutException(
            operation: 'ext.mytest.uiTree',
            timeout: Duration(seconds: 30),
          ),
        ),
      );

      expect(result.detail, contains('ext.mytest.uiTree'));
    });

    test('a protocol failure keeps what could not be read', () async {
      final result = await _run(
        _Driver(
          failAt: FailAt.loginRoute,
          error: const ProtocolObservationException('SCREEN_ENTER had no id'),
        ),
      );

      expect(result.detail, contains('SCREEN_ENTER had no id'));
    });

    test('it carries a remedy, as every classification must', () async {
      final result = await _run(
        _Driver(
          failAt: FailAt.verifyRoute,
          error: const TransportDisconnectedException(
            TransportLiveness.disconnected,
          ),
        ),
      );

      expect(result.remedy, isNotEmpty);
    });

    test('it is still a failed run with the usual exit code', () async {
      final result = await _run(
        _Driver(
          failAt: FailAt.verifyRoute,
          error: const TransportDisconnectedException(
            TransportLiveness.disconnected,
          ),
        ),
      );

      expect(result.succeeded, isFalse);
      expect(result.exitCode, 2);
    });

    test('no credential reaches the diagnostic', () async {
      final result = await _run(
        _Driver(
          failAt: FailAt.verifyRoute,
          error: const TransportDisconnectedException(
            TransportLiveness.disconnected,
          ),
        ),
      );

      expect(result.detail, isNot(contains(_seededPin)));
      expect('${result.toJson()}', isNot(contains(_seededPin)));
    });
  });

  group('application failures keep their own classifications', () {
    test('a step that stalls is still an auth flow failure', () async {
      final result = await _run(
        _Driver(
          failAt: FailAt.loginRoute,
          error: StateError('the screen never settled'),
        ),
      );

      expect(result.failure, AuthSetupFailure.authFlowFailed);
      expect(result.detail, contains('never settled'));
    });

    test('a missing login element is still a missing login UI', () async {
      final result = await _run(
        _Driver(
          failAt: FailAt.loginRoute,
          error: const ElementNotFoundException(
            testId: 'login.pin',
            available: [],
          ),
        ),
      );

      expect(result.failure, AuthSetupFailure.loginUiNotFound);
    });

    test('a route that never arrives is still a state failure', () async {
      // No infrastructure error at all - the application simply stayed
      // where it was. This must keep saying so.
      final result = await _run(_Driver(arrivesAt: '/login'));

      expect(result.failure, AuthSetupFailure.authenticatedStateNotReached);
    });

    test('a verified element that never appears is still a state failure',
        () async {
      final result = await _run(_Driver(elementPresent: false));

      expect(result.failure, AuthSetupFailure.authenticatedStateNotReached);
    });
  });

  group('the paths that already worked are untouched', () {
    test('a successful login still succeeds', () async {
      final result = await _run(_Driver());

      expect(result.succeeded, isTrue);
      expect(result.failure, isNull);
      expect(result.loginPerformed, isTrue);
    });

    test('an already-authenticated device still needs no credential',
        () async {
      final result = await _run(_Driver(route: '/home'));

      expect(result.succeeded, isTrue);
      expect(result.loginPerformed, isFalse);
      expect(result.secretsUsed, isEmpty);
    });
  });

  group('the driver adapter does not absorb it on the way up', () {
    // `SessionAuthDriver` needs a handset, so its rules are asserted
    // against the source. Each of these three answered "no" on behalf of
    // an application it had failed to reach, and "no" is an observation.
    test('every broad catch in the adapter lets infrastructure through',
        () {
      final source = adapterSource();

      final broad = <String>[];
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!RegExp(r'\}\s*(on Object|catch)\s*(catch)?\s*\(').hasMatch(lines[i])) {
          continue;
        }
        // Wide enough to see past the comment that usually explains why
        // the distinction is being drawn.
        final window = lines.skip(i).take(18).join('\n');
        if (!window.contains('isInfrastructureFailure')) {
          broad.add('line ${i + 1}: ${lines[i].trim()}');
        }
      }

      expect(broad, isEmpty,
          reason: 'these catches would report an unreachable application '
              'as an answer about it:\n${broad.join('\n')}');
    });

    test('it uses the shared predicate rather than its own list', () {
      // One list of infrastructure types, in the transport that defines
      // them. A second copy here would drift the first time one is
      // added.
      expect(adapterSource(), contains('isInfrastructureFailure'));
    });
  });

  group('an unexpected programmer error keeps its existing behaviour', () {
    test('it is not swallowed into an infrastructure classification',
        () async {
      // Only the typed infrastructure failures are reclassified. A bug in
      // this codebase must keep surfacing as a bug rather than being
      // filed as a flaky device.
      await expectLater(
        _run(
          _Driver(
            failAt: FailAt.verifyElement,
            error: UnimplementedError('a bug in the runner'),
          ),
        ),
        throwsA(isA<UnimplementedError>()),
      );
    });
  });
}
