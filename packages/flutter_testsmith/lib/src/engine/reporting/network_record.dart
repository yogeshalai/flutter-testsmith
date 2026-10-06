import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../session/screen_session.dart';
import '../session/session_correlator.dart';

/// How much of the application's HTTP traffic a run could have seen.
///
/// Three states and no fourth called "complete". The capture hooks
/// `dart:io` `HttpClient` and whatever the application reports through
/// `TestSdk.network`; traffic on any other path never reaches it, and
/// nothing on the engine's side of the connection can tell that traffic
/// apart from no traffic at all. So the strongest thing a run can say is
/// that capture was on and nothing it can check went missing - which is
/// [active], and which [NetworkRecord.scope] qualifies wherever it is
/// written down.
enum NetworkCaptureState {
  /// The application did not offer network capture at all.
  ///
  /// An empty request list then says nothing about whether requests were
  /// made. The report has to say so, because an empty table reads as
  /// "the app made no calls".
  unavailable('unavailable'),

  /// Capture was on, and the run has evidence that some of what it
  /// captured never arrived: [NetworkRecord.reasons] names it.
  partial('partial'),

  /// Capture was on, and none of the losses the engine can detect
  /// occurred.
  active('active');

  const NetworkCaptureState(this.wire);

  final String wire;
}

/// What one request came to.
///
/// Decided from the response the application recorded, never from a
/// timing: a request with no response at the end of the run is
/// [unanswered], not slow and not failed, because the run cannot tell
/// those apart.
enum ExchangeOutcome {
  /// Answered with a status from 200 to 399, as
  /// [ApiResponsePayload.isSuccess] defines it.
  success('success'),

  /// Answered, with any other status.
  httpError('httpError'),

  /// No status at all: the client raised instead. A refused connection,
  /// a DNS failure, a TLS error and a client-side timeout all land here,
  /// and `error` says which.
  failed('failed'),

  /// No response had been observed when the run ended.
  unanswered('unanswered');

  const ExchangeOutcome(this.wire);

  final String wire;
}

/// Which clock the application measured each `durationMs` on.
///
/// Read from the handshake, never inferred from a version: an application
/// pins its own SDK, so an older SDK meeting a newer CLI is an ordinary
/// configuration, and its durations must not be described as something
/// they were not.
enum NetworkDurationClock {
  /// The SDK advertised `monotonicNetworkTiming`. Each duration is the
  /// difference of two readings of one monotonic source, from before the
  /// connection was opened to the request's terminal event.
  monotonic('monotonic'),

  /// The SDK advertised `network` without `monotonicNetworkTiming`: an
  /// SDK from before it. Each duration is the difference of two
  /// wall-clock readings, which a clock step during the request distorts,
  /// and it began after the connection was established.
  wall('wall');

  const NetworkDurationClock(this.wire);

  final String wire;
}

/// One captured request, for the run-wide table and timeline.
///
/// Fields come from the events the application emitted and nothing
/// else. The URL was redacted in the application, before it was ever
/// emitted (ARCHITECTURE 13); headers and bodies are deliberately not
/// carried here at all, so this record cannot become the place one leaks
/// from.
@immutable
class NetworkExchange {
  const NetworkExchange({
    required this.requestId,
    required this.method,
    required this.url,
    required this.requestedAt,
    required this.outcome,
    this.screenId,
    this.respondedAt,
    this.statusCode,
    this.error,
    this.durationMs,
  });

  /// Built from a correlated exchange. [screenId] is null for one the
  /// correlator could attribute to no screen.
  factory NetworkExchange.from(ApiExchange exchange, {String? screenId}) {
    final response = exchange.response;
    return NetworkExchange(
      requestId: exchange.request.requestId,
      method: exchange.request.method,
      url: exchange.request.url,
      screenId: screenId,
      requestedAt: exchange.requestedAt,
      respondedAt: exchange.respondedAt,
      statusCode: response?.statusCode,
      error: response?.error,
      durationMs: response?.durationMs,
      outcome: switch (response) {
        null => ExchangeOutcome.unanswered,
        ApiResponsePayload(error: final _?) => ExchangeOutcome.failed,
        ApiResponsePayload(statusCode: null) => ExchangeOutcome.failed,
        final r when r.isSuccess => ExchangeOutcome.success,
        _ => ExchangeOutcome.httpError,
      },
    );
  }

  /// The id the application generated at capture, which pairs this
  /// request with its response and with any API assertion that cites it.
  final String requestId;

  final String method;

  /// As captured: query values the redaction policy treats as sensitive
  /// are already masked.
  final String url;

  /// The screen this request belongs to under the correlator's rule, or
  /// null when it belongs to none.
  final String? screenId;

  /// When the request event was emitted, on the **application's** clock.
  final DateTime requestedAt;

  /// When the response event was emitted, on the application's clock.
  final DateTime? respondedAt;

  final int? statusCode;
  final String? error;

  /// How long the request took, as the application measured it.
  ///
  /// Null when no response was observed. Never 0 in its place: a 0 is a
  /// measurement, and nobody made one.
  final int? durationMs;

  final ExchangeOutcome outcome;

  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'method': method,
        'url': url,
        if (screenId != null) 'screenId': screenId,
        'requestedAt': formatUtcTimestamp(requestedAt),
        if (respondedAt != null)
          'respondedAt': formatUtcTimestamp(respondedAt!),
        'outcome': outcome.wire,
        if (statusCode != null) 'statusCode': statusCode,
        if (error != null) 'error': error,
        if (durationMs != null) 'durationMs': durationMs,
      };
}

