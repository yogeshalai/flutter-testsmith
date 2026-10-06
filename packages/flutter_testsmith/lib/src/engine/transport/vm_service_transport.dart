import 'dart:async';

import 'package:flutter_testsmith/protocol.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart' as vm_io;

import 'sdk_transport.dart';

/// The stream extension events are posted on, matching the SDK.
const String kEventStreamKind = 'mytest';

/// Carries events and RPCs over the Dart VM Service.
///
/// Deliberately thin: isolate selection lives in [selectSdkIsolate] and
/// event decoding in the protocol (lib/src/protocol), both unit tested. What remains here
/// needs a live VM Service and is covered by the on-device smoke test.
class VmServiceTransport implements SdkTransport {
  VmServiceTransport({
    required this.uri,
    this.engineVersion = '0.1.0',
    this.armTimeout = const Duration(seconds: 30),
    this.armPollInterval = const Duration(milliseconds: 250),
    this.rpcTimeout = const Duration(seconds: 30),
  });

  final Uri uri;
  final String engineVersion;

  /// The deadline every VM Service operation is held to.
  ///
  /// One policy, not a constant per call site. It is a **backstop**
  /// rather than the primary bound: callers already carry their own,
  /// shorter deadlines - `expectScreen` 5s, `waitForSettle` 10s - and
  /// this exists so that a single unanswered RPC overshoots one of them
  /// by a bounded amount instead of hanging the run for ever.
  ///
  /// Thirty seconds to match [armTimeout], on the same reasoning:
  /// generous enough never to fire on a healthy application under load
  /// on a slow device, short enough that a wedged one is reported rather
  /// than waited on. Overridable for an environment that genuinely needs
  /// longer, which is one knob rather than twelve.
  final Duration rpcTimeout;

  /// How long to wait for the application to register the SDK.
  ///
  /// `flutter run` reports the VM Service URI as soon as the isolate
  /// starts, which is well before `main()` has finished. An application
  /// that loads a `.env`, warms shared preferences and initialises
  /// Firebase before calling `TestSdk.initialize` is not armed for
  /// several seconds after the engine can already connect.
  ///
  /// Measured against a real external application: scanning the isolate
  /// list once and giving up failed every time. The platform's own
  /// example registered the SDK as the first statement in `main`, so
  /// the race never appeared until something else was tried.
  final Duration armTimeout;

  final Duration armPollInterval;

  vm.VmService? _service;
  String? _isolateId;
  StreamSubscription<vm.Event>? _subscription;
  final StreamController<TestEvent> _events =
      StreamController<TestEvent>.broadcast();

  final TransportLivenessMonitor _liveness = TransportLivenessMonitor();
  final ProtocolObservationMonitor _protocol = ProtocolObservationMonitor();

  @override
  TransportLiveness get liveness => _liveness.state;

  @override
  ProtocolObservation get protocol => _protocol.state;

  @override
  Stream<TestEvent> get events => _events.stream;

  /// Waits for an isolate to start serving the SDK's extensions.
  ///
  /// Polls rather than reading once, for the same reason every other
  /// wait in this platform polls: the thing being waited for arrives on
  /// the application's schedule, not the runner's. The isolate list is
  /// re-fetched each time, so an isolate that appears late is seen.
  ///
  /// On timeout it throws the same [SdkNotFoundException] as before,
  /// carrying the last set of isolates examined - the diagnostic is the
  /// valuable part and does not change.
  Future<String> _awaitSdkIsolate(vm.VmService service) async {
    final deadline = DateTime.now().add(armTimeout);
    var inspected = <String, List<String>>{};

    while (true) {
      inspected = <String, List<String>>{};
      // Each call carries the deadline, not just the loop. The loop's
      // `armTimeout` is only reachable between iterations, so a single
      // `getVM` that never answers would wait for ever inside a wait
      // that looks bounded.
      final vmInfo = await boundedRpc(
        service.getVM(),
        operation: 'getVM',
        timeout: rpcTimeout,
      );
      for (final ref in vmInfo.isolates ?? const <vm.IsolateRef>[]) {
        final isolate = await boundedRpc(
          service.getIsolate(ref.id!),
          operation: 'getIsolate(${ref.id})',
          timeout: rpcTimeout,
        );
        inspected[ref.id!] = isolate.extensionRPCs ?? const <String>[];
      }

      for (final entry in inspected.entries) {
        if (entry.value.any((rpc) => rpc.startsWith(kRpcNamespace))) {
          return entry.key;
        }
      }

      if (!DateTime.now().isBefore(deadline)) {
        // Same diagnostic as a single read would have given, so the
        // message people already know still applies.
        return selectSdkIsolate(inspected);
      }
      await Future<void>.delayed(armPollInterval);
    }
  }

