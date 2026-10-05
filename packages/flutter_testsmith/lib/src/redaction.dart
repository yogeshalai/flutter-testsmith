import 'dart:convert';

import 'package:meta/meta.dart';

/// A body after truncation, and whether truncation happened.
@immutable
class TruncatedBody {
  const TruncatedBody(this.body, {required this.truncated});

  final String? body;
  final bool truncated;
}

/// Cuts [body] to [maxBytes], reporting whether it had to.
///
/// The flag matters as much as the cut: a report showing half a response
/// as though it were the whole thing is worse than one that says it was
/// truncated.
TruncatedBody truncateBody(String? body, {required int maxBytes}) {
  if (body == null) return const TruncatedBody(null, truncated: false);
  if (body.length <= maxBytes) {
    return TruncatedBody(body, truncated: false);
  }
  return TruncatedBody(body.substring(0, maxBytes), truncated: true);
}

/// Which fields, headers and endpoints must never leave the application.
///
/// Redaction runs at capture time, in-process, before an event is
/// emitted: a secret that never enters an event cannot leak from a
/// report, a log, or a crash dump. Redacting at report-generation time
/// would be strictly weaker. See ARCHITECTURE 13.
@immutable
class RedactionPolicy {
  const RedactionPolicy({
    required this.sensitiveKeys,
    this.allowedKeys = const {},
    this.excludedPaths = const {},
    this.sensitivePatterns = defaultPatterns,
  });

  /// Deliberately broad. The cost of over-redacting a field in a test
  /// report is low; the cost of leaking a credential is not.
  const RedactionPolicy.strictDefaults()
      : sensitiveKeys = const {
          'authorization',
          'proxyauthorization',
          'cookie',
          'setcookie',
          'password',
          'passwd',
          'secret',
          'token',
          'accesstoken',
          'refreshtoken',
          'idtoken',
          'apikey',
          'privatekey',
          'session',
          'sessionid',
          'cardnumber',
          'cvv',
          'cvc',
          'pin',
          'otp',
          'ssn',
        },
        allowedKeys = const {},
        excludedPaths = const {},
        sensitivePatterns = defaultPatterns;

  /// What gets written in place of a secret.
  static const String marker = '[REDACTED]';

  /// Substrings that mark a key as a credential even when unlisted.
  ///
  /// Chosen to avoid common false positives: `authorization` rather than
  /// `auth` (which would catch `author`), and `apikey` rather than `key`
  /// (which would catch `keyboard` and `monkey`).
  static const Set<String> defaultPatterns = {
    'password',
    'passwd',
    'secret',
    'token',
    'apikey',
    'authorization',
    'credential',
    'privatekey',
    'cardnumber',
  };

  /// Exact key names, already normalised.
  final Set<String> sensitiveKeys;

  /// Keys explicitly permitted through, overriding every other rule.
  final Set<String> allowedKeys;

  /// Path prefixes never captured at all.
  final Set<String> excludedPaths;

  final Set<String> sensitivePatterns;

  /// Lowercased with separators removed, so `access_token`,
  /// `access-token` and `accessToken` all compare equal.
  static String _normalise(String key) =>
      key.toLowerCase().replaceAll(RegExp('[_\\-. ]'), '');

  bool isSensitive(String key) {
    final normalised = _normalise(key);
    if (allowedKeys.any((k) => _normalise(k) == normalised)) return false;
    if (sensitiveKeys.any((k) => _normalise(k) == normalised)) return true;
    return sensitivePatterns.any(normalised.contains);
  }

  /// Whether this endpoint may be recorded at all.
  bool shouldCapture(Uri url) =>
      !excludedPaths.any((prefix) => url.path.startsWith(prefix));

  Map<String, String> redactHeaders(Map<String, String> headers) => {
        // The name is kept: knowing a request was authenticated is
        // useful, knowing the token is not.
        for (final entry in headers.entries)
          entry.key: isSensitive(entry.key) ? marker : entry.value,
      };

  /// The same rule again, for a credential carried in the query string.
  ///
  /// A query parameter is neither a header nor a decoded body, so it was
  /// the one place a credential reached an event intact - recorded as
  /// Phase 12's limitation L3, with a passing test asserting the leak.
  /// `?token=...` is ordinary in real APIs, and an application this
  /// platform did not grow up with is the one most likely to use it.
  /// `http_api_fetcher.dart` has stripped a query for this reason on the
  /// CLI side all along; the capture path had not.
  ///
  /// Per parameter rather than dropping the whole query, for the reason
  /// [redactHeaders] keeps its names: `?page=2` is diagnostic, and a
  /// report that cannot say which page was asked for has lost something
  /// for nothing. The name survives, the value does not.
  ///
  /// Done on the serialised form rather than through [Uri.replace],
  /// which is lossy here: `queryParametersAll` discards a valueless
  /// `?a=` and a bare `?raw`, and re-encoding turns the marker into
  /// `%5BREDACTED%5D`. Splitting the text touches the pairs that are
  /// sensitive and copies the rest through byte for byte - so a URL
  /// carrying no credential is returned exactly as it arrived.
  String redactUrl(Uri url) {
    final text = url.toString();
    final start = text.indexOf('?');
    if (start == -1) return text;

    // The first literal `?` opens the query and the next literal `#`
    // closes it: anywhere else both are percent-encoded by `Uri`.
    final hash = text.indexOf('#', start);
    final end = hash == -1 ? text.length : hash;

    var redacted = false;
    final pairs = text.substring(start + 1, end).split('&').map((pair) {
      final equals = pair.indexOf('=');
      final name = equals == -1 ? pair : pair.substring(0, equals);
      if (!isSensitive(_decodeName(name))) return pair;
      redacted = true;
      return '$name=$marker';
    }).toList();

    return redacted ? text.replaceRange(start + 1, end, pairs.join('&')) : text;
  }

  /// A parameter name as written, for [isSensitive] to judge.
  ///
  /// Decoded so `access%5Ftoken` is recognised as `access_token`, and
  /// tolerant of a name that will not decode: a malformed escape is a
  /// reason to fall back to the raw text, never a reason to throw out of
  /// a capture that is only observing.
  static String _decodeName(String raw) {
    try {
      return Uri.decodeQueryComponent(raw);
    } on ArgumentError {
      return raw;
    } on FormatException {
      return raw;
    }
  }

  /// Recursively replaces sensitive values in a decoded JSON structure.
  Map<String, Object?> redactJson(Map<String, Object?> json) =>
      _redactValue(json)! as Map<String, Object?>;

  Object? _redactValue(Object? value) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): isSensitive(entry.key.toString())
              ? marker
              : _redactValue(entry.value),
      };
    }
    if (value is List) {
      return [for (final item in value) _redactValue(item)];
    }
    return value;
  }

  /// Redacts a body given as text.
  ///
  /// A body that does not parse as JSON cannot be inspected key by key,
  /// so it cannot be shown to be safe. If it looks like it contains a
  /// credential it is dropped wholesale - the conservative choice, and
  /// the reason is recorded in its place.
  String? redactBodyString(String? body) {
    if (body == null || body.isEmpty) return body;

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        return jsonEncode(redactJson(decoded.cast<String, Object?>()));
      }
      return jsonEncode(_redactValue(decoded));
    } on FormatException {
      return _looksSensitive(body)
          ? '$marker (unparseable body containing a credential-like value)'
          : body;
    }
  }

  bool _looksSensitive(String body) {
    final normalised = _normalise(body);
    return sensitivePatterns.any(normalised.contains);
  }
}
