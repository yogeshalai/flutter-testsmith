part of '../payloads.dart';

/// Emitted when the application navigates into a screen.
final class ScreenEnterPayload extends EventPayload {
  const ScreenEnterPayload({
    required this.screenId,
    this.routeName,
    this.previousScreenId,
  });

  final String screenId;

  /// The router's name for the route, when it has one.
  ///
  /// Null for unnamed routes, where the screen ID falls back to the widget
  /// type. See ARCHITECTURE 9.3.
  final String? routeName;

  final String? previousScreenId;

  @override
  EventType get type => EventType.screenEnter;

  @override
  Map<String, Object?> toJson() => {
        'screenId': screenId,
        if (routeName != null) 'routeName': routeName,
        if (previousScreenId != null) 'previousScreenId': previousScreenId,
      };

  factory ScreenEnterPayload.fromJson(Map<String, Object?> json) =>
      ScreenEnterPayload(
        screenId: json.required<String>('screenId'),
        routeName: json.optional<String>('routeName'),
        previousScreenId: json.optional<String>('previousScreenId'),
      );

  @override
  bool operator ==(Object other) =>
      other is ScreenEnterPayload &&
      other.screenId == screenId &&
      other.routeName == routeName &&
      other.previousScreenId == previousScreenId;

  @override
  int get hashCode => Object.hash(screenId, routeName, previousScreenId);

  @override
  String toString() => 'ScreenEnterPayload($screenId, route=$routeName)';
}

/// Emitted when the application navigates away from a screen.
final class ScreenExitPayload extends EventPayload {
  const ScreenExitPayload({required this.screenId, this.nextScreenId});

  final String screenId;

  /// Null when leaving the last screen, for example on app termination.
  final String? nextScreenId;

  @override
  EventType get type => EventType.screenExit;

  @override
  Map<String, Object?> toJson() => {
        'screenId': screenId,
        if (nextScreenId != null) 'nextScreenId': nextScreenId,
      };

  factory ScreenExitPayload.fromJson(Map<String, Object?> json) =>
      ScreenExitPayload(
        screenId: json.required<String>('screenId'),
        nextScreenId: json.optional<String>('nextScreenId'),
      );

  @override
  bool operator ==(Object other) =>
      other is ScreenExitPayload &&
      other.screenId == screenId &&
      other.nextScreenId == nextScreenId;

  @override
  int get hashCode => Object.hash(screenId, nextScreenId);

  @override
  String toString() => 'ScreenExitPayload($screenId -> $nextScreenId)';
}
