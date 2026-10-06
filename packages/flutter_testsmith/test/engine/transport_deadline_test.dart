// Every bounded operation in this platform rested on an unbounded one.
//
// `VmServiceTransport` awaited the VM Service with no deadline anywhere:
// `invoke`, and - less obviously - `getVM`, `getIsolate`, `streamListen`,
// `vmServiceConnectUri` and `dispose`, three of which never went through
// `invoke` at all. The isolate wait *looked* bounded, because its polling
// loop carries `armTimeout`, but the bound was on the loop and not on the
// call inside it: one `getVM()` that never answers hangs for ever while
// the deadline sits unreachable at the top of the next iteration.
//
// So "expect this within 10 seconds" was a promise the transport could
// not keep. An application wedged in a breakpoint, a devtools connection
// stolen by another client, a VM Service socket that accepts and then
// goes quiet - each turns every timeout in the engine into a hang.
//
// The fix is one policy at the transport, not a timeout per call site.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

const Duration _short = Duration(milliseconds: 30);

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

void main() {
  group('a request that answers is left alone', () {
    test('its value is returned', () async {
      final value = await boundedRpc(
        Future<int>.value(7),
        operation: 'ext.mytest.uiTree',
        timeout: const Duration(seconds: 5),
      );

      expect(value, 7);
    });

    test('it returns as soon as the request does', () async {
      final watch = Stopwatch()..start();
      await boundedRpc(
        Future<String>.value('ok'),
        operation: 'ext.mytest.settle',
        timeout: const Duration(seconds: 30),
      );
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'it waited out the deadline instead of returning');
    });
  });

  group('a request that never answers becomes a bounded failure', () {
    test('it times out rather than hanging', () async {
      await expectLater(
        boundedRpc(
          Completer<int>().future,
          operation: 'ext.mytest.uiTree',
          timeout: _short,
        ),
        throwsA(isA<TransportTimeoutException>()),
      );
    });

    test('the wait is bounded by the declared deadline', () async {
      final watch = Stopwatch()..start();
      try {
        await boundedRpc(
          Completer<int>().future,
          operation: 'ext.mytest.uiTree',
          timeout: _short,
        );
        fail('an unanswered request returned');
      } on TransportTimeoutException {
        // expected
      }
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('the failure names the operation', () async {
      try {
        await boundedRpc(
          Completer<int>().future,
          operation: 'ext.mytest.screenshot',
          timeout: _short,
        );
        fail('returned');
      } on TransportTimeoutException catch (error) {
        expect(error.operation, 'ext.mytest.screenshot');
        expect('$error', contains('ext.mytest.screenshot'));
      }
    });

    test('the failure names the deadline it exceeded', () async {
      try {
        await boundedRpc(
          Completer<int>().future,
          operation: 'getVM',
          timeout: _short,
        );
        fail('returned');
      } on TransportTimeoutException catch (error) {
        expect(error.timeout, _short);
        expect('$error', contains('30ms'));
      }
    });

    test('it says this is the application not answering, not a test '
        'failing', () async {
      // An infrastructure timeout must not read like an assertion about
      // the application's behaviour. E-04's whole purpose is saying why
      // testing could not happen.
      try {
        await boundedRpc(
          Completer<int>().future,
          operation: 'ext.mytest.uiTree',
          timeout: _short,
        );
        fail('returned');
      } on TransportTimeoutException catch (error) {
        expect('$error', contains('did not answer'));
      }
    });
  });

  group('a timeout stays distinguishable from every other failure', () {
    test('an error from the VM Service propagates as itself', () async {
      await expectLater(
        boundedRpc(
          Future<int>.error(const FormatException('bad rpc')),
          operation: 'ext.mytest.uiTree',
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a disconnect propagates as itself', () async {
      // A closed transport is a different fact from a silent one, and
      // sends a reader somewhere different.
      await expectLater(
        boundedRpc(
          Future<int>.error(StateError('Not connected; call connect() first.')),
          operation: 'ext.mytest.uiTree',
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a timeout is not a StateError, so existing catches do not '
        'swallow it as one', () async {
      await expectLater(
        boundedRpc(
          Completer<int>().future,
          operation: 'ext.mytest.uiTree',
          timeout: _short,
        ),
        throwsA(isNot(isA<StateError>())),
      );
    });
  });

  group('a request abandoned at the deadline cannot cause harm later', () {
    test('its late value does not reach a later call', () async {
      final abandoned = Completer<int>();
      try {
        await boundedRpc(
          abandoned.future,
          operation: 'ext.mytest.uiTree',
          timeout: _short,
        );
        fail('returned');
      } on TransportTimeoutException {
        // expected
      }

      // The VM Service package keys every request by its own id, so a
      // late answer completes the request it belonged to and nothing
      // else. Asserted here at this layer: the next call is unaffected.
      abandoned.complete(99);
      final next = await boundedRpc(
        Future<int>.value(1),
        operation: 'ext.mytest.uiTree',
        timeout: const Duration(seconds: 5),
      );

      expect(next, 1);
    });

    test('its late error does not become an unhandled asynchronous error',
        () async {
      // `Future.timeout` does not cancel anything. An abandoned request
      // that later fails with nobody listening is an unhandled async
      // error, which Dart can escalate into tearing down the isolate -
      // a hang traded for a crash.
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final abandoned = Completer<int>();
        try {
          await boundedRpc(
            abandoned.future,
            operation: 'ext.mytest.uiTree',
            timeout: _short,
          );
        } on TransportTimeoutException {
          // expected
        }
        abandoned.completeError(StateError('answered far too late'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }, (error, stack) {
        errors.add(error);
      });

      expect(errors, isEmpty,
          reason: 'the abandoned request was left without a listener');
    });
  });

  group('no VM Service call may bypass the deadline', () {
    test('every awaited service call in the transport is wrapped', () {
      // A structural guarantee rather than a behavioural one: a future
      // RPC added without a deadline is the defect this milestone
      // exists to remove, and only the source can prove its absence.
      final source = transportSource();

      final bare = <String>[
        for (final line in source.split('\n'))
          if (RegExp(r'await\s+(service|_service|vm_io)\b').hasMatch(line))
            line.trim(),
      ];

      expect(bare, isEmpty,
          reason: 'these VM Service calls are awaited without a deadline:\n'
              '${bare.join('\n')}');
    });

    test('the transport routes its calls through boundedRpc', () {
      expect(transportSource(), contains('boundedRpc'));
    });

    test('the deadline is one policy, not a constant per call site', () {
      // Every call takes the transport's own `rpcTimeout`. A literal
      // Duration next to a call site is how a policy becomes twelve.
      final source = transportSource();
      final occurrences = 'rpcTimeout'.allMatches(source).length;

      expect(occurrences, greaterThan(1));
    });
  });

  group('the policy is configurable, and has a default', () {
    test('a transport declares a finite default deadline', () {
      final transport = VmServiceTransport(uri: Uri.parse('ws://127.0.0.1:1/'));
      expect(transport.rpcTimeout, isNotNull);
      expect(transport.rpcTimeout.inMilliseconds, greaterThan(0));
    });

    test('it can be overridden for a slow environment', () {
      final transport = VmServiceTransport(
        uri: Uri.parse('ws://127.0.0.1:1/'),
        rpcTimeout: const Duration(seconds: 90),
      );

      expect(transport.rpcTimeout, const Duration(seconds: 90));
    });
  });
}
