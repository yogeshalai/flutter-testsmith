part of '../payloads.dart';

/// Emitted once, as early as the SDK can run, when a test session begins.
final class SessionStartPayload extends EventPayload {
  const SessionStartPayload({
    required this.sdkVersion,
    required this.appId,
    this.capabilities = const {},
  });

  final String sdkVersion;
  final String appId;

  /// What this SDK build can actually do, so the engine never invokes an
  /// RPC the app does not implement.
  final Set<String> capabilities;

  @override
  EventType get type => EventType.sessionStart;

  @override
  Map<String, Object?> toJson() => {
        'sdkVersion': sdkVersion,
        'appId': appId,
        if (capabilities.isNotEmpty) 'capabilities': capabilities.toList(),
      };

  factory SessionStartPayload.fromJson(Map<String, Object?> json) =>
      SessionStartPayload(
        sdkVersion: json.required<String>('sdkVersion'),
        appId: json.required<String>('appId'),
        capabilities: (json.optional<List<Object?>>('capabilities') ?? const [])
            .cast<String>()
            .toSet(),
      );

  @override
  bool operator ==(Object other) =>
      other is SessionStartPayload &&
      other.sdkVersion == sdkVersion &&
      other.appId == appId &&
      other.capabilities.length == capabilities.length &&
      other.capabilities.containsAll(capabilities);

  @override
  int get hashCode => Object.hash(
        sdkVersion,
        appId,
        // Order-independent, so a set that round-trips through a JSON list
        // in a different order still hashes equal.
        Object.hashAllUnordered(capabilities),
      );

  @override
  String toString() => 'SessionStartPayload($appId, sdk=$sdkVersion)';
}

/// Why a session finished.
enum SessionEndReason {
  completed('completed'),
  terminated('terminated'),
  error('error');

  const SessionEndReason(this.wire);

  final String wire;

  static SessionEndReason fromWire(String wire) {
    for (final reason in SessionEndReason.values) {
      if (reason.wire == wire) return reason;
    }
    throw ProtocolFormatException('Unknown session end reason "$wire"');
  }
}

/// Emitted when a test session finishes, however it finishes.
final class SessionEndPayload extends EventPayload {
  const SessionEndPayload({required this.reason, this.detail});

  final SessionEndReason reason;
  final String? detail;

  @override
  EventType get type => EventType.sessionEnd;

  @override
  Map<String, Object?> toJson() => {
        'reason': reason.wire,
        if (detail != null) 'detail': detail,
      };

  factory SessionEndPayload.fromJson(Map<String, Object?> json) =>
      SessionEndPayload(
        reason: SessionEndReason.fromWire(json.required<String>('reason')),
        detail: json.optional<String>('detail'),
      );

  @override
  bool operator ==(Object other) =>
      other is SessionEndPayload &&
      other.reason == reason &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(reason, detail);

  @override
  String toString() => 'SessionEndPayload(${reason.wire}, $detail)';
}

/// Periodic liveness signal, so a hung application is distinguishable from a
/// merely slow one.
final class HeartbeatPayload extends EventPayload {
  const HeartbeatPayload({required this.sequence});

  final int sequence;

  @override
  EventType get type => EventType.heartbeat;

  @override
  Map<String, Object?> toJson() => {'sequence': sequence};

  factory HeartbeatPayload.fromJson(Map<String, Object?> json) =>
      HeartbeatPayload(sequence: json.required<int>('sequence'));

  @override
  bool operator ==(Object other) =>
      other is HeartbeatPayload && other.sequence == sequence;

  @override
  int get hashCode => sequence.hashCode;

  @override
  String toString() => 'HeartbeatPayload($sequence)';
}
