import 'errors.dart';

/// The wire identity of an event.
///
/// Dart names are `camelCase`; wire names are `SCREAMING_SNAKE_CASE` and are
/// part of the protocol contract, so they may not be renamed within a major
/// version.
enum EventType {
  sessionStart('SESSION_START'),
  sessionEnd('SESSION_END'),
  screenEnter('SCREEN_ENTER'),
  screenExit('SCREEN_EXIT'),
  appLog('APP_LOG'),
  heartbeat('HEARTBEAT'),
  widgetTree('WIDGET_TREE'),
  screenshot('SCREENSHOT'),
  apiRequest('API_REQUEST'),
  apiResponse('API_RESPONSE');

  const EventType(this.wire);

  final String wire;

  static EventType fromWire(String wire) {
    for (final type in EventType.values) {
      if (type.wire == wire) return type;
    }
    throw ProtocolFormatException(
      'Unknown event type "$wire". Known types: '
      '${EventType.values.map((t) => t.wire).join(', ')}',
    );
  }
}
