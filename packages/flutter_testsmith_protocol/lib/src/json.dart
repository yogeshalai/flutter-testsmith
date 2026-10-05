import 'errors.dart';

String _pad(int value, int width) => value.toString().padLeft(width, '0');

/// Formats [time] as UTC ISO-8601 with a fixed six fractional digits.
///
/// `DateTime.toIso8601String` emits three fractional digits when the
/// microsecond component is zero and six otherwise. A variable-width
/// timestamp is awkward for non-Dart consumers of the protocol and breaks
/// lexicographic ordering, so the wire format pins the width.
String formatUtcTimestamp(DateTime time) {
  final utc = time.toUtc();
  final fraction = utc.millisecond * 1000 + utc.microsecond;
  return '${_pad(utc.year, 4)}-${_pad(utc.month, 2)}-${_pad(utc.day, 2)}'
      'T${_pad(utc.hour, 2)}:${_pad(utc.minute, 2)}:${_pad(utc.second, 2)}'
      '.${_pad(fraction, 6)}Z';
}

/// Field readers that fail with the field's name rather than a cast error.
extension JsonMapReader on Map<String, Object?> {
  T required<T>(String field) {
    if (!containsKey(field)) {
      throw ProtocolFormatException('Missing required field "$field"');
    }
    final value = this[field];
    if (value is! T) {
      throw ProtocolFormatException(
        'Field "$field" should be $T but was ${value.runtimeType}',
      );
    }
    return value;
  }

  T? optional<T>(String field) {
    final value = this[field];
    if (value == null) return null;
    if (value is! T) {
      throw ProtocolFormatException(
        'Field "$field" should be $T or null but was ${value.runtimeType}',
      );
    }
    return value as T;
  }

  Map<String, Object?> requiredMap(String field) {
    final value = required<Map<Object?, Object?>>(field);
    return value.cast<String, Object?>();
  }

  Map<String, Object?> mapOrEmpty(String field) {
    final value = optional<Map<Object?, Object?>>(field);
    return value == null ? const {} : value.cast<String, Object?>();
  }

  double requiredDouble(String field) {
    final value = required<num>(field);
    return value.toDouble();
  }

  DateTime requiredUtcTimestamp(String field) {
    final raw = required<String>(field);
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw ProtocolFormatException(
        'Field "$field" is not an ISO-8601 timestamp: "$raw"',
      );
    }
    return parsed.toUtc();
  }
}