  String get isolateId {
    final id = _isolateId;
    if (id == null) throw StateError('Not connected; call connect() first.');
    return id;
  }

  @override
  Future<HandshakeResponse> connect() async {
    // A socket that accepts and then goes quiet is the one failure that
    // would otherwise hang before any of this platform's own timeouts
    // exist to be exceeded. E-04's purpose is to say why testing could
    // not happen, and it cannot say anything from inside a hang.
    final service = await boundedRpc(
      vm_io.vmServiceConnectUri(uri.toString()),
      operation: 'connect($uri)',
      timeout: rpcTimeout,
    );
    _service = service;

    // The only liveness signal this API actually offers.
    //
    // `package:vm_service` disposes itself when its input stream closes,
    // and `dispose()` completes `onDone`. It does *not* close its event
    // controllers, so `onExtensionEvent` neither errors nor completes
    // when the connection dies - it goes silent, indistinguishable from
    // an application with nothing to say. Subscribing to `onDone` is the
    // only way to tell those apart, and it costs no traffic: it is a
    // future that is already there.
    unawaited(service.onDone.then((_) => _liveness.ended()));

    _isolateId = await _awaitSdkIsolate(service);

    // Subscribe before handshaking. Both paths deliver the pre-attach
    // events, and the session manager deduplicates; subscribing first
    // simply means nothing emitted during the handshake is missed.
    _subscription = service.onExtensionEvent.listen(_onExtensionEvent);
    await boundedRpc(
      service.streamListen(vm.EventStreams.kExtension),
      operation: 'streamListen(${vm.EventStreams.kExtension})',
      timeout: rpcTimeout,
    );

    final response = await invoke(
      'ext.mytest.handshake',
      const HandshakeRequest(engineVersion: '0.1.0')
          .toJson()
          .map((key, value) => MapEntry(key, value.toString())),
    );

    // Marked healthy only once the application has actually answered.
    // A socket that opened and an isolate that armed are not yet a
    // working connection.
    _liveness.connected();
    return HandshakeResponse.fromJson(response);
  }

  /// Reads one extension event, and records anything it could not read.
  ///
  /// Three outcomes, and the whole point is that they are three rather
  /// than two:
  ///
  /// * traffic belonging to other tooling is **not ours to judge** and
  ///   leaves immediately - the VM Service is shared;
  /// * an event addressed to this engine that it cannot read marks the
  ///   stream unreadable, because a run that keeps asserting after one
  ///   of these is drawing conclusions from observations it is missing;
  /// * an event type a *version-compatible* peer added later is skipped,
  ///   which is what keeps an SDK upgrade from being a breaking change.
  ///
  /// Nothing is pushed onto [_events] as an error any more. That path
  /// read as `! malformed event` in the session log and the run carried
  /// on past it, which is exactly the silence this replaces.
  void _onExtensionEvent(vm.Event event) {
    if (event.extensionKind != kEventStreamKind) return;

    final data = event.extensionData?.data;
    if (data == null) {
      // Addressed to this engine, carrying nothing. Previously a silent
      // `return`, which is indistinguishable from the application having
      // said nothing at all.
      _protocol.failed(
        'an event arrived on the "$kEventStreamKind" stream with no data '
        'at all, so there is nothing to read it from',
      );
      return;
    }

    switch (decodeTestEvent(Map<String, Object?>.from(data))) {
      case DecodedEvent(:final event):
        _events.add(event);
      case IgnoredEvent():
        return;
      case UndecodableEvent(:final describe):
        _protocol.failed(describe);
    }
  }

  @override
  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, String> args = const {},
  ]) async {
    final service = _service;
    if (service == null) {
      throw StateError('Not connected; call connect() first.');
    }
    final response = await boundedRpc(
      service.callServiceExtension(
        method,
        isolateId: isolateId,
        args: args,
      ),
      operation: method,
      timeout: rpcTimeout,
    );
    return response.json ?? const {};
  }

  @override
  Future<void> close() async {
    // Recorded before anything is disposed. Disposing completes
    // `onDone` by exactly the same path a dead socket does, so without
    // saying who asked, every clean teardown would report a lost
    // connection.
    _liveness.closing();

    await _subscription?.cancel();
    await _events.close();

    // Teardown is bounded too, and its failure is swallowed rather than
    // raised. A run that has already finished must not be held open by
    // an application that stopped answering, and must not replace
    // whatever caused the shutdown with a complaint about the shutdown.
    final service = _service;
    if (service != null) {
      try {
        await boundedRpc(
          service.dispose(),
          operation: 'dispose',
          timeout: rpcTimeout,
        );
      } on TransportTimeoutException {
        // The connection is being discarded anyway.
      }
    }
    _service = null;
  }
}
