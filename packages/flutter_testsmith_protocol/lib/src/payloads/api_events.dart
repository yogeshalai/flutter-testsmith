part of '../payloads.dart';

/// An outbound HTTP request, as captured in the application.
///
/// Headers and body have already passed through redaction before this
/// exists: a secret that never enters an event cannot leak from a report,
/// a log or a crash dump. See ARCHITECTURE 13.
final class ApiRequestPayload extends EventPayload {
  const ApiRequestPayload({
    required this.requestId,
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
    this.bodyTruncated = false,
  });

  /// Ties this request to its response. Generated at capture.
  final String requestId;

  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;

  /// Whether [body] was cut short at the configured limit.
  ///
  /// Recorded so no report shows partial data as though it were complete.
  final bool bodyTruncated;

  /// The path alone, for matching a request without its host.
  String get path => Uri.tryParse(url)?.path ?? url;

  @override
  EventType get type => EventType.apiRequest;

  @override
  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'method': method,
        'url': url,
        if (headers.isNotEmpty) 'headers': headers,
        if (body != null) 'body': body,
        if (bodyTruncated) 'bodyTruncated': true,
      };

  factory ApiRequestPayload.fromJson(Map<String, Object?> json) =>
      ApiRequestPayload(
        requestId: json.required<String>('requestId'),
        method: json.required<String>('method'),
        url: json.required<String>('url'),
        headers: json.mapOrEmpty('headers').cast<String, String>(),
        body: json.optional<String>('body'),
        bodyTruncated: json.optional<bool>('bodyTruncated') ?? false,
      );

  @override
  String toString() => 'ApiRequestPayload($method $url)';
}

/// The answer to an [ApiRequestPayload], or the failure to get one.
final class ApiResponsePayload extends EventPayload {
  const ApiResponsePayload({
    required this.requestId,
    required this.durationMs,
    this.statusCode,
    this.headers = const {},
    this.body,
    this.bodyTruncated = false,
    this.error,
  });

  final String requestId;

  /// Null when the request never produced a response at all - a timeout,
  /// a refused connection, a DNS failure. Substituting 0 or 500 here
  /// would misreport what actually happened.
  final int? statusCode;

  final Map<String, String> headers;
  final String? body;
  final bool bodyTruncated;

  /// Set when the request failed without a response.
  final String? error;

  final int durationMs;

  bool get isSuccess {
    final code = statusCode;
    return error == null && code != null && code >= 200 && code < 400;
  }

  /// Reads a dotted path out of a JSON body, or null.
  ///
  /// Returns null rather than throwing for a non-JSON body, a truncated
  /// body, or a missing key: this feeds API-to-UI comparison, where
  /// "absent" is a normal answer and a crash is not. A truncated body is
  /// never parsed, because guessing at the missing half would produce
  /// confident nonsense.
  Object? readPath(String path) {
    if (bodyTruncated) return null;
    final raw = body;
    if (raw == null) return null;

    Object? current;
    try {
      current = jsonDecode(raw);
    } on FormatException {
      return null;
    }

    for (final segment in path.split('.')) {
      if (current is Map && current.containsKey(segment)) {
        current = current[segment];
      } else if (current is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) {
          return null;
        }
        current = current[index];
      } else {
        return null;
      }
    }
    return current;
  }

  @override
  EventType get type => EventType.apiResponse;

  @override
  Map<String, Object?> toJson() => {
        'requestId': requestId,
        if (statusCode != null) 'statusCode': statusCode,
        if (headers.isNotEmpty) 'headers': headers,
        if (body != null) 'body': body,
        if (bodyTruncated) 'bodyTruncated': true,
        if (error != null) 'error': error,
        'durationMs': durationMs,
      };

  factory ApiResponsePayload.fromJson(Map<String, Object?> json) =>
      ApiResponsePayload(
        requestId: json.required<String>('requestId'),
        statusCode: json.optional<int>('statusCode'),
        headers: json.mapOrEmpty('headers').cast<String, String>(),
        body: json.optional<String>('body'),
        bodyTruncated: json.optional<bool>('bodyTruncated') ?? false,
        error: json.optional<String>('error'),
        durationMs: json.required<int>('durationMs'),
      );

  @override
  String toString() =>
      'ApiResponsePayload(${statusCode ?? error}, ${durationMs}ms)';
}
