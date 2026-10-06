import 'package:test/test.dart';
import 'package:flutter_testsmith/protocol.dart';

void main() {
  group('formatUtcTimestamp', () {
    test('always emits six fractional digits', () {
      // Dart's own toIso8601String drops to three digits when microseconds
      // are zero. A variable-width timestamp is hard for non-Dart consumers
      // to parse and breaks lexicographic ordering, so the protocol pins the
      // width.
      expect(
        formatUtcTimestamp(DateTime.utc(2026, 9, 10, 12, 30, 55)),
        '2026-09-10T12:30:55.000000Z',
      );
      expect(
        formatUtcTimestamp(DateTime.utc(2026, 9, 10, 12, 30, 45, 123, 456)),
        '2026-09-10T12:30:45.123456Z',
      );
      expect(
        formatUtcTimestamp(DateTime.utc(2026, 9, 10, 12, 30, 45, 0, 7)),
        '2026-09-10T12:30:45.000007Z',
      );
    });

    test('converts a local time to UTC', () {
      final local = DateTime.utc(2026, 9, 10, 12).toLocal();
      expect(formatUtcTimestamp(local), '2026-09-10T12:00:00.000000Z');
    });

    test('zero-pads every component', () {
      expect(
        formatUtcTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5, 0, 6)),
        '2026-01-02T03:04:05.000006Z',
      );
    });

    test('sorts lexicographically in chronological order', () {
      final times = [
        DateTime.utc(2026, 9, 10, 12, 30, 45, 123, 456),
        DateTime.utc(2026, 9, 10, 12, 30, 45),
        DateTime.utc(2026, 9, 10, 12, 30, 45, 0, 7),
      ];

      final formatted = times.map(formatUtcTimestamp).toList()..sort();

      expect(formatted, [
        '2026-09-10T12:30:45.000000Z',
        '2026-09-10T12:30:45.000007Z',
        '2026-09-10T12:30:45.123456Z',
      ]);
    });

    test('round-trips through DateTime.parse', () {
      final original = DateTime.utc(2026, 9, 10, 12, 30, 45, 123, 456);
      expect(DateTime.parse(formatUtcTimestamp(original)), original);
    });
  });
}
