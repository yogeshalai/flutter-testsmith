import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Issues a screen's declared API request over real HTTP.
///
/// Every failure mode becomes a [FetchFailed] carrying one actionable
/// line. None of them names a header: the authorization header is
/// exactly what must not reach a log or a report, and an error message
/// added in a hurry is how it would get there.
class HttpApiFetcher implements ApiFetcher {
  const HttpApiFetcher({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  @override
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  }) async {
    final Uri uri;
    try {
      uri = source.resolvedUri(resolvedBaseUrl);
    } on FormatException {
      return FetchFailed(
        '"$resolvedBaseUrl" with endpoint "${source.endpoint}" is not a '
        'usable URL',
      );
    }

    final client = HttpClient()..connectionTimeout = timeout;
    final watch = Stopwatch()..start();
    try {
      final request = await client.openUrl(source.method, uri);

      source.headers.forEach(request.headers.set);
      if (token != null) {
        // The one place the value is exposed. It goes straight into the
        // header and nothing holds it afterwards.
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer ${token.expose()}');
      }

      final body = source.body;
      if (body != null) {
        request.headers.contentType ??= ContentType.json;
        request.write(body);
      }

      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join();

      return FetchSucceeded(
        jsonResponse(
          statusCode: response.statusCode,
          body: text,
          durationMs: watch.elapsedMilliseconds,
        ),
      );
    } on TimeoutException {
      return FetchFailed(
        '${source.method} ${_safe(uri)} did not answer within '
        '${timeout.inSeconds}s',
      );
    } on SocketException catch (error) {
      return FetchFailed(
        '${source.method} ${_safe(uri)} could not be reached: '
        '${error.osError?.message ?? error.message}',
      );
    } on HttpException catch (error) {
      return FetchFailed(
        '${source.method} ${_safe(uri)} failed: ${error.message}',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// The URL without its query, which can carry a credential of its own.
  static String _safe(Uri uri) => uri.replace(query: '').toString();
}
