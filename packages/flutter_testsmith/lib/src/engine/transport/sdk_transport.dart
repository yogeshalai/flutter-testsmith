import 'dart:async';

import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../device/device_controller.dart';
import '../validation/validation_result.dart';

/// Namespace every SDK service extension shares.
const String kRpcNamespace = 'ext.mytest.';

/// The engine's side of the application connection.
///
/// An interface so the VM Service is not the only possible transport. A
/// WebSocket implementation is planned for release-mode and device-farm
/// execution; see ADR-0002.
abstract interface class SdkTransport {
  Future<HandshakeResponse> connect();

  /// Events streamed live from the application.
  ///
  /// May overlap the handshake's buffered events; deduplication is the
  /// [SessionManager]'s job. See ARCHITECTURE 8.2.
  Stream<TestEvent> get events;

  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, String> args,
  ]);

  /// Whether the connection carrying [events] is still usable.
  ///
  /// Read by callers that would otherwise mistake silence for an
  /// application that has stopped doing things.
  TransportLiveness get liveness;

  /// Whether the events arriving over [events] can still be read.
  ///
  /// Separate from [liveness]: a healthy connection can carry events
  /// this engine does not understand, and that is a different problem
  /// with a different remedy.
  ProtocolObservation get protocol;

  Future<void> close();
}

/// Whether the connection carrying events is usable.
///
/// Deliberately **not** a measure of how recently an event arrived. An
/// application is entitled to sit perfectly still - on a form, waiting
/// for a person who is not there - for as long as it likes, and an
/// inactivity threshold would turn that into a failure. "Quiet" is not a
/// state here, because quiet and healthy are the same thing.
///
/// A connection becomes unusable only on evidence, and there is exactly
/// one piece of evidence available: the VM Service connection ending.
enum TransportLiveness {
  /// Nothing has been connected yet.
  notConnected,

  /// Connected. Events may or may not be flowing, and that is not this
  /// value's business.
  healthy,

  /// Shut down deliberately, by us. Not a failure.
  closed,

  /// The connection ended without being asked to. A failure.
  disconnected;

  /// Whether readings taken over this connection can still be believed.
  bool get isUsable => this == TransportLiveness.healthy;
}

/// The one authoritative liveness state, and the three things that move
/// it.
///
/// A state machine rather than a flag because two of the transitions are
/// easy to get wrong. `package:vm_service` completes `onDone` when it
/// disposes, and it disposes both when the socket dies **and** when we
/// close it ourselves - so without recording who asked, every clean
/// teardown would report a lost connection. And nothing ever moves back
/// to healthy: this product has no reconnection, and a transport that
/// quietly healed would let a run continue across a gap it could not
/// account for.
///
/// Holds no timer, no threshold and no clock. See [TransportLiveness].
class TransportLivenessMonitor {
  TransportLiveness _state = TransportLiveness.notConnected;

  TransportLiveness get state => _state;

  /// A connection has been established.
  ///
  /// Ignored once the connection has ended, so a late or repeated call
  /// cannot resurrect a dead session.
  void connected() {
    if (_state == TransportLiveness.notConnected) {
      _state = TransportLiveness.healthy;
    }
  }

  /// We are about to shut the connection down on purpose.
  void closing() {
    if (_state == TransportLiveness.healthy) {
      _state = TransportLiveness.closed;
    }
  }

  /// The connection has ended.
  ///
  /// Whoever asked for it decides what this means, which is why
  /// [closing] exists.
  void ended() {
    if (_state == TransportLiveness.healthy ||
        _state == TransportLiveness.notConnected) {
      _state = TransportLiveness.disconnected;
    }
  }
}

/// Whether what arrives over the connection can still be read.
///
/// A **second** state beside [TransportLiveness], deliberately not
/// folded into it, because the two answer different questions:
///
///     TransportLiveness    - is the connection there?
///     ProtocolObservation  - can what arrives over it be understood?
///
/// "Connected, and emitting events I cannot decode" is not
/// "disconnected", and one state for both would send a reader to the
/// cable when the problem is the schema.
@immutable
class ProtocolObservation {
  const ProtocolObservation.intact() : failure = null;
  const ProtocolObservation.broken(String this.failure);

  /// Why the stream stopped being readable, or null while it is.
  final String? failure;

  bool get isIntact => failure == null;
}

/// The one authoritative answer to "can the event stream still be read".
///
/// Records the **first** failure and keeps it. Later failures are
/// consequences of the same hole, and the first is the one that explains
/// it; keeping the latest would report the symptom. Nothing clears it,
/// for the same reason nothing un-disconnects a transport: once events
/// have been missed, the observations built on them have a gap that no
/// later event can fill, and continuing would mean asserting from a
/// record known to be incomplete.
class ProtocolObservationMonitor {
  String? _failure;

  ProtocolObservation get state => _failure == null
      ? const ProtocolObservation.intact()
      : ProtocolObservation.broken(_failure!);

  void failed(String description) => _failure ??= description;
}

/// The engine could not interpret the application's event stream.
///
/// An **infrastructure** failure and never a verdict. The application
/// may be behaving perfectly; what is established is only that the
/// engine stopped being able to read what it was sent, and therefore
/// that anything derived from the stream after that point is incomplete.
@immutable
class ProtocolObservationException implements Exception {
  const ProtocolObservationException(this.failure);

  final String failure;

  @override
  String toString() =>
      'ProtocolObservationException: the engine could not interpret the '
      'application\'s event stream, so what it has observed since is '
      'incomplete.\n'
      '  $failure\n'
      'This is the engine and the application disagreeing about the '
      'protocol, not a result about the application. Usually the two '
      'were built from different versions of this platform.';
}