/// The run's HTTP traffic, and how much of it the run could see.
///
/// Built once, at the end of a run, from the correlation the run already
/// performs and from four facts the connection already knows. Nothing
/// here re-derives a verdict: the API dimension is decided by
/// `expectApi` and the screen validators, and this record is what a
/// reader looks at to understand them.
@immutable
class NetworkRecord {
  const NetworkRecord({
    required this.state,
    required this.exchanges,
    this.reasons = const [],
    this.orphanResponses = 0,
    this.durationClock,
  });

  /// Assembles the record from what the run observed.
  ///
  /// [advertised] is whether the application's handshake offered the
  /// `network` capability, which it does exactly when its configuration
  /// has capture switched on. [droppedEventCount] is the handshake's own
  /// count of events its startup buffer discarded. [protocolFailure] is
  /// the first event the engine could not read, and [connectionLost]
  /// whether the connection ended without being asked to.
  ///
  /// [monotonicTiming] is whether the handshake also offered
  /// `monotonicNetworkTiming`. Required, so no caller can leave it out and
  /// have every duration silently described as wall-clock.
  ///
  /// Each of those, and a response whose request was never seen, is a
  /// way for a request to have happened and not be in [exchanges]. Any
  /// one of them makes the state [NetworkCaptureState.partial], and each
  /// is named in [reasons] so the report can say which.
  factory NetworkRecord.observe({
    required bool advertised,
    required bool monotonicTiming,
    required CorrelationResult correlation,
    int droppedEventCount = 0,
    String? protocolFailure,
    bool connectionLost = false,
  }) {
    final exchanges = <NetworkExchange>[
      for (final session in correlation.sessions)
        for (final exchange in session.exchanges)
          NetworkExchange.from(exchange, screenId: session.screenId),
      for (final exchange in correlation.unattributed)
        NetworkExchange.from(exchange),
    ];
    // Stable, so two requests stamped with the same millisecond keep the
    // order the application emitted them in.
    _stableSortBy(exchanges, (e) => e.requestedAt);

    final orphans = correlation.orphanResponses.length;

    if (!advertised) {
      return NetworkRecord(
        state: NetworkCaptureState.unavailable,
        exchanges: exchanges,
        orphanResponses: orphans,
        reasons: const [
          'the application did not offer network capture: the SDK is '
              'disabled, enableNetworkCapture is off, or the SDK predates '
              'reporting it. No request was observed, which is not '
              'evidence that none was made.',
        ],
      );
    }

    final reasons = <String>[
      if (droppedEventCount > 0)
        'the application discarded $droppedEventCount buffered '
            'event${droppedEventCount == 1 ? '' : 's'} before the engine '
            'attached, so requests made during start-up may be missing',
      if (protocolFailure != null)
        'an event from the application could not be read '
            '($protocolFailure), so requests after it may be missing',
      if (connectionLost)
        'the connection to the application ended during the run, so '
            'requests after that point were not received',
      if (orphans > 0)
        '$orphans response${orphans == 1 ? '' : 's'} arrived for a '
            'request that was never seen',
    ];

    return NetworkRecord(
      state: reasons.isEmpty
          ? NetworkCaptureState.active
          : NetworkCaptureState.partial,
      exchanges: exchanges,
      reasons: reasons,
      orphanResponses: orphans,
      durationClock: monotonicTiming
          ? NetworkDurationClock.monotonic
          : NetworkDurationClock.wall,
    );
  }

  /// What [NetworkCaptureState.active] covers, written into every record
  /// so a consumer never has to know it from the documentation.
  ///
  /// The support matrix in TECHNICAL_RISKS R9, in one sentence each way.
  static const String scope =
      'dart:io HttpClient (which package:http IOClient and the default dio '
      'adapter use) and requests the application reports through '
      'TestSdk.network. Not seen: custom dio adapters, web fetch, HTTP '
      'performed natively by a plugin, gRPC, WebSockets, endpoints the '
      'redaction policy excludes, and any client the application installs '
      'its own HttpOverrides for after the SDK starts.';

  final NetworkCaptureState state;

  /// Why the state is not [NetworkCaptureState.active], one sentence per
  /// cause. Empty when it is.
  final List<String> reasons;

  /// Every captured request, ordered by when it was issued.
  ///
  /// Run-wide, not per screen: the per-screen lists in `screens[]` hold
  /// only the screens a step validated, and a request on any other
  /// screen, or on none, appeared nowhere in the report before this.
  final List<NetworkExchange> exchanges;

  /// Responses whose request was never seen. Counted rather than listed:
  /// with no request there is no method or URL to list.
  final int orphanResponses;

  /// The clock every `durationMs` in [exchanges] was measured on.
  ///
  /// Null when capture was [NetworkCaptureState.unavailable] - there were
  /// no durations to describe - and absent from any record written before
  /// schema 1.6, which a reader must treat as "not recorded", never as
  /// either value.
  final NetworkDurationClock? durationClock;

  Map<String, Object?> toJson() => {
        'capture': state.wire,
        if (durationClock != null) 'durationClock': durationClock!.wire,
        'scope': scope,
        if (reasons.isNotEmpty) 'reasons': reasons,
        // Said as a number even when it is zero, so a consumer can tell
        // "none were orphaned" from a file written before this was
        // counted.
        'orphanResponses': orphanResponses,
        'exchanges': [for (final e in exchanges) e.toJson()],
      };
}

void _stableSortBy<T>(List<T> items, DateTime Function(T) key) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final byTime = key(a.$2).compareTo(key(b.$2));
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < items.length; i++) {
    items[i] = indexed[i].$2;
  }
}
