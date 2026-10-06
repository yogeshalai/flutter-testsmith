import 'package:meta/meta.dart';

import '../secrets/secret_ref.dart';
import 'response_source.dart';

/// How the runner may fetch this screen's API response for itself.
///
/// A **fallback**, never the first choice. Captured traffic - what the
/// application actually received - is always preferred, because
/// asserting against the server's own reply proves only that the server
/// works, and because a response served from the app's own cache appears
/// in one and not the other. This exists for the case where the capture
/// could not supply what the screen declared it needed.
///
/// Declared in `mappings/<screen>.yaml`, which is user-owned test
/// configuration: hand-written, git-tracked, and never rewritten by the
/// engine.
@immutable
class ApiSource {
  const ApiSource({
    required this.baseUrl,
    required this.method,
    required this.endpoint,
    this.token,
    this.headers = const {},
    this.query = const {},
    this.body,
  });

  /// The development or staging base, or an `env:` reference to one.
  ///
  /// Resolved through the same mechanism as a secret so a missing value
  /// fails with the same actionable message - but it is a URL, not a
  /// credential, and is allowed to appear in a report.
  final String baseUrl;

  final String method;

  /// The path under [baseUrl].
  final String endpoint;

  /// A reference to the credential, never the credential.
  final SecretRef? token;

  final Map<String, String> headers;
  final Map<String, String> query;
  final String? body;

  /// The full URI to request.
  Uri resolvedUri(String resolvedBase) {
    final base = Uri.parse(resolvedBase);
    return base.replace(
      path: _join(base.path, endpoint),
      queryParameters: query.isEmpty ? null : query,
    );
  }

  /// The captured exchange this source describes, for matching against
  /// what the application itself called.
  ///
  /// Derived from the **base URL's path plus the endpoint**, not from
  /// the endpoint alone: a base of `https://host/api/v1` with an
  /// endpoint of `/products/123` is the request the application makes as
  /// `/api/v1/products/123`, and matching on the endpoint alone would
  /// miss it entirely.
  ApiEndpoint requiredEndpoint(String resolvedBase) => ApiEndpoint(
        method.toUpperCase(),
        _join(Uri.parse(resolvedBase).path, endpoint),
      );

  static String _join(String basePath, String endpoint) {
    final left = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final right = endpoint.startsWith('/') ? endpoint : '/$endpoint';
    return '$left$right';
  }

  @override
  String toString() => 'ApiSource($method $baseUrl$endpoint)';
}
