import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A scenario file could not be read.
///
/// Always names the file. A fixture that silently falls back to the
/// default state is the single worst failure available here: the run goes
/// green having tested the happy path under an edge-case name, and
/// reports coverage that does not exist.
@immutable
class ScenarioFormatException implements Exception {
  const ScenarioFormatException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => 'ScenarioFormatException in $source: $message';
}

/// What the mock API answers for one route.
@immutable
class ScenarioRoute {
  const ScenarioRoute({
    this.status = 200,
    this.body,
    this.rawBody,
    this.bodyBytes,
    this.headers = const {},
    this.delay = Duration.zero,
  });

  /// The HTTP status to return.
  final int status;

  /// A JSON-encodable body.
  final Object? body;

  /// A body sent verbatim, bypassing JSON encoding.
  ///
  /// The only way to test a malformed response: anything routed through
  /// [jsonEncode] is well-formed by construction.
  final String? rawBody;

  /// A body sent as bytes, decoded from the scenario's `bodyBase64`.
  ///
  /// The only way to answer with a picture. A screen that draws remote
  /// images cannot be photographed deterministically while those images
  /// come from somebody else's CDN, and neither [body] - which goes
  /// through [jsonEncode] - nor [rawBody] - a Dart string - can carry a
  /// PNG intact.
  final Uint8List? bodyBytes;

  final Map<String, String> headers;

  /// How long to wait before answering.
  ///
  /// A client-side timeout cannot be tested without this, and a real
  /// timeout is not the same event as a 500: one produces a response
  /// with an error status, the other produces no response at all.
  final Duration delay;

  /// The text to write, or null when there is none to write.
  ///
  /// Null for a binary route as well as for an empty one: writing
  /// base64 as text would send a corrupt image rather than failing, and
  /// a caller that forgets [bodyBytes] should send nothing instead.
  String? get bodyText {
    if (bodyBytes != null) return null;
    if (rawBody != null) return rawBody;
    if (body == null) return null;
    return jsonEncode(body);
  }

  static const Set<String> _keys = {
    'status',
    'body',
    'rawBody',
    'bodyBase64',
    'headers',
    'delayMs',
  };

  /// The body keys that are mutually exclusive.
  static const List<String> _bodyKeys = ['body', 'rawBody', 'bodyBase64'];

  factory ScenarioRoute.fromJson(
    Map<String, Object?> json, {
    required String source,
    required String route,
  }) {
    void fail(String message) =>
        throw ScenarioFormatException(source, 'route "$route": $message');

    for (final key in json.keys) {
      if (!_keys.contains(key)) {
        fail('unknown key "$key". Known: ${_keys.join(', ')}.');
      }
    }

    final given = [for (final key in _bodyKeys) if (json.containsKey(key)) key];
    if (given.length > 1) {
      final both = given.length == 2 ? 'both ' : '';
      final named = given.map((k) => '"$k"').join(' and ');
      fail('sets $both$named, so which one is sent has no defensible '
          'answer. Use "rawBody" alone for a malformed reply, and '
          '"bodyBase64" alone for a picture.');
    }

    final status = json['status'] ?? 200;
    if (status is! int || status < 100 || status > 599) {
      fail('"status" must be an HTTP status code, not "$status"');
    }

    final delayMs = json['delayMs'] ?? 0;
    if (delayMs is! int || delayMs < 0) {
      fail('"delayMs" must be a whole number of milliseconds, not '
          '"$delayMs"');
    }

    final rawHeaders = json['headers'];
    if (rawHeaders != null && rawHeaders is! Map) {
      fail('"headers" must be a mapping of name to value');
    }

    final rawBody = json['rawBody'];
    if (rawBody != null && rawBody is! String) {
      fail('"rawBody" must be a string; it is sent verbatim');
    }

    final encoded = json['bodyBase64'];
    if (encoded != null && encoded is! String) {
      fail('"bodyBase64" must be a base64 string holding the bytes to send');
    }
    Uint8List? bytes;
    if (encoded != null) {
      try {
        bytes = base64Decode(encoded as String);
      } on FormatException catch (error) {
        // At parse time, not on the first request. A fixture serving a
        // corrupt image would leave the screen showing a broken-image
        // placeholder, which photographs perfectly well and says
        // nothing about why.
        fail('"bodyBase64" must be base64: ${error.message}');
      }
    }

    return ScenarioRoute(
      status: status as int,
      body: json['body'],
      rawBody: rawBody as String?,
      bodyBytes: bytes,
      headers: {
        for (final entry in (rawHeaders as Map?)?.cast<Object?, Object?>().entries ??
            const <MapEntry<Object?, Object?>>[])
          entry.key.toString(): entry.value.toString(),
      },
      delay: Duration(milliseconds: delayMs as int),
    );
  }

  @override
  String toString() => 'ScenarioRoute($status'
      '${delay == Duration.zero ? '' : ', after ${delay.inMilliseconds}ms'})';
}

