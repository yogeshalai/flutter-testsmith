import 'dart:convert';

import 'package:meta/meta.dart';

import 'errors.dart';
import 'event_type.dart';
import 'json.dart';
import 'ui_tree.dart';

part 'payloads/api_events.dart';
part 'payloads/log_events.dart';
part 'payloads/screen_events.dart';
part 'payloads/session_events.dart';
part 'payloads/ui_events.dart';

/// The body of an event.
///
/// Sealed, so that every `switch` over payloads is checked for exhaustiveness
/// at compile time: adding an event type produces an error at each site that
/// must handle it, rather than a silent gap.
@immutable
sealed class EventPayload {
  const EventPayload();

  EventType get type;

  Map<String, Object?> toJson();

  /// Decodes a payload for [type].
  ///
  /// The switch is exhaustive over [EventType], so a new event type cannot be
  /// added without a decoder: the compiler rejects it.
  static EventPayload fromJson(EventType type, Map<String, Object?> json) {
    return switch (type) {
      EventType.sessionStart => SessionStartPayload.fromJson(json),
      EventType.sessionEnd => SessionEndPayload.fromJson(json),
      EventType.screenEnter => ScreenEnterPayload.fromJson(json),
      EventType.screenExit => ScreenExitPayload.fromJson(json),
      EventType.appLog => AppLogPayload.fromJson(json),
      EventType.heartbeat => HeartbeatPayload.fromJson(json),
      EventType.widgetTree => WidgetTreePayload.fromJson(json),
      EventType.screenshot => ScreenshotPayload.fromJson(json),
      EventType.apiRequest => ApiRequestPayload.fromJson(json),
      EventType.apiResponse => ApiResponsePayload.fromJson(json),
    };
  }
}
