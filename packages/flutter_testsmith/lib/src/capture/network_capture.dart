import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../config.dart';
import '../identity/event_id.dart';
import '../redaction.dart';

/// Microseconds on a monotonic clock.
///
/// Only the difference between two readings means anything. A reading is
/// not a time of day, does not survive the process, and is never sent
/// anywhere: what leaves the application is a duration computed from two
/// readings of the same source.
typedef MonotonicMicros = int Function();

class _InFlight {
  _InFlight(this.requestId, this.startedAtMicros, this.url);

  final String requestId;

  /// A [MonotonicMicros] reading from this capture's own source.
  final int startedAtMicros;

  /// Kept so a failure that quotes the URL can be redacted the way the
  /// request already was.
  final Uri url;
}

/// The shared core of every network capture adapter.
///
/// Adapters differ only in how they hook a client; what they do with what
/// they see - redact, truncate, pair, time, emit - is all here, and all
/// unit tested. An adapter that reimplemented any of this would be a
/// second place for a credential to leak.
///
/// This is also the public surface an application uses to wire up a client
/// the SDK does not know about:
///
/// ```dart
/// final id = TestSdk.network?.begin(method: 'GET', url: uri, headers: h);
/// // ... perform the request ...
/// TestSdk.network?.complete(id, statusCode: 200, body: body);
/// ```
///
/// `begin` returns null for an endpoint that must not be captured, and
/// `complete`/`fail` accept null, so a caller never has to branch.
///
/// **Durations are monotonic.** Each is the difference of two readings of
/// [monotonicMicros], rounded down to whole milliseconds. It used to be
/// the difference of two `DateTime.now()` readings, which a clock step
/// mid-request - NTP, a user, a timezone sync - stretched, shrank or made
/// negative. The wall clock is still what stamps each event, for display;
/// no duration is ever computed from it. This is what the handshake's
/// `monotonicNetworkTiming` capability promises.
class NetworkCapture {
  NetworkCapture({
    required this.config,
    required this._emit,
    String Function()? generateId,
    MonotonicMicros? monotonicMicros,
  })  : _generateId = generateId ?? generateUuidV4,
        monotonicMicros = monotonicMicros ?? _stopwatchMicros();

  final TestSdkConfig config;
  final void Function(EventPayload payload) _emit;
  final String Function() _generateId;

  /// This capture's clock: a [Stopwatch] started with it, unless a test
  /// supplied another.
  ///
  /// [Stopwatch] is documented to increase monotonically, and on the VM
  /// that Flutter runs it reads the platform's monotonic tick rather than
  /// the time of day. One source per capture, so a reading from one
  /// session is never measured against another's.
  final MonotonicMicros monotonicMicros;

  static MonotonicMicros _stopwatchMicros() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMicroseconds;
  }

  final Map<String, _InFlight> _inFlight = <String, _InFlight>{};

  /// Requests issued but not yet answered.
  ///
  /// Settle detection needs this: a screen is not ready to validate while
  /// it is still waiting on the network. See ARCHITECTURE 10.3.
  int get inFlightCount => _inFlight.length;

  RedactionPolicy get _redaction => config.redaction;

  /// Records the start of a request, returning an id to complete it with.
  ///
  /// Returns null when this exchange must not be captured at all, in
  /// which case nothing about it is ever emitted.
  ///
  /// [startedAtMicros] is when the request really began, read from
  /// [monotonicMicros] before any of it happened. The `dart:io` adapter
  /// reads it before opening the connection, because `openUrl` is where
  /// DNS, TCP and TLS happen and the request event cannot be built until
  /// the headers are final at `close()`. Omitted, the request is timed
  /// from now. A reading later than now cannot have come from this clock
  /// and is ignored for the same reason: a duration is never negative.
  String? begin({
    required String method,
    required Uri url,
    Map<String, String> headers = const {},
    String? body,
    int? startedAtMicros,
  }) {
    if (!config.enabled || !config.enableNetworkCapture) return null;
    if (!_redaction.shouldCapture(url)) return null;

    final now = monotonicMicros();
    final startedAt =
        startedAtMicros == null || startedAtMicros > now ? now : startedAtMicros;

    final requestId = _generateId();
    _inFlight[requestId] = _InFlight(requestId, startedAt, url);

    final truncated = truncateBody(
      _redaction.redactBodyString(body),
      maxBytes: config.maxBodyBytes,
    );

    _emit(
      ApiRequestPayload(
        requestId: requestId,
        method: method,
        url: _redaction.redactUrl(url),
        headers: _redaction.redactHeaders(headers),
        body: truncated.body,
        bodyTruncated: truncated.truncated,
      ),
    );

    return requestId;
  }

  void complete(
    String? requestId, {
    int? statusCode,
    Map<String, String> headers = const {},
    String? body,
  }) {
    final entry = _take(requestId);
    if (entry == null) return;

    final truncated = truncateBody(
      _redaction.redactBodyString(body),
      maxBytes: config.maxBodyBytes,
    );

    _emit(
      ApiResponsePayload(
        requestId: entry.requestId,
        statusCode: statusCode,
        headers: _redaction.redactHeaders(headers),
        body: truncated.body,
        bodyTruncated: truncated.truncated,
        durationMs: _elapsedMs(entry),
      ),
    );
  }

  void fail(String? requestId, {required Object error}) {
    final entry = _take(requestId);
    if (entry == null) return;

    _emit(
      ApiResponsePayload(
        requestId: entry.requestId,
        error: _redactedError(error, entry.url),
        durationMs: _elapsedMs(entry),
      ),
    );
  }

  /// The error's own text, with the request's URL in it redacted.
  ///
  /// `dart:io`'s `HttpException` prints `uri = <the whole URL>`, so a
  /// query credential the request event had masked came straight back in
  /// the failure that followed it - and from there into `result.json` and
  /// the report beside it. Replaced as the exact text `Uri` produces,
  /// which is how `HttpException` writes it; a client that formats the
  /// URL some other way is not recognised here.
  String _redactedError(Object error, Uri url) {
    final text = error.toString();
    final raw = url.toString();
    final redacted = _redaction.redactUrl(url);
    return raw == redacted ? text : text.replaceAll(raw, redacted);
  }

  _InFlight? _take(String? requestId) {
    if (requestId == null) return null;
    return _inFlight.remove(requestId);
  }

  /// Whole milliseconds since [entry] began, rounded down.
  ///
  /// Never negative: [begin] refuses a start later than its own reading,
  /// and the source only moves forward.
  int _elapsedMs(_InFlight entry) =>
      (monotonicMicros() - entry.startedAtMicros) ~/ 1000;
}
