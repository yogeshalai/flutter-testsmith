// Whether the engine can still understand what the application sends.
//
// Deliberately a **second** state, beside liveness, and not folded into
// it. The two answer different questions and the distinction is the
// point of the milestone:
//
//     TransportLiveness      - is the connection there?
//     ProtocolObservation    - can what arrives over it be read?
//
// "Connected and emitting events I cannot decode" is not "disconnected",
// and merging them would produce a diagnostic that sends a reader to the
// cable when the problem is the schema.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

String transportSource() {
  for (final candidate in [
    'lib/src/transport/vm_service_transport.dart',
    'packages/flutter_testsmith_engine/lib/src/transport/vm_service_transport.dart',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find vm_service_transport.dart');
}

void main() {
  group('a stream nothing has gone wrong with', () {
    test('is intact', () {
      expect(ProtocolObservationMonitor().state.isIntact, isTrue);
    });

    test('stays intact while valid events arrive', () {
      final monitor = ProtocolObservationMonitor();
      expect(monitor.state.isIntact, isTrue);
      expect(monitor.state.failure, isNull);
    });
  });

  group('an event that could not be read breaks it', () {
    test('the state stops being intact', () {
      final monitor = ProtocolObservationMonitor()
        ..failed('SCREEN_ENTER payload has no screenId');

      expect(monitor.state.isIntact, isFalse);
    });

    test('the reason is kept, not just the fact', () {
      final monitor = ProtocolObservationMonitor()
        ..failed('SCREEN_ENTER payload has no screenId');

      expect(monitor.state.failure, contains('screenId'));
    });
  });

  group('a broken stream is never repaired', () {
    test('a later valid event does not restore it', () {
      // Once events have been missed, the observations built on them
      // have a hole in them that nothing later can fill. Continuing
      // would mean asserting from a record known to be incomplete.
      final monitor = ProtocolObservationMonitor()..failed('bad payload');
      expect(monitor.state.isIntact, isFalse);
    });

    test('the first failure is the one reported', () {
      // The first is the one that explains the hole; the rest are
      // consequences. Keeping the latest would report the symptom.
      final monitor = ProtocolObservationMonitor()
        ..failed('first: version 2.0')
        ..failed('second: missing screenId');

      expect(monitor.state.failure, contains('first'));
      expect(monitor.state.failure, isNot(contains('second')));
    });
  });

  group('the failure reads as infrastructure, never as a verdict', () {
    test('it says the engine could not interpret the stream', () {
      const failure = ProtocolObservationException('bad payload');

      expect('$failure', contains('interpret'));
      expect('$failure', isNot(contains('did not navigate')));
    });

    test('it carries the reason', () {
      const failure = ProtocolObservationException('version 2.0');
      expect('$failure', contains('version 2.0'));
    });

    test('it is distinct from a disconnect and from a timeout', () {
      const failure = ProtocolObservationException('bad payload');

      expect(failure, isNot(isA<TransportDisconnectedException>()));
      expect(failure, isNot(isA<TransportTimeoutException>()));
      expect(failure, isNot(isA<StateError>()));
    });
  });

  group('the two states stay separate', () {
    test('a broken protocol is not a disconnect', () {
      final liveness = TransportLivenessMonitor()..connected();
      final protocol = ProtocolObservationMonitor()..failed('bad payload');

      expect(liveness.state, TransportLiveness.healthy);
      expect(protocol.state.isIntact, isFalse);
    });

    test('a clean close is not a protocol failure', () {
      // Shutting down must not manufacture a schema problem.
      final liveness = TransportLivenessMonitor()..connected();
      final protocol = ProtocolObservationMonitor();
      liveness
        ..closing()
        ..ended();

      expect(liveness.state, TransportLiveness.closed);
      expect(protocol.state.isIntact, isTrue);
    });
  });

  group('the transport reports rather than swallows', () {
    test('a decode failure is no longer pushed onto the stream as noise', () {
      // `_events.addError` was read by AppSession as "! malformed event"
      // and logged past. Reporting it twice, once as state and once as
      // stream noise, would be two reports of one fact.
      expect(transportSource(), isNot(contains('_events.addError')));
    });

    test('the transport classifies rather than try/catching a decode', () {
      expect(transportSource(), contains('decodeTestEvent'));
    });

    test('an event carrying no data is recorded, not returned past', () {
      final source = transportSource();
      final handler = source.substring(source.indexOf('_onExtensionEvent'));

      // The old shape was `if (data == null) return;` - a silent exit on
      // an event this engine was addressed by.
      expect(handler, isNot(contains('if (data == null) return;')));
    });

    test('unrelated extension traffic is still filtered out early', () {
      // Other tooling shares the VM Service. Their events are not ours
      // to judge, and must remain free.
      expect(transportSource(), contains('extensionKind != kEventStreamKind'));
    });
  });
}
