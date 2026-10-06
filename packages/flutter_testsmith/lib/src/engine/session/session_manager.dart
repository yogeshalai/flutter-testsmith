import 'dart:async';

import 'package:flutter_testsmith/protocol.dart';

/// An event together with the order it reached the engine.
class _Received {
  _Received(this.event, this.arrival);

  final TestEvent event;
  final int arrival;
}

/// Assembles one session's event history from every delivery path.
///
/// Two problems make this more than a list append.
///
/// **Duplicates.** DDS replays buffered stream events to a newly attached
/// client, and the handshake drains the SDK's own ring buffer. Both carry
/// the events emitted before attach, so those arrive twice. Deduplication
/// is by `eventId` and belongs here rather than in the SDK, because only
/// the engine sees both paths. See ARCHITECTURE 8.2.
///
/// **Ordering.** Arrival order is not chronological order. DDS replay is
/// capped at 10,000 events, so the live stream can deliver later events
/// while the handshake drain later supplies the earlier ones DDS dropped.
/// The history is therefore ordered by timestamp, with arrival order
/// breaking ties.
class SessionManager {
  final Map<String, _Received> _byId = <String, _Received>{};
  final StreamController<TestEvent> _controller =
      StreamController<TestEvent>.broadcast();

  int _arrivalCounter = 0;
  int _duplicateCount = 0;
  String? _sessionId;

  /// The session these events belong to, or null before the first event.
  String? get sessionId => _sessionId;

  /// How many repeat deliveries were discarded.
  int get duplicateCount => _duplicateCount;

  /// Distinct events in chronological order.
  List<TestEvent> get events {
    final received = _byId.values.toList()
      ..sort((a, b) {
        final byTime = a.event.timestamp.compareTo(b.event.timestamp);
        return byTime != 0 ? byTime : a.arrival.compareTo(b.arrival);
      });
    return [for (final entry in received) entry.event];
  }

  /// Fires once per distinct event, as it is first seen.
  Stream<TestEvent> get onEvent => _controller.stream;

  /// Screens entered, in chronological order.
  List<String> get screenHistory => [
        for (final event in events)
          if (event.payload case ScreenEnterPayload(:final screenId))
            screenId,
      ];

  /// The screen the application is on, derived chronologically so a
  /// late-arriving earlier event cannot rewrite the present.
  ///
  /// An exit is only believed when it is the *current* screen leaving.
  /// A router that removes a route from underneath the one on screen -
  /// which is what `context.go` from a splash does - reports the
  /// departure of a screen the app left already, and a removed route has
  /// nothing beneath it, so the exit carries no next screen. Applied
  /// literally that reads as "the app is on no screen" and an
  /// `expectScreen` for the destination waits out its whole timeout
  /// while sitting on exactly the screen it asked for. Intermittently,
  /// because it depends on whether a poll lands before the removal does.
  String? get currentScreenId {
    String? current;
    for (final event in events) {
      switch (event.payload) {
        case ScreenEnterPayload(:final screenId):
          current = screenId;
        case ScreenExitPayload(:final screenId, :final nextScreenId):
          if (screenId == current) current = nextScreenId;
        default:
          break;
      }
    }
    return current;
  }

  void ingest(TestEvent event) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      _sessionId = event.sessionId;
    } else if (event.sessionId != sessionId) {
      // Interleaving two sessions would silently corrupt every correlation
      // built on this history, so it is refused rather than tolerated.
      throw StateError(
        'Event ${event.eventId} belongs to session "${event.sessionId}" but '
        'this manager is tracking "$sessionId". A session manager handles '
        'exactly one session.',
      );
    }

    if (_byId.containsKey(event.eventId)) {
      _duplicateCount++;
      return;
    }

    _byId[event.eventId] = _Received(event, _arrivalCounter++);
    _controller.add(event);
  }

  void ingestAll(Iterable<TestEvent> events) => events.forEach(ingest);

  Future<void> close() => _controller.close();
}
