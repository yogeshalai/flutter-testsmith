// `expectScreen` had one reading of the route and two ways to be wrong.
//
// The audit behind these tests found something that changes what can
// honestly be built here. There are two places a route name can be read:
//
//   R1  `SessionManager.currentScreenId` - rebuilt by the engine from
//       the navigation events it has received over the VM Service;
//   R2  `UiSnapshot.screenId` - the application's own `_currentScreenId`
//       read live at capture time.
//
// Both trace to the same line: `TestNavigatorObserver.resolveScreenId`.
// They are the same source sampled at two points through two transports,
// **not** two independent witnesses. And the captured tree cannot supply
// a third: `routeIndex` is an ordinal, so a capture can say "two routes
// are built and the second is on top" and can never say "the second one
// is /home".
//
// So this does not pretend to corroborate route identity. What it does
// is stop a *lagging or lost event* from failing a test that is sitting
// on exactly the screen it asked for - R2 is the fresher sample of the
// same variable - and make the timeout name every reading instead of
// one.
import 'dart:async';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/flow_executor.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const LogicalRect _box = LogicalRect(x: 0, y: 0, width: 100, height: 40);

UiNode _node(String type, {String? testId, Object? routeIndex}) => UiNode(
      testId: testId,
      type: type,
      visible: true,
      bounds: _box,
      properties: {'routeIndex': ?routeIndex},
    );

UiSnapshot _snapshot(String screenId, {List<UiNode> children = const []}) =>
    UiSnapshot(
      screenId: screenId,
      capturedAt: DateTime.utc(2026, 9, 16),
      devicePixelRatio: 2,
      root: UiNode(
        type: 'Scaffold',
        visible: true,
        bounds: _box,
        children: children,
      ),
    );

/// A router whose reported route follows a script, one step per read.
class _Router {
  _Router(this._routes);

  final List<String?> _routes;
  int reads = 0;

  String? read() {
    final route = _routes[reads < _routes.length ? reads : _routes.length - 1];
    reads++;
    return route;
  }
}

/// Counts captures, so "one capture, on the failing path" is measurable.
class _Capture {
  _Capture(this._snapshot);

  final UiSnapshot _snapshot;
  int taken = 0;

  Future<UiSnapshot> call() async {
    taken++;
    return _snapshot;
  }
}

Future<void> _await({
  required String screenId,
  required String? Function() router,
  Future<UiSnapshot> Function()? capture,
  List<String> visited = const [],
  Duration timeout = const Duration(milliseconds: 40),
}) =>
    awaitScreenEvidence(
      screenId: screenId,
      timeout: timeout,
      routerRoute: router,
      screensVisited: () => visited,
      capture: capture,
      pollInterval: const Duration(milliseconds: 1),
    );

