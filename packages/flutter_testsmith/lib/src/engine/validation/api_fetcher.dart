import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../secrets/secret_ref.dart';
import 'api_source.dart';

/// What a fetch produced.
///
/// Sealed rather than nullable, for the same reason validation
/// distinguishes skip from error: "it answered 401" and "nothing
/// answered" are different facts and need different words.
@immutable
sealed class FetchOutcome {
  const FetchOutcome();
}

final class FetchSucceeded extends FetchOutcome {
  const FetchSucceeded(this.payload);

  final ApiResponsePayload payload;
}

/// The request did not produce a usable response.
///
/// Always an **error** at the validation layer, never a failure: the
/// runner not being able to reach the backend says nothing about the
/// application.
final class FetchFailed extends FetchOutcome {
  const FetchFailed(this.reason);

  /// One actionable line. Never contains a header, a token, or a
  /// credential of any kind.
  final String reason;
}

/// Issues the request a screen's [ApiSource] describes.
///
/// An interface, mirroring the Figma client's `FigmaHttp`, so every test
/// in this milestone runs without a network. The `dart:io`
/// implementation lives in the CLI (`lib/src/cli/http_api_fetcher.dart`),
/// keeping the engine free of transport - and free of Flutter, which is the constraint that lets
/// the CLI compile to a native binary.
abstract interface class ApiFetcher {
  /// [token] is resolved by the caller immediately before this call and
  /// is not retained afterwards.
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  });
}

/// Builds the payload a fetched response becomes.
///
/// Normalised into the protocol's own [ApiResponsePayload] so the
/// existing comparison validators need no change at all - they already
/// consume this type.
///
/// **Headers are not carried, in either direction.** The authorization
/// header is the one thing that must never reach a report, and the
/// safest way to guarantee that is for it never to enter the model.
/// Response headers are omitted for the same reason: a `set-cookie` is a
/// credential too.
ApiResponsePayload jsonResponse({
  required int? statusCode,
  required String? body,
  required int durationMs,
  String? error,
}) =>
    ApiResponsePayload(
      requestId: 'fetched',
      statusCode: statusCode,
      body: body,
      durationMs: durationMs,
      error: error,
    );
