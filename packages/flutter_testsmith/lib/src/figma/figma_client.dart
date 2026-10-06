import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// Something went wrong talking to Figma.
///
/// The message never repeats the token back, because these end up in
/// logs and CI output.
@immutable
class FigmaException implements Exception {
  const FigmaException(this.message);

  final String message;

  @override
  String toString() => 'FigmaException: $message';
}

@immutable
class FigmaHttpResponse {
  const FigmaHttpResponse({required this.status, required this.body});

  final int status;
  final String body;
}

/// The HTTP call, behind an interface so the client is testable without
/// a network or a token.
abstract interface class FigmaHttp {
  Future<FigmaHttpResponse> get(String url, Map<String, String> headers);
}

class _RealFigmaHttp implements FigmaHttp {
  const _RealFigmaHttp();

  @override
  Future<FigmaHttpResponse> get(
    String url,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      headers.forEach(request.headers.set);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      return FigmaHttpResponse(status: response.statusCode, body: body);
    } finally {
      client.close();
    }
  }
}

/// Which frame of which file.
@immutable
class FigmaTarget {
  const FigmaTarget({required this.fileKey, required this.nodeId});

  final String fileKey;

  /// Colon form, as the API wants.
  final String nodeId;

  /// Reads a target straight out of a Figma URL.
  ///
  /// URLs carry `node-id=913-1` while the API wants `913:1`.
  /// Making someone translate that by hand is a needless trap, and one
  /// that fails with an unhelpful "node not found".
  factory FigmaTarget.parseUrl(String url) {
    final uri = Uri.parse(url);

    final segments = uri.pathSegments;
    final keyIndex = segments.indexWhere(
      (s) => s == 'design' || s == 'file',
    );
    if (keyIndex == -1 || keyIndex + 1 >= segments.length) {
      throw FormatException(
        'Not a Figma file URL; expected /design/<key>/... or /file/<key>/...',
        url,
      );
    }

    final rawNode = uri.queryParameters['node-id'];
    if (rawNode == null || rawNode.isEmpty) {
      throw FormatException(
        'The URL has no node-id. Open the frame in Figma and copy the '
        'link to it, which includes node-id=...',
        url,
      );
    }

    return FigmaTarget(
      fileKey: segments[keyIndex + 1],
      nodeId: normaliseNodeId(rawNode),
    );
  }

  /// Accepts either the URL's dash form or the API's colon form.
  static String normaliseNodeId(String nodeId) => nodeId.replaceAll('-', ':');

  @override
  String toString() => '$fileKey#$nodeId';
}

/// Reads frames from the Figma REST API, with an on-disk cache.
///
/// Caching is not an optimisation here. Figma rate-limits, a design does
/// not change between two steps of one run, and re-fetching a 100KB
/// frame for every validation would make runs slow and fragile.
class FigmaClient {
  FigmaClient({
    required String token,
    FigmaHttp? http,
    Directory? cacheDirectory,
  })  : _token = token, // ignore: prefer_initializing_formals
        _cacheDirectory = cacheDirectory, // ignore: prefer_initializing_formals
        _http = http ?? const _RealFigmaHttp();

  // Fields are private, so initialising formals cannot be used with
  // these public parameter names; the lint is suppressed rather than
  // leaking `_token` into the public API.

  static const String _base = 'https://api.figma.com/v1';

  final String _token;
  final FigmaHttp _http;
  final Directory? _cacheDirectory;

  /// Reads a node, from the cache when possible.
  Future<Map<String, Object?>> fetchNode({
    required String fileKey,
    required String nodeId,
    bool refresh = false,
  }) async {
    final id = FigmaTarget.normaliseNodeId(nodeId);
    final cacheFile = _cacheFileFor(fileKey, id);

    if (!refresh && cacheFile != null && cacheFile.existsSync()) {
      return _decode(await cacheFile.readAsString(), fileKey, id, cached: true);
    }

    final url = '$_base/files/$fileKey/nodes'
        '?ids=${Uri.encodeQueryComponent(id)}';

    final FigmaHttpResponse response;
    try {
      response = await _http.get(url, {'X-Figma-Token': _token});
    } on IOException catch (error) {
      // Every way the transport can fail, in one clause, because they
      // arrive as three unrelated classes: a DNS failure and a refused
      // connection are `SocketException`, a rejected certificate is a
      // `HandshakeException` under `TlsException`, and a connection cut
      // mid-body is an `HttpException`. `IOException` is the one thing
      // they share. The two other HTTP clients here name `SocketException`
      // and `HttpException` individually, and a TLS failure goes straight
      // past both of them.
      //
      // Unguarded, these left this client as themselves, past
      // `on FigmaException` in `resolveFigmaSources` and `figma pull`,
      // past `bin/testsmith.dart` - which catches `UsageException` and
      // nothing else - and ended the process at 255. A design nobody
      // could fetch is a Figma failure like a rejected token: the run
      // reports it against the screen that declared it.
      throw FigmaException(_unreachable(url, error));
    } on FormatException catch (error) {
      // A response body that is not valid UTF-8. It arrives from the
      // decoder rather than the socket, so it is not an IOException.
      throw FigmaException(_unreachable(url, error));
    } on TimeoutException catch (error) {
      // Nothing here applies a timeout - that is a separate question,
      // and it has a number in it. This is where one belongs when a
      // transport does apply it.
      throw FigmaException(_unreachable(url, error));
    }

    if (response.status != 200) {
      throw FigmaException(_explain(response.status, fileKey, id));
    }

    // Decode before caching, so a gateway error page is never stored as
    // though it were a design.
    final decoded = _decode(response.body, fileKey, id, cached: false);

    if (cacheFile != null) {
      await cacheFile.parent.create(recursive: true);
      // Only the response is written. The token is not part of it.
      await cacheFile.writeAsString(response.body);
    }

    return decoded;
  }

