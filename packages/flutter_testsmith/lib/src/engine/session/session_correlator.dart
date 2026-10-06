import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'screen_session.dart';
import 'session_manager.dart';

/// The full outcome of correlation, including what could not be placed.
@immutable
class CorrelationResult {
  const CorrelationResult({
    required this.sessions,
    required this.unattributed,
    required this.orphanResponses,
  });

  final List<ScreenSession> sessions;

  /// Exchanges that belong to no screen.
  ///
  /// Surfaced rather than dropped: silently discarding a request hides
  /// it from the report, and arbitrarily assigning one is a lie.
  final List<ApiExchange> unattributed;

  /// Responses whose request was never seen - usually the ring buffer
  /// having overflowed, or capture starting mid-flight.
  final List<ApiResponsePayload> orphanResponses;
}

/// Groups a session's events into per-screen sessions.
///
/// **The attribution rule**, stated exactly because ambiguity here is the
/// classic source of flaky, unreproducible results:
///
/// 1. An exchange belongs to the screen that was current when the
///    **request was issued**. Never the response: a slow response
///    arriving after a navigation does not make the request belong to
///    the new screen.
/// 2. Exception - a request issued within [graceWindow] *before* a screen
///    was entered, and **still unanswered when that screen appeared**, is
///    attributed to the new screen instead. This is the tap-handler that
///    fetches and then navigates: the request was made for the
///    destination. Being still in flight at the transition is what
///    distinguishes it from a request the old screen merely finished
///    late.
/// 3. A request issued before any screen was entered joins the first
///    screen if it falls within [graceWindow] of it; otherwise it is
///    reported as unattributed.
class SessionCorrelator {
  const SessionCorrelator({
    this.graceWindow = const Duration(seconds: 2),
  });

  final Duration graceWindow;

  List<ScreenSession> correlate(SessionManager manager) =>
      correlateAll(manager).sessions;

  CorrelationResult correlateAll(SessionManager manager) {
    final events = manager.events;

    final sessions = _buildSessions(events);
    final (exchanges, orphans) = _pairExchanges(events);

    final unattributed = <ApiExchange>[];
    for (final exchange in exchanges) {
      final target = _screenFor(exchange, sessions);
      if (target == null) {
        unattributed.add(exchange);
      } else {
        target.exchanges.add(exchange);
      }
    }

    _attachSnapshots(events, sessions);

    return CorrelationResult(
      sessions: sessions,
      unattributed: unattributed,
      orphanResponses: orphans,
    );
  }

  List<ScreenSession> _buildSessions(List<TestEvent> events) {
    final sessions = <ScreenSession>[];

    for (final event in events) {
      if (event.payload case ScreenEnterPayload(:final screenId)) {
        if (sessions.isNotEmpty) {
          sessions.last.exitedAt ??= event.timestamp;
        }
        sessions.add(
          ScreenSession(screenId: screenId, enteredAt: event.timestamp),
        );
      }
    }

    return sessions;
  }

  (List<ApiExchange>, List<ApiResponsePayload>) _pairExchanges(
    List<TestEvent> events,
  ) {
    final byRequestId = <String, ApiExchange>{};
    final orphans = <ApiResponsePayload>[];
    final order = <String>[];

    for (final event in events) {
      switch (event.payload) {
        case final ApiRequestPayload request:
          byRequestId[request.requestId] = ApiExchange(
            request: request,
            requestedAt: event.timestamp,
          );
          order.add(request.requestId);
        case final ApiResponsePayload response:
          final existing = byRequestId[response.requestId];
          if (existing == null) {
            orphans.add(response);
          } else {
            byRequestId[response.requestId] =
                existing.withResponse(response, event.timestamp);
          }
        default:
          break;
      }
    }

    return ([for (final id in order) byRequestId[id]!], orphans);
  }

  ScreenSession? _screenFor(
    ApiExchange exchange,
    List<ScreenSession> sessions,
  ) {
    if (sessions.isEmpty) return null;

    // Rule 2 takes precedence: a request still open when the next screen
    // arrived, issued shortly before it, belongs to that screen.
    for (final session in sessions) {
      final windowOpens = session.enteredAt.subtract(graceWindow);
      final issuedInWindow =
          !exchange.requestedAt.isBefore(windowOpens) &&
              exchange.requestedAt.isBefore(session.enteredAt);
      if (issuedInWindow && exchange.wasInFlightAt(session.enteredAt)) {
        return session;
      }
    }

    // Rule 1: the screen current when the request was issued.
    for (final session in sessions.reversed) {
      if (!exchange.requestedAt.isBefore(session.enteredAt)) return session;
    }

    // Rule 3: before any screen, but close enough to the first.
    final first = sessions.first;
    if (!exchange.requestedAt
        .isBefore(first.enteredAt.subtract(graceWindow))) {
      return first;
    }

    return null;
  }

  void _attachSnapshots(List<TestEvent> events, List<ScreenSession> sessions) {
    for (final event in events) {
      if (event.payload case WidgetTreePayload(:final snapshot)) {
        for (final session in sessions.reversed) {
          if (!event.timestamp.isBefore(session.enteredAt)) {
            session.uiSnapshot = snapshot;
            break;
          }
        }
      }
    }
  }
}
