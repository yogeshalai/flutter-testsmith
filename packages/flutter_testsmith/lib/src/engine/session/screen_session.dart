import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

/// One request and the response it did or did not get.
@immutable
class ApiExchange {
  const ApiExchange({
    required this.request,
    required this.requestedAt,
    this.response,
    this.respondedAt,
  });

  final ApiRequestPayload request;
  final DateTime requestedAt;

  /// Null while the request is unanswered.
  ///
  /// An unanswered request is kept and marked, never dropped: a request
  /// that hangs is a finding in its own right.
  final ApiResponsePayload? response;
  final DateTime? respondedAt;

  bool get isComplete => response != null;

  bool get succeeded => response?.isSuccess ?? false;

  /// Whether this was still outstanding at [moment].
  ///
  /// This is what separates a request made *for* the screen being
  /// navigated to from one that merely finished late.
  bool wasInFlightAt(DateTime moment) {
    if (requestedAt.isAfter(moment)) return false;
    final answeredAt = respondedAt;
    return answeredAt == null || answeredAt.isAfter(moment);
  }

  ApiExchange withResponse(ApiResponsePayload payload, DateTime when) =>
      ApiExchange(
        request: request,
        requestedAt: requestedAt,
        response: payload,
        respondedAt: when,
      );

  @override
  String toString() =>
      'ApiExchange(${request.method} ${request.path} -> '
      '${response?.statusCode ?? response?.error ?? 'pending'})';
}

/// Everything observed while one screen was on display.
///
/// This is the unit `validateScreen` will run against: the API traffic,
/// the UI tree and the screenshot for one screen, correlated.
class ScreenSession {
  ScreenSession({
    required this.screenId,
    required this.enteredAt,
    this.exitedAt,
  });

  final String screenId;
  final DateTime enteredAt;

  /// Null for the screen still on display at the end of the run.
  DateTime? exitedAt;

  final List<ApiExchange> exchanges = <ApiExchange>[];

  /// Captured while this screen was current, when one was taken.
  UiSnapshot? uiSnapshot;

  bool get allExchangesSucceeded => exchanges.every((e) => e.succeeded);

  List<ApiExchange> get failedExchanges =>
      [for (final e in exchanges) if (!e.succeeded) e];

  /// The exchange for [path], or null.
  ApiExchange? exchangeFor(String path) {
    for (final exchange in exchanges) {
      if (exchange.request.path == path) return exchange;
    }
    return null;
  }

  @override
  String toString() =>
      'ScreenSession($screenId, ${exchanges.length} exchanges)';
}