/// A named, deterministic API state.
///
/// A flow names one of these, and that name is the whole contract: the
/// scenario says what the API returns and the flow says what the screen
/// must then do. Before this existed the mock API served one static file
/// and a scenario called `api_404_not_found` tested the happy path.
///
/// Deliberately in `flutter_testsmith_engine` rather than the CLI: parsing and
/// resolution are the part worth testing, and neither needs `dart:io`.
@immutable
class ApiScenario {
  const ApiScenario({
    required this.name,
    required this.routes,
    this.description = '',
    this.inherits,
  });

  final String name;
  final String description;

  /// Keyed by `METHOD /path`, where a path segment may be `*`.
  final Map<String, ScenarioRoute> routes;

  /// The scenario this one is a delta against, if any.
  ///
  /// Resolved by the loader, which knows where files live; this class
  /// only records what was asked for. That keeps the whole of
  /// scenario semantics testable with no filesystem.
  final String? inherits;

  static const Set<String> _keys = {
    'name',
    'description',
    'inherits',
    'routes',
  };

  static final RegExp _route = RegExp(r'^([A-Z]+) (/\S*)$');

  factory ApiScenario.parse(String text, {required String source}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw ScenarioFormatException(source, 'invalid JSON: ${error.message}');
    }

    if (decoded is! Map) {
      throw ScenarioFormatException(
        source,
        'expected an object with "name" and "routes"',
      );
    }
    final json = decoded.cast<String, Object?>();

    for (final key in json.keys) {
      if (!_keys.contains(key)) {
        throw ScenarioFormatException(
          source,
          'unknown key "$key". Known: ${_keys.join(', ')}.',
        );
      }
    }

    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw ScenarioFormatException(source, 'a "name" is required');
    }

    final rawRoutes = json['routes'];
    if (rawRoutes != null && rawRoutes is! Map) {
      throw ScenarioFormatException(
        source,
        '"routes" must be a mapping of "METHOD /path" to a reply',
      );
    }

    final routes = <String, ScenarioRoute>{};
    for (final entry
        in (rawRoutes as Map?)?.cast<Object?, Object?>().entries ??
            const <MapEntry<Object?, Object?>>[]) {
      final key = entry.key.toString();
      if (!_route.hasMatch(key)) {
        throw ScenarioFormatException(
          source,
          'route "$key" is not of the form METHOD /path, as in '
          '"GET /products/123"',
        );
      }
      final value = entry.value;
      if (value is! Map) {
        throw ScenarioFormatException(
          source,
          'route "$key" must map to an object',
        );
      }
      routes[key] = ScenarioRoute.fromJson(
        value.cast<String, Object?>(),
        source: source,
        route: key,
      );
    }

    // The same check `name` above has always had. `inherits` was a
    // cast, so the same kind of slip in the same file gave two answers:
    // `generate` and `preflight` exited 255 with a stack trace, while
    // `suite run` exited 2 only because the broad guard at its step 5
    // happened to catch it. Absent and an explicit `null` both still
    // mean "no parent", exactly as the cast did.
    final inherits = json['inherits'];
    if (inherits != null && inherits is! String) {
      throw ScenarioFormatException(
        source,
        '"inherits" must name another scenario, as in `"inherits": "default"`',
      );
    }

    return ApiScenario(
      name: name,
      description: (json['description'] ?? '').toString(),
      inherits: inherits as String?,
      routes: Map.unmodifiable(routes),
    );
  }

  /// This scenario's routes laid over [base]'s.
  ///
  /// A delta, not a replacement: a scenario that says "the product is out
  /// of stock" should not have to restate the cart, the login and the
  /// checkout to say it.
  ApiScenario mergedOnto(ApiScenario base) => ApiScenario(
        name: name,
        description: description,
        inherits: inherits,
        routes: Map.unmodifiable({...base.routes, ...routes}),
      );

  /// The reply for one request, or null if this scenario says nothing
  /// about it.
  ///
  /// An exact route always beats a wildcard: `GET /products/*` returning
  /// 404 plus `GET /products/123` returning 200 is the natural way to say
  /// "only this product exists", and the other precedence would make that
  /// unexpressible.
  ScenarioRoute? match(String method, String path) {
    final normalised = path.isEmpty ? '/' : path;
    final exact = routes['$method $normalised'];
    if (exact != null) return exact;

    final wanted = _segments(normalised);
    for (final entry in routes.entries) {
      final parts = entry.key.split(' ');
      if (parts.first != method) continue;
      final pattern = _segments(parts.last);
      if (pattern.length != wanted.length) continue;

      var matches = true;
      for (var i = 0; i < pattern.length; i++) {
        if (pattern[i] == '*') continue;
        if (pattern[i] != wanted[i]) {
          matches = false;
          break;
        }
      }
      if (matches) return entry.value;
    }
    return null;
  }

  static List<String> _segments(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  @override
  String toString() => 'ApiScenario($name, ${routes.length} route(s))';
}
