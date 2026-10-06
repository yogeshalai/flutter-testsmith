import 'package:meta/meta.dart';

import 'app_context.dart';
import 'errors.dart';
import 'event_type.dart';
import 'json.dart';
import 'payloads.dart';
import 'version.dart';

/// A single protocol event.
///
/// The envelope is stable across the whole event catalogue: adding an event
/// type adds a payload, never a field here.
@immutable
class TestEvent {
  const TestEvent({
    required this.eventId,
    required this.timestamp,
    required this.sessionId,
    required this.app,
    required this.payload,
    this.screenId,
    this.metadata = const {},
  });

  /// Unique per emitted event.
  ///
  /// The engine deduplicates on this, because DDS replay and the handshake
  /// drain both deliver the events emitted before attach. See ARCHITECTURE
  /// 8.2.
  final String eventId;

  final DateTime timestamp;
  final String sessionId;

  /// The screen active when the event was emitted, where one applies.
  final String? screenId;

  final AppContext app;
  final Map<String, Object?> metadata;
  final EventPayload payload;

  /// Derived from the payload, so a type/payload mismatch cannot be
  /// represented.
  EventType get type => payload.type;

  Map<String, Object?> toJson() => {
        'protocolVersion': ProtocolVersion.current.value,
        'event': type.wire,
        'eventId': eventId,
        'timestamp': formatUtcTimestamp(timestamp),
        'sessionId': sessionId,
        if (screenId != null) 'screenId': screenId,
        'app': app.toJson(),
        if (metadata.isNotEmpty) 'metadata': metadata,
        'payload': payload.toJson(),
      };

  factory TestEvent.fromJson(Map<String, Object?> json) {
    final received = ProtocolVersion.parse(
      json.required<String>('protocolVersion'),
    );
    if (!ProtocolVersion.current.isCompatibleWith(received)) {
      throw ProtocolVersionMismatch(
        expected: ProtocolVersion.current,
        received: received,
      );
    }

    final type = EventType.fromWire(json.required<String>('event'));

    return TestEvent(
      eventId: json.required<String>('eventId'),
      timestamp: json.requiredUtcTimestamp('timestamp'),
      sessionId: json.required<String>('sessionId'),
      screenId: json.optional<String>('screenId'),
      app: AppContext.fromJson(json.requiredMap('app')),
      metadata: json.mapOrEmpty('metadata'),
      payload: EventPayload.fromJson(type, json.requiredMap('payload')),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TestEvent &&
      other.eventId == eventId &&
      other.timestamp == timestamp &&
      other.sessionId == sessionId &&
      other.screenId == screenId &&
      other.app == app &&
      other.payload == payload;

  @override
  int get hashCode =>
      Object.hash(eventId, timestamp, sessionId, screenId, app, payload);

  @override
  String toString() =>
      'TestEvent(${type.wire}, id=$eventId, screen=$screenId, '
      'at=${timestamp.toIso8601String()})';
}

/// What came of trying to read one event off the wire.
///
/// Sealed rather than a nullable [TestEvent], because "this is not for
/// me" and "this is for me and I cannot read it" are different facts and
/// only one of them is a problem. Collapsing them is what let a run
/// continue past events it had failed to decode, asserting from a record
/// with a hole in it.
@immutable
sealed class EventDecode {
  const EventDecode();
}

/// The event was read.
final class DecodedEvent extends EventDecode {
  const DecodedEvent(this.event);

  final TestEvent event;
}

/// A version-compatible peer sent something this build has never heard
/// of, and it is safe to skip.
///
/// Forward compatibility, and the reason this whole classification is
/// not simply "anything unreadable is fatal". [ProtocolVersion] decides
/// compatibility on the major component alone, which is a promise that a
/// later **minor** may add event types. Refusing an unknown type would
/// turn every additive SDK release into a breaking one.
final class IgnoredEvent extends EventDecode {
  const IgnoredEvent(this.reason);

  final String reason;
}

/// The event was addressed to this engine and could not be read.
///
/// Never a silence. A consumer that keeps asserting after one of these
/// is drawing conclusions from observations it is missing.
final class UndecodableEvent extends EventDecode {
  const UndecodableEvent(this.error);

  final Object error;

  /// One line naming the cause, for a diagnostic.
  String get describe => '$error';
}

/// Classifies one raw event body.
///
/// The order is deliberate and is the whole contract:
///
/// 1. **Version first.** An incompatible major is a failure even when
///    the event type is also unknown - otherwise a peer two majors ahead
///    would look like harmless forward compatibility and every one of
///    its events would be quietly dropped.
/// 2. **Then the type.** A type this build does not know, from a peer it
///    *is* compatible with, is an addition to skip.
/// 3. **Then the body.** A type this build knows, whose payload will not
///    read, is a failure: the engine was addressed and could not listen.
///
/// Nothing here filters by `extensionKind` - that is the transport's
/// job, and traffic belonging to other tooling never reaches this.
EventDecode decodeTestEvent(Map<String, Object?> json) {
  try {
    final received = ProtocolVersion.parse(
      json.required<String>('protocolVersion'),
    );
    if (!ProtocolVersion.current.isCompatibleWith(received)) {
      return UndecodableEvent(
        ProtocolVersionMismatch(
          expected: ProtocolVersion.current,
          received: received,
        ),
      );
    }

    final wire = json.required<String>('event');
    if (!EventType.values.any((type) => type.wire == wire)) {
      return IgnoredEvent(
        'the application sent "$wire", which this build of the protocol '
        'does not know. Its version is compatible, so this is an event '
        'type added later and is skipped rather than failed.',
      );
    }

    return DecodedEvent(TestEvent.fromJson(json));
  } catch (error) {
    return UndecodableEvent(error);
  }
}
