part of '../payloads.dart';

/// Severity of an application log record.
enum LogLevel {
  debug('debug'),
  info('info'),
  warning('warning'),
  error('error');

  const LogLevel(this.wire);

  final String wire;

  static LogLevel fromWire(String wire) {
    for (final level in LogLevel.values) {
      if (level.wire == wire) return level;
    }
    throw ProtocolFormatException('Unknown log level "$wire"');
  }
}

/// A log record forwarded from the application under test.
final class AppLogPayload extends EventPayload {
  const AppLogPayload({
    required this.level,
    required this.message,
    this.loggerName,
    this.stackTrace,
  });

  final LogLevel level;
  final String message;
  final String? loggerName;
  final String? stackTrace;

  @override
  EventType get type => EventType.appLog;

  @override
  Map<String, Object?> toJson() => {
        'level': level.wire,
        'message': message,
        if (loggerName != null) 'loggerName': loggerName,
        if (stackTrace != null) 'stackTrace': stackTrace,
      };

  factory AppLogPayload.fromJson(Map<String, Object?> json) => AppLogPayload(
        level: LogLevel.fromWire(json.required<String>('level')),
        message: json.required<String>('message'),
        loggerName: json.optional<String>('loggerName'),
        stackTrace: json.optional<String>('stackTrace'),
      );

  @override
  bool operator ==(Object other) =>
      other is AppLogPayload &&
      other.level == level &&
      other.message == message &&
      other.loggerName == loggerName &&
      other.stackTrace == stackTrace;

  @override
  int get hashCode => Object.hash(level, message, loggerName, stackTrace);

  @override
  String toString() => 'AppLogPayload(${level.wire}, $message)';
}