/// The engine lost the connection carrying the application's events.
///
/// An **infrastructure** failure, its own type, and never a verdict
/// about the application. The distinction it exists to draw is the whole
/// of this milestone: a run that stops hearing from an application must
/// say so, rather than reporting that the application stopped doing
/// things.
@immutable
class TransportDisconnectedException implements Exception {
  const TransportDisconnectedException(this.liveness);

  final TransportLiveness liveness;

  @override
  String toString() =>
      'TransportDisconnectedException: the engine has lost its connection '
      'to the application (${liveness.name}), so nothing read over it can '
      'still be believed.\n'
      'This is the connection failing, not a result about the '
      'application: the last route, tree and event seen are simply the '
      'last ones that arrived before the connection ended. Usually the '
      'app was stopped or crashed, `flutter run` exited, or the device '
      'was disconnected.';
}

/// The application did not answer a transport operation in time.
///
/// An **infrastructure** failure, deliberately its own type. A timeout
/// here says the application stopped answering; it says nothing about
/// whether the application is correct, and it must never be read as an
/// assertion about behaviour. Keeping it distinct from [StateError] -
/// which is what a disconnected transport and a malformed reply already
/// raise - is what lets a caller tell "silent" from "broken" from
/// "wrong".
@immutable
class TransportTimeoutException implements Exception {
  const TransportTimeoutException({
    required this.operation,
    required this.timeout,
  });

  /// The RPC or connection step that went unanswered, named as the
  /// transport calls it - `ext.mytest.uiTree`, `getVM`, `connect`.
  final String operation;

  /// The deadline it exceeded.
  final Duration timeout;

  @override
  String toString() =>
      'TransportTimeoutException: the application did not answer '
      '"$operation" within ${timeout.inMilliseconds}ms.\n'
      'This is the connection to the application failing, not a result '
      'about the application: nothing here says the app is wrong. It is '
      'usually a paused isolate, a debugger holding the VM Service, or a '
      'device that went to sleep mid-run.';
}

/// Runs [request] under a deadline, and reports a breach as one.
///
/// The single place a VM Service operation becomes bounded. Every call a
/// transport makes goes through here, rather than a timeout at each call
/// site: a deadline that has to be remembered once per RPC is a deadline
/// that will be forgotten by the next RPC someone adds, and the whole of
/// this engine's "within 10 seconds" vocabulary rests on it.
///
/// **A late answer is not cancelled.** The VM Service protocol has no
/// cancellation, and `Future.timeout` abandons a request rather than
/// stopping it, so [request] may still complete afterwards. That is safe
/// at this layer because nothing here holds state a late answer could
/// write into, and safe below it because `package:vm_service` keys every
/// request by its own id - a late reply completes the request it
/// belonged to and can never be delivered as the answer to another.
///
/// What is *not* automatically safe is a late **failure**: an abandoned
/// future that errors with no listener is an unhandled asynchronous
/// error, which Dart may escalate into tearing the isolate down - a hang
/// traded for a crash. A listener is therefore attached before the
/// deadline can abandon it, and discards whatever arrives.
Future<T> boundedRpc<T>(
  Future<T> request, {
  required String operation,
  required Duration timeout,
}) {
  unawaited(request.then<void>((_) {}, onError: (Object _) {}));
  return request.timeout(
    timeout,
    onTimeout: () => throw TransportTimeoutException(
      operation: operation,
      timeout: timeout,
    ),
  );
}

/// Whether [error] means the engine could not observe the application,
/// rather than anything about the application itself.
///
/// The one place the three infrastructure failures are named together,
/// so a caller deciding "is this a result or a testability problem" does
/// not have to keep its own list and drift from this one.
///
/// Deliberately exhaustive by type rather than by message. A broad
/// `on Object` that means "the application misbehaved" is only correct
/// if these have already been let through, and matching on wording would
/// make that correctness depend on nobody rephrasing a diagnostic.
bool isInfrastructureFailure(Object error) =>
    error is TransportTimeoutException ||
    error is TransportDisconnectedException ||
    error is ProtocolObservationException ||
    // Not a transport failure, and it belongs here all the same: a
    // result this engine cannot account for means the screen was not
    // trustworthily judged. The question this predicate answers is
    // "could the run establish anything?", not "was it the socket?".
    error is UndimensionedResultException ||
    // The same question, asked of the handset: an adb command that never
    // came back, now that each one is bounded. Before this it was a
    // failed step - a UI FAIL at exit 1, and an auth flow failure -
    // about an application nobody had been able to drive. An adb command
    // that ran and answered with an error is not here: whether that
    // answer is about the device or the application is not decided by
    // type.
    error is DeviceTimeoutException;

/// No isolate in the target application is serving the test SDK.
@immutable
class SdkNotFoundException implements Exception {
  const SdkNotFoundException(this.inspected);

  /// Isolate ids that were examined, for the diagnostic.
  final List<String> inspected;

  @override
  String toString() => 'SdkNotFoundException: no isolate is serving '
      '"$kRpcNamespace*" extensions (inspected: '
      '${inspected.isEmpty ? 'none' : inspected.join(', ')}).\n'
      'The application is running but the test SDK is not armed. Check '
      'that:\n'
      '  1. the app calls TestSdk.initialize() before runApp(), and\n'
      '  2. it was built with --dart-define=TEST_MODE=true.';
}

/// Finds the isolate serving the SDK, given each isolate's extension list.
///
/// Separated from the vm_service plumbing so the failure diagnostic - by
/// far the most valuable part - is unit tested.
String selectSdkIsolate(Map<String, List<String>> isolateExtensions) {
  for (final entry in isolateExtensions.entries) {
    if (entry.value.any((rpc) => rpc.startsWith(kRpcNamespace))) {
      return entry.key;
    }
  }
  throw SdkNotFoundException(isolateExtensions.keys.toList());
}
