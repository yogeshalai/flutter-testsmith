import 'dart:collection';

/// A bounded, non-consuming history of the most recent entries.
///
/// This exists because `dart:developer`'s `postEvent` is fire-and-forget:
/// events emitted before the engine subscribes are lost, and those are the
/// most important events in a run - session start and the first screen
/// entry. The handshake reads this buffer so that history is recovered
/// deterministically. See ARCHITECTURE 8.1.
///
/// Reads are non-consuming, so a runner that reattaches - after its own
/// restart, or after a hot restart - still sees the startup history.
///
/// The bound matters: an application left running with no engine attached
/// must not accumulate memory without limit.
class EventRingBuffer<T> {
  EventRingBuffer({required this.capacity}) {
    if (capacity < 1) {
      throw ArgumentError.value(
        capacity,
        'capacity',
        'Ring buffer capacity must be at least 1',
      );
    }
  }

  final int capacity;

  final ListQueue<T> _entries = ListQueue<T>();
  int _droppedCount = 0;

  /// How many entries were discarded to stay within [capacity].
  ///
  /// Non-zero means the history this buffer can offer is truncated.
  int get droppedCount => _droppedCount;

  /// Whether every entry ever added is still present.
  bool get isComplete => _droppedCount == 0;

  int get length => _entries.length;

  void add(T entry) {
    if (_entries.length == capacity) {
      _entries.removeFirst();
      _droppedCount++;
    }
    _entries.add(entry);
  }

  /// The retained entries, oldest first.
  ///
  /// Non-consuming, and an independent unmodifiable copy: a caller cannot
  /// mutate the buffer through the returned list, and later additions do not
  /// alter a snapshot already taken.
  List<T> snapshot() => List<T>.unmodifiable(_entries);

  void clear() {
    _entries.clear();
    _droppedCount = 0;
  }
}