  File? _cacheFileFor(String fileKey, String nodeId) {
    final directory = _cacheDirectory;
    if (directory == null) return null;
    final safe = nodeId.replaceAll(':', '-');
    return File('${directory.path}/$fileKey.$safe.json');
  }

  /// The body as a Figma node response, or a [FigmaException] saying why
  /// it is not one.
  ///
  /// [cached] only changes the remedy. A body that is not a design is the
  /// same news wherever it came from, but a fresh one means the network
  /// is answering badly now, while a stored one keeps answering until
  /// somebody replaces it.
  static Map<String, Object?> _decode(
    String body,
    String fileKey,
    String nodeId, {
    required bool cached,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw FigmaException(
        'Figma returned something that is not JSON for $fileKey#$nodeId. '
        'That usually means a proxy or gateway answered instead.'
        '${cached ? _replaceIt : ''}',
      );
    }

    if (decoded is! Map) {
      throw FigmaException(
        'Figma returned JSON that is not an object.'
        '${cached ? _replaceIt : ''}',
      );
    }

    // The comment above the cache write says a gateway error page must
    // never be stored as though it were a design. Asking only whether
    // the body was a JSON object was not enough to keep that promise: a
    // captive portal or proxy answering HTTP 200 with `{"error": "..."}`
    // passed, was written to `<app>/figma/.cache`, and then killed the
    // normaliser on that run and on every later one - offline, from a
    // directory `.gitignore` covers.
    //
    // `nodes` is what this endpoint always returns and the first thing
    // the normaliser reads. An *empty* `nodes` is a real answer and stays
    // one: it is what Figma says when the id is not in the file, and
    // refusing which node is missing is the normaliser's job.
    if (decoded['nodes'] is! Map) {
      throw FigmaException(
        'Figma answered for $fileKey#$nodeId with JSON that carries no '
        'design ("nodes" is missing). That usually means a proxy or '
        'gateway answered instead.${cached ? _replaceIt : ''}',
      );
    }

    return decoded.cast<String, Object?>();
  }

  /// What to do about a stored answer that is not a design.
  static const String _replaceIt =
      ' It came from the cache; run `testsmith figma pull --refresh` to '
      'replace it.';

  /// A transport failure, named by host rather than by Dart type.
  ///
  /// The URL carries no credential - the token is a header - so the host
  /// is safe to print, and the sentence the platform already uses for an
  /// unreachable service is `could not reach <host>`.
  static String _unreachable(String url, Object error) =>
      'could not reach ${Uri.parse(url).host}: ${_reason(error)}';

  /// What the failure said, without its Dart type name in front of it.
  ///
  /// Each of these carries a `message`, but through classes that share no
  /// interface, so there is nothing to call it on generically.
  static String _reason(Object error) => switch (error) {
        SocketException(:final message, :final osError) =>
          osError == null ? message : '$message (${osError.message})',
        TlsException(:final message) => message,
        HttpException(:final message) => message,
        FormatException(:final message) => message,
        TimeoutException(:final message) => message ?? 'the request timed out',
        _ => '$error',
      };

  static String _explain(int status, String fileKey, String nodeId) =>
      switch (status) {
        401 || 403 =>
          'Figma rejected the token (HTTP $status). Check that it is '
              'current and has access to file $fileKey.',
        404 => 'Figma has no file "$fileKey" or no node "$nodeId" in it '
            '(HTTP 404).',
        429 => 'Figma is rate limiting (HTTP 429). Wait, or rely on the '
            'cached spec.',
        _ => 'Figma returned HTTP $status for $fileKey#$nodeId.',
      };
}