void main() {
  group('A - the router already reports the requested screen', () {
    test('it passes', () async {
      await _await(screenId: '/home', router: () => '/home');
    });

    test('no capture is taken when the event stream already agrees', () async {
      // The cheap path stays cheap: walking the element tree of a real
      // application is not something to do every 100ms for a route that
      // has already arrived.
      final capture = _Capture(_snapshot('/home'));
      await _await(
        screenId: '/home',
        router: () => '/home',
        capture: capture.call,
      );

      expect(capture.taken, 0);
    });
  });

  group('D then A - the screen arrives during the wait', () {
    test('it waits, then passes', () async {
      final router = _Router(['/login', '/login', '/home']);
      await _await(
        screenId: '/home',
        router: router.read,
        timeout: const Duration(seconds: 5),
      );

      expect(router.reads, 3);
    });

    test('it returns as soon as the route arrives, not at the deadline',
        () async {
      final router = _Router(['/login', '/home']);
      final watch = Stopwatch()..start();
      await _await(
        screenId: '/home',
        router: router.read,
        timeout: const Duration(seconds: 30),
      );
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('C - the event stream lagged or lost the navigation', () {
    test('the application\'s own reading is accepted', () async {
      // The application says it is on /home. The engine never received
      // the event. Failing here would blame the application for a
      // screen it plainly reached.
      await _await(
        screenId: '/home',
        router: () => '/login',
        capture: _Capture(_snapshot('/home')).call,
      );
    });

    test('exactly one capture is taken, not one per poll', () async {
      final capture = _Capture(_snapshot('/home'));
      await _await(
        screenId: '/home',
        router: () => '/login',
        capture: capture.call,
        timeout: const Duration(milliseconds: 40),
      );

      expect(capture.taken, 1);
    });
  });

  group('F - the disagreement survives the deadline', () {
    test('it fails, bounded', () async {
      await expectLater(
        _await(
          screenId: '/home',
          router: () => '/secure-login',
          capture: _Capture(_snapshot('/secure-login')).call,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the message names both readings', () async {
      try {
        await _await(
          screenId: '/home',
          router: () => '/secure-login',
          capture: _Capture(_snapshot('/otp')).call,
        );
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, contains('/home'));
        expect(error.message, contains('/secure-login'));
        expect(error.message, contains('/otp'));
      }
    });

    test('the message names the screens visited', () async {
      try {
        await _await(
          screenId: '/home',
          router: () => '/login',
          visited: ['/', '/login'],
        );
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, contains('/ -> /login'));
      }
    });

    test('it counts the routes the capture found built', () async {
      // Structural evidence the tree genuinely can supply: how many
      // routes are built. Never identity - an ordinal cannot name a
      // screen - so this is reported and never used for the verdict.
      try {
        await _await(
          screenId: '/home',
          router: () => '/login',
          capture: _Capture(
            _snapshot('/login', children: [
              _node('Scaffold', routeIndex: 1),
              _node('AlertDialog', routeIndex: 2),
            ]),
          ).call,
        );
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, contains('2'));
      }
    });

    test('the wait is bounded by the declared timeout', () async {
      final watch = Stopwatch()..start();
      try {
        await _await(
          screenId: '/home',
          router: () => '/login',
          timeout: const Duration(milliseconds: 60),
        );
      } on StateError {
        // expected
      }
      watch.stop();

      expect(watch.elapsed.inMilliseconds, greaterThanOrEqualTo(50));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('E - the capture cannot describe routes', () {
    test('a tree with no route indices says so rather than inventing one',
        () async {
      try {
        await _await(
          screenId: '/home',
          router: () => '/login',
          capture: _Capture(
            _snapshot('/login', children: [_node('Scaffold')]),
          ).call,
        );
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, contains('no routes'));
      }
    });

    test('a malformed route index is not turned into a route', () async {
      try {
        await _await(
          screenId: '/home',
          router: () => '/login',
          capture: _Capture(
            _snapshot('/login', children: [
              _node('Scaffold', routeIndex: 'two'),
            ]),
          ).call,
        );
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, contains('no routes'));
      }
    });

    test('no capture available still gives the router reading', () async {
      try {
        await _await(screenId: '/home', router: () => '/login');
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, contains('/login'));
      }
    });

    test('a capture that never answers cannot delay the real failure',
        () async {
      // `VmServiceTransport.invoke` has no timeout of its own, so an
      // application that has stopped answering would otherwise turn a
      // bounded failure into a hang - on the diagnostic, which is the
      // least important part of it.
      final watch = Stopwatch()..start();
      try {
        await awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(milliseconds: 20),
          routerRoute: () => '/login',
          screensVisited: () => const [],
          capture: () => Completer<UiSnapshot>().future,
          captureTimeout: const Duration(milliseconds: 30),
          pollInterval: const Duration(milliseconds: 1),
        );
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, contains('/login'));
      }
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the capture was awaited without a bound');
    });

    test('a capture that throws does not replace the real failure',
        () async {
      // Teardown-style discipline: the route that never arrived is the
      // finding. A broken capture is a footnote, not a new exception.
      try {
        await _await(
          screenId: '/home',
          router: () => '/login',
          capture: () async => throw StateError('vm service died'),
        );
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, contains('/home'));
        expect(error.message, contains('/login'));
      }
    });
  });

  group('a lost event stream is not "the app did not navigate"', () {
    test('a healthy connection on the wrong route waits normally', () async {
      // Quiet and healthy is the ordinary case, and must stay ordinary.
      final watch = Stopwatch()..start();
      try {
        await awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(milliseconds: 60),
          routerRoute: () => '/login',
          screensVisited: () => const [],
          liveness: () => TransportLiveness.healthy,
          pollInterval: const Duration(milliseconds: 1),
        );
        fail('returned');
      } on StateError {
        // expected: the assertion timed out, which is correct
      }
      watch.stop();

      expect(watch.elapsed.inMilliseconds, greaterThanOrEqualTo(50),
          reason: 'a healthy connection must be given its full deadline');
    });

    test('a healthy connection on the right route still passes', () async {
      await awaitScreenEvidence(
        screenId: '/home',
        timeout: const Duration(milliseconds: 40),
        routerRoute: () => '/home',
        screensVisited: () => const [],
        liveness: () => TransportLiveness.healthy,
        pollInterval: const Duration(milliseconds: 1),
      );
    });

    test('a lost connection fails without waiting out the deadline',
        () async {
      final watch = Stopwatch()..start();
      await expectLater(
        awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(seconds: 30),
          routerRoute: () => '/login',
          screensVisited: () => const [],
          liveness: () => TransportLiveness.disconnected,
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TransportDisconnectedException>()),
      );
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'it waited on a stream that had already died');
    });

    test('a stale but matching route does not pass once the stream died',
        () async {
      // The defect in one line. The last route heard about was /home;
      // the engine then stopped listening. Reporting PASS here is
      // exactly "the engine stopped receiving events" being read as
      // "the application navigated".
      await expectLater(
        awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(milliseconds: 40),
          routerRoute: () => '/home',
          screensVisited: () => const [],
          liveness: () => TransportLiveness.disconnected,
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TransportDisconnectedException>()),
      );
    });

    test('the diagnostic blames the connection, not the application',
        () async {
      try {
        await awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(milliseconds: 40),
          routerRoute: () => '/login',
          screensVisited: () => const [],
          liveness: () => TransportLiveness.disconnected,
          pollInterval: const Duration(milliseconds: 1),
        );
        fail('returned');
      } on TransportDisconnectedException catch (error) {
        expect('$error', contains('lost'));
      }
    });

    test('callers that pass no liveness behave exactly as before',
        () async {
      // Every existing call site keeps working unchanged.
      await awaitScreenEvidence(
        screenId: '/home',
        timeout: const Duration(milliseconds: 40),
        routerRoute: () => '/home',
        screensVisited: () => const [],
        pollInterval: const Duration(milliseconds: 1),
      );
    });
  });

  group('an uninterpretable event stream is not "nothing happened"', () {
    test('an intact stream on the right route passes', () async {
      await awaitScreenEvidence(
        screenId: '/home',
        timeout: const Duration(milliseconds: 40),
        routerRoute: () => '/home',
        screensVisited: () => const [],
        liveness: () => TransportLiveness.healthy,
        protocol: () => const ProtocolObservation.intact(),
        pollInterval: const Duration(milliseconds: 1),
      );
    });

    test('an intact stream on the wrong route waits normally', () async {
      final watch = Stopwatch()..start();
      try {
        await awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(milliseconds: 60),
          routerRoute: () => '/login',
          screensVisited: () => const [],
          liveness: () => TransportLiveness.healthy,
          protocol: () => const ProtocolObservation.intact(),
          pollInterval: const Duration(milliseconds: 1),
        );
        fail('returned');
      } on StateError {
        // expected: an ordinary assertion timeout
      }
      watch.stop();

      expect(watch.elapsed.inMilliseconds, greaterThanOrEqualTo(50));
    });

    test('a broken stream fails without waiting out the deadline', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(seconds: 30),
          routerRoute: () => '/login',
          screensVisited: () => const [],
          liveness: () => TransportLiveness.healthy,
          protocol: () =>
              const ProtocolObservation.broken('SCREEN_ENTER had no screenId'),
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<ProtocolObservationException>()),
      );
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a stale matching route does not pass once decoding broke',
        () async {
      // The defect stated exactly. The last SCREEN_ENTER the engine
      // could read said /home; the ones after it were unreadable. PASS
      // here is "the engine stopped understanding" reported as "the
      // application arrived".
      await expectLater(
        awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(milliseconds: 40),
          routerRoute: () => '/home',
          screensVisited: () => const [],
          protocol: () => const ProtocolObservation.broken('bad payload'),
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<ProtocolObservationException>()),
      );
    });

    test('the diagnostic names the schema problem, not the application',
        () async {
      try {
        await awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(milliseconds: 40),
          routerRoute: () => '/login',
          screensVisited: () => const [],
          protocol: () =>
              const ProtocolObservation.broken('protocol 2.0 is incompatible'),
          pollInterval: const Duration(milliseconds: 1),
        );
        fail('returned');
      } on ProtocolObservationException catch (error) {
        expect('$error', contains('interpret'));
        expect('$error', contains('protocol 2.0'));
      }
    });

    test('a broken protocol is reported ahead of a lost connection',
        () async {
      // Both are true when an app dies mid-stream. The decode failure
      // happened while connected, so it is the cause and the disconnect
      // is the consequence.
      await expectLater(
        awaitScreenEvidence(
          screenId: '/home',
          timeout: const Duration(milliseconds: 40),
          routerRoute: () => '/login',
          screensVisited: () => const [],
          liveness: () => TransportLiveness.disconnected,
          protocol: () => const ProtocolObservation.broken('bad payload'),
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<ProtocolObservationException>()),
      );
    });

    test('callers that pass no protocol state behave exactly as before',
        () async {
      await awaitScreenEvidence(
        screenId: '/home',
        timeout: const Duration(milliseconds: 40),
        routerRoute: () => '/home',
        screensVisited: () => const [],
        pollInterval: const Duration(milliseconds: 1),
      );
    });
  });

  group('the router reporting nothing at all', () {
    test('is named rather than rendered as null', () async {
      try {
        await _await(screenId: '/home', router: () => null);
        fail('a disagreement passed');
      } on StateError catch (error) {
        expect(error.message, isNot(contains('null')));
      }
    });
  });
}
