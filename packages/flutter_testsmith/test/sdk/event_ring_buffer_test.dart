import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  group('EventRingBuffer', () {
    test('retains everything added while under capacity, in order', () {
      final buffer = EventRingBuffer<int>(capacity: 5);

      for (final value in [1, 2, 3]) {
        buffer.add(value);
      }

      expect(buffer.snapshot(), [1, 2, 3]);
      expect(buffer.length, 3);
      expect(buffer.droppedCount, 0);
    });

    test('drops the oldest entries once capacity is exceeded', () {
      final buffer = EventRingBuffer<int>(capacity: 3);

      for (final value in [1, 2, 3, 4, 5]) {
        buffer.add(value);
      }

      expect(buffer.snapshot(), [3, 4, 5]);
      expect(buffer.length, 3);
    });

    test('counts how many entries were dropped', () {
      final buffer = EventRingBuffer<int>(capacity: 2);

      for (final value in [1, 2, 3, 4, 5]) {
        buffer.add(value);
      }

      // The engine needs this to know the history is truncated rather than
      // assuming the drain returned everything.
      expect(buffer.droppedCount, 3);
      expect(buffer.isComplete, isFalse);
    });

    test('reports a complete history when nothing was dropped', () {
      final buffer = EventRingBuffer<int>(capacity: 10)..add(1);
      expect(buffer.isComplete, isTrue);
    });

    test('snapshot does not consume the buffer', () {
      // A second attach - a runner restart, a reattach after hot restart -
      // must still see the startup history.
      final buffer = EventRingBuffer<int>(capacity: 5)
        ..add(1)
        ..add(2);

      expect(buffer.snapshot(), [1, 2]);
      expect(buffer.snapshot(), [1, 2]);
      expect(buffer.length, 2);
    });

    test('snapshot is independent of later additions', () {
      final buffer = EventRingBuffer<int>(capacity: 5)..add(1);

      final taken = buffer.snapshot();
      buffer.add(2);

      expect(taken, [1]);
    });

    test('snapshot cannot be mutated by the caller', () {
      final buffer = EventRingBuffer<int>(capacity: 5)..add(1);

      expect(() => buffer.snapshot().add(2), throwsUnsupportedError);
    });

    test('clear empties the buffer and resets the dropped count', () {
      final buffer = EventRingBuffer<int>(capacity: 2);
      for (final value in [1, 2, 3, 4]) {
        buffer.add(value);
      }

      buffer.clear();

      expect(buffer.snapshot(), isEmpty);
      expect(buffer.droppedCount, 0);
      expect(buffer.isComplete, isTrue);
    });

    test('rejects a non-positive capacity', () {
      expect(() => EventRingBuffer<int>(capacity: 0), throwsArgumentError);
      expect(() => EventRingBuffer<int>(capacity: -1), throwsArgumentError);
    });

    test('handles a capacity of one', () {
      final buffer = EventRingBuffer<int>(capacity: 1)
        ..add(1)
        ..add(2);

      expect(buffer.snapshot(), [2]);
      expect(buffer.droppedCount, 1);
    });
  });
}
