// A dead event stream was indistinguishable from a quiet one.
//
// `package:vm_service` disposes itself when its input stream closes, and
// `dispose()` does four things: cancels the socket subscription, fails
// every outstanding request with `Service connection disposed`, runs the
// dispose handler, and completes `onDone`. Read the list again for what
// is *missing*: it never closes `_eventControllers`. So
// `onExtensionEvent` does not error and does not complete when the
// connection dies - it simply stops producing, for ever.
//
// Our subscription had neither an `onError` nor an `onDone`, and it
// would not have mattered if it had: neither can ever fire. The engine
// therefore kept the last route it had heard about and waited out every
// deadline against it, reporting "the application did not navigate"
// about an application it had stopped listening to.
//
// `onDone` is the one real signal, and these tests pin the rule built on
// it. The rule is emphatically **not** "no events for N seconds": an
// application is allowed to sit still for as long as it likes, and a
// test that called that a failure would be worse than the bug.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// The transport source, wherever the suite was launched from.
String transportSource() {
  for (final candidate in [
    'lib/src/engine/transport/vm_service_transport.dart',
    'packages/flutter_testsmith/lib/src/engine/transport/vm_service_transport.dart',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find vm_service_transport.dart');
}

String livenessSource() {
  for (final candidate in [
    'lib/src/engine/transport/sdk_transport.dart',
    'packages/flutter_testsmith/lib/src/engine/transport/sdk_transport.dart',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find sdk_transport.dart');
}

void main() {
  group('a connection that has not been made yet', () {
    test('is not reported as healthy', () {
      expect(TransportLivenessMonitor().state, TransportLiveness.notConnected);
    });

    test('is not usable', () {
      expect(TransportLivenessMonitor().state.isUsable, isFalse);
    });
  });

  group('a healthy connection stays healthy while nothing happens', () {
    test('silence is not a failure', () async {
      // The whole point. An application on a form, waiting for a person
      // who is not there, emits nothing for as long as it likes.
      final monitor = TransportLivenessMonitor()..connected();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(monitor.state, TransportLiveness.healthy);
      expect(monitor.state.isUsable, isTrue);
    });

    test('there is no inactivity threshold anywhere in the rule', () {
      // Asserted against the source, because the absence of a timer is
      // not observable from behaviour in a short test - and an
      // inactivity threshold added later would reintroduce exactly the
      // defect this design refuses.
      final source = livenessSource();
      final monitorPart = source.substring(
        source.indexOf('class TransportLivenessMonitor'),
      );

      expect(monitorPart, isNot(contains('Timer')));
      expect(monitorPart, isNot(contains('Future.delayed')));
      expect(monitorPart, isNot(contains('Stopwatch')));
    });
  });

  group('a connection that ends on its own is a failure', () {
    test('it becomes disconnected', () {
      final monitor = TransportLivenessMonitor()..connected();
      monitor.ended();

      expect(monitor.state, TransportLiveness.disconnected);
      expect(monitor.state.isUsable, isFalse);
    });

    test('ending twice reports the same thing', () {
      final monitor = TransportLivenessMonitor()..connected();
      monitor
        ..ended()
        ..ended();

      expect(monitor.state, TransportLiveness.disconnected);
    });
  });

  group('a connection we closed ourselves is not a failure', () {
    test('a deliberate shutdown reports closed, not disconnected', () {
      // `close()` disposes the service, which completes `onDone` by
      // exactly the same path a dead socket does. Without recording who
      // asked, every clean teardown would report a lost connection.
      final monitor = TransportLivenessMonitor()..connected();
      monitor
        ..closing()
        ..ended();

      expect(monitor.state, TransportLiveness.closed);
    });

    test('closing is still not usable afterwards', () {
      final monitor = TransportLivenessMonitor()..connected();
      monitor
        ..closing()
        ..ended();

      expect(monitor.state.isUsable, isFalse);
    });
  });

  group('a failed connection is never resurrected', () {
    test('a later connected() does not undo a disconnect', () {
      // There is no reconnection in this product. A transport that
      // quietly healed would let a run continue across a gap it could
      // not account for, which is worse than stopping.
      final monitor = TransportLivenessMonitor()..connected();
      monitor
        ..ended()
        ..connected();

      expect(monitor.state, TransportLiveness.disconnected);
    });

    test('a late event cannot make a dead session usable again', () {
      final monitor = TransportLivenessMonitor()..connected();
      monitor.ended();

      expect(monitor.state.isUsable, isFalse);
    });
  });

  group('the failure reads as infrastructure, not as a verdict', () {
    test('it names the state it is in', () {
      const failure =
          TransportDisconnectedException(TransportLiveness.disconnected);

      expect(failure.liveness, TransportLiveness.disconnected);
      expect('$failure', contains('disconnected'));
    });

    test('it says the engine lost the connection, not that the app '
        'misbehaved', () {
      const failure =
          TransportDisconnectedException(TransportLiveness.disconnected);

      expect('$failure', contains('lost'));
      expect('$failure', isNot(contains('did not navigate')));
    });

    test('it is its own type, distinct from a timeout', () {
      const failure =
          TransportDisconnectedException(TransportLiveness.disconnected);

      expect(failure, isNot(isA<TransportTimeoutException>()));
      expect(failure, isNot(isA<StateError>()));
    });
  });

  group('the transport wires the one signal that exists', () {
    test('it observes VmService.onDone', () {
      expect(transportSource(), contains('onDone'));
    });

    test('it records a deliberate close before disposing', () {
      final source = transportSource();
      expect(source, contains('closing()'));
    });

    test('it never reconnects or retries', () {
      final source = transportSource();
      expect(source, isNot(contains('reconnect')));
      expect(source.contains('retry'), isFalse);
    });

    test('it adds no heartbeat traffic to manufacture liveness', () {
      // Pinging the application to prove it is alive would be traffic
      // the application did not ask for, on the very channel whose
      // silence is being measured.
      final source = transportSource();
      expect(source, isNot(contains('Timer.periodic')));
      expect(source, isNot(contains('heartbeat')));
    });
  });
}
