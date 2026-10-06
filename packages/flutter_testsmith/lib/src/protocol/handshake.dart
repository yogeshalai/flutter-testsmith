import 'package:meta/meta.dart';

import 'app_context.dart';
import 'envelope.dart';
import 'errors.dart';
import 'json.dart';
import 'version.dart';

/// Verifies that a decoded message speaks a compatible protocol version.
///
/// Compatibility is checked on every handshake message rather than once at
/// connect, so a peer that is swapped mid-session (a hot restart, a
/// reattach) cannot slip through on the earlier check.
ProtocolVersion _checkVersion(Map<String, Object?> json) {
  final received = ProtocolVersion.parse(
    json.required<String>('protocolVersion'),
  );
  if (!ProtocolVersion.current.isCompatibleWith(received)) {
    throw ProtocolVersionMismatch(
      expected: ProtocolVersion.current,
      received: received,
    );
  }
  return received;
}

/// Sent by the engine to open a session.
@immutable
class HandshakeRequest {
  const HandshakeRequest({required this.engineVersion});

  final String engineVersion;

  ProtocolVersion get protocolVersion => ProtocolVersion.current;

  Map<String, Object?> toJson() => {
        'protocolVersion': ProtocolVersion.current.value,
        'engineVersion': engineVersion,
      };

  factory HandshakeRequest.fromJson(Map<String, Object?> json) {
    _checkVersion(json);
    return HandshakeRequest(
      engineVersion: json.required<String>('engineVersion'),
    );
  }

  @override
  String toString() => 'HandshakeRequest(engine=$engineVersion)';
}

/// The SDK's reply, which also drains the startup ring buffer.
///
/// The drain is the protocol-guaranteed recovery of events emitted before the
/// engine could subscribe. See ARCHITECTURE 8.1.
@immutable
class HandshakeResponse {
  const HandshakeResponse({
    required this.sessionId,
    required this.app,
    this.capabilities = const {},
    this.bufferedEvents = const [],
    this.droppedEventCount = 0,
  });

  final String sessionId;
  final AppContext app;
  final Set<String> capabilities;

  /// Events emitted before the engine attached, in emission order.
  final List<TestEvent> bufferedEvents;

  /// How many events the ring buffer discarded before this drain.
  ///
  /// Non-zero means the history is truncated. The engine must be able to
  /// distinguish a complete history from a partial one instead of assuming
  /// the drain returned everything.
  final int droppedEventCount;

  bool get historyIsComplete => droppedEventCount == 0;

  ProtocolVersion get protocolVersion => ProtocolVersion.current;

  Map<String, Object?> toJson() => {
        'protocolVersion': ProtocolVersion.current.value,
        'sessionId': sessionId,
        'app': app.toJson(),
        if (capabilities.isNotEmpty) 'capabilities': capabilities.toList(),
        'bufferedEvents': [
          for (final event in bufferedEvents) event.toJson(),
        ],
        'droppedEventCount': droppedEventCount,
      };

  factory HandshakeResponse.fromJson(Map<String, Object?> json) {
    _checkVersion(json);
    final buffered = json.optional<List<Object?>>('bufferedEvents') ?? const [];
    return HandshakeResponse(
      sessionId: json.required<String>('sessionId'),
      app: AppContext.fromJson(json.requiredMap('app')),
      capabilities: (json.optional<List<Object?>>('capabilities') ?? const [])
          .cast<String>()
          .toSet(),
      bufferedEvents: [
        for (final raw in buffered)
          TestEvent.fromJson((raw! as Map<Object?, Object?>).cast()),
      ],
      droppedEventCount: json.optional<int>('droppedEventCount') ?? 0,
    );
  }

  @override
  String toString() => 'HandshakeResponse(session=$sessionId, '
      'buffered=${bufferedEvents.length}, dropped=$droppedEventCount)';
}
