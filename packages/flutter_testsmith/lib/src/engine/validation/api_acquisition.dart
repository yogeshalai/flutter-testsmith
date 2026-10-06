import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../secrets/secret_ref.dart';
import '../session/screen_session.dart';
import 'api_fetcher.dart';
import 'mappings.dart';
import 'response_source.dart';

/// Where a screen's response came from.
@immutable
sealed class ApiAcquisition {
  const ApiAcquisition();
}

/// The application's own traffic. The preferred answer, always.
final class AcquiredFromCapture extends ApiAcquisition {
  const AcquiredFromCapture({required this.payload, required this.endpoint});

  final ApiResponsePayload payload;
  final String endpoint;
}

/// A request the runner made, because the capture could not supply one.
///
/// A weaker claim than a capture, and the report says so: a
/// non-deterministic or stateful backend may answer the runner
/// differently from the application.
final class AcquiredFromFetch extends ApiAcquisition {
  const AcquiredFromFetch({
    required this.payload,
    required this.endpoint,
    required this.fallbackReason,
  });

  final ApiResponsePayload payload;
  final String endpoint;

  /// Why the capture did not supply it.
  final String fallbackReason;
}

/// Nothing to compare against. An **error**, never a failure.
final class AcquisitionUnavailable extends ApiAcquisition {
  const AcquisitionUnavailable(this.reason);

  final String reason;
}

/// Several captured responses matched and the declaration does not say
/// which.
///
/// Deliberately **not** a fallback trigger. Issuing a request and
/// preferring its answer would silently resolve a question the platform
/// elsewhere refuses to resolve, and would let the runner's own fetch
/// override two responses the application actually received.
final class AcquisitionAmbiguous extends ApiAcquisition {
  const AcquisitionAmbiguous(this.reason);

  final String reason;
}

/// Chooses a screen's response: capture first, a declared fetch second.
///
/// The order is fixed and is the rule this milestone turns on:
///
/// 1. `usesResponseFrom:` - the existing resolver, whole-session,
///    honouring `occurrence`, `capturedOn` and `maxAge`.
/// 2. `api: METHOD /path` - existing behaviour, first match on this
///    screen. Left exactly as it was; tightening it would turn
///    currently-passing runs into errors.
/// 3. `apiSource:` - a derived endpoint, matched with `only` semantics
///    because it is new and can afford to refuse from the outset.
/// 4. nothing declared - the first completed exchange on this screen.
///
/// A fetch is issued only when one of those came back *unavailable*, so
/// a fully-instrumented run makes no outbound request of its own. An
/// *ambiguous* capture never falls back.
class ApiAcquirer {
  const ApiAcquirer();

  Future<ApiAcquisition> acquire({
    required MappingsFile? mappings,
    required ScreenSession session,
    required List<ScreenSession> history,
    required ApiFetcher fetcher,
    required SecretResolver secrets,
  }) async {
    if (mappings == null) {
      return const AcquisitionUnavailable('no mappings for this screen');
    }

    // 1. usesResponseFrom: the most explicit declaration there is.
    final declared = mappings.usesResponseFrom;
    if (declared != null) {
      final resolution = const ResponseResolver().resolve(
        source: declared,
        history: history.isEmpty ? [session] : history,
        renderedScreenEnteredAt: session.enteredAt,
      );
      switch (resolution) {
        case ResponseResolved(:final response):
          return AcquiredFromCapture(
            payload: response.payload,
            endpoint: response.endpoint,
          );
        case ResponseAmbiguous(:final reason):
          return AcquisitionAmbiguous(reason);
        case ResponseUnavailable(:final reason):
          return _fallback(mappings, fetcher, secrets, reason);
      }
    }

    // 2. api: existing behaviour, unchanged.
    final endpoint = ApiEndpoint.tryParse(mappings.api);
    if (endpoint != null) {
      final match = _firstMatch(session, endpoint);
      if (match != null) return match;
      return _fallback(
        mappings,
        fetcher,
        secrets,
        'the mappings name "$endpoint", which this screen did not call. '
        'It called: ${_called(session)}.',
      );
    }

    // 3. apiSource: new, so `only` semantics from the outset.
    final source = mappings.apiSource;
    if (source != null) {
      final base = _resolveBase(source.baseUrl, secrets);
      if (base == null) {
        return AcquisitionUnavailable(
          'the apiSource baseUrl "${source.baseUrl}" resolved to nothing. '
          'Set that environment variable, or put it in a .env file that is '
          'not committed.',
        );
      }
      final required = source.requiredEndpoint(base);
      final matches = _allMatches(session, required);
      if (matches.length > 1) {
        return AcquisitionAmbiguous(
          'the application called $required ${matches.length} times, so '
          'which one this screen is showing is ambiguous. Add '
          '`usesResponseFrom:` with `occurrence: first` or '
          '`occurrence: last` to say which. No request was issued: a fetch '
          'here would silently answer a question this platform refuses to '
          'answer.',
        );
      }
      if (matches.length == 1) {
        return AcquiredFromCapture(
          payload: matches.single.response!,
          endpoint: '$required',
        );
      }
      return _fallback(
        mappings,
        fetcher,
        secrets,
        'the application did not call $required on this screen. '
        'It called: ${_called(session)}.',
      );
    }

    // 4. Nothing declared: existing behaviour.
    for (final exchange in session.exchanges) {
      final payload = exchange.response;
      if (payload != null) {
        return AcquiredFromCapture(
          payload: payload,
          endpoint: '${exchange.request.method} ${exchange.request.path}',
        );
      }
    }
    return const AcquisitionUnavailable(
      'no API response was captured for this screen, so nothing could be '
      'compared',
    );
  }

  /// Issues the declared request, if one is declared.
  ///
  /// Reached only from an *unavailable* capture. Ambiguity returns
  /// before this is called.
  Future<ApiAcquisition> _fallback(
    MappingsFile mappings,
    ApiFetcher fetcher,
    SecretResolver secrets,
    String why,
  ) async {
    final source = mappings.apiSource;
    if (source == null) return AcquisitionUnavailable(why);

    final base = _resolveBase(source.baseUrl, secrets);
    if (base == null) {
      return AcquisitionUnavailable(
        '$why The declared apiSource could not be used either: its baseUrl '
        '"${source.baseUrl}" resolved to nothing.',
      );
    }

    Secret? token;
    final ref = source.token;
    if (ref != null) {
      if (!secrets.isPresent(ref)) {
        return AcquisitionUnavailable(
          '$why The declared apiSource could not be used either: $ref '
          'resolved to nothing. Set the ${ref.name} environment variable, '
          'or put it in a .env file that is not committed.',
        );
      }
      token = secrets.resolve(ref);
    }

    final outcome = await fetcher.fetch(
      source: source,
      resolvedBaseUrl: base,
      token: token,
    );

    switch (outcome) {
      case FetchFailed(:final reason):
        return AcquisitionUnavailable(
          '$why The declared apiSource could not be used either: $reason.',
        );
      case FetchSucceeded(:final payload):
        if (!payload.isSuccess) {
          return AcquisitionUnavailable(
            '$why The declared apiSource answered '
            '${payload.statusCode ?? payload.error}, so there is nothing to '
            'compare against.',
          );
        }
        return AcquiredFromFetch(
          payload: payload,
          endpoint: '${source.method} ${source.endpoint}',
          fallbackReason: why,
        );
    }
  }

  /// Resolves a value that may be an `env:` reference.
  ///
  /// A base URL is not a secret - it is a URL, and a report may name it -
  /// but it is read through the same mechanism so a missing one fails
  /// the same way.
  static String? _resolveBase(String raw, SecretResolver secrets) {
    const prefix = '${SecretRef.envScheme}:';
    if (!raw.startsWith(prefix)) return raw;
    final ref = SecretRef(
      scheme: SecretRef.envScheme,
      name: raw.substring(prefix.length),
    );
    if (!secrets.isPresent(ref)) return null;
    return secrets.resolve(ref).expose();
  }

  static AcquiredFromCapture? _firstMatch(
    ScreenSession session,
    ApiEndpoint endpoint,
  ) {
    for (final exchange in session.exchanges) {
      final payload = exchange.response;
      if (payload == null) continue;
      if (endpoint.matches(exchange.request.method, exchange.request.path)) {
        return AcquiredFromCapture(payload: payload, endpoint: '$endpoint');
      }
    }
    return null;
  }

  static List<ApiExchange> _allMatches(
    ScreenSession session,
    ApiEndpoint endpoint,
  ) =>
      [
        for (final exchange in session.exchanges)
          if (exchange.response != null &&
              endpoint.matches(exchange.request.method, exchange.request.path))
            exchange,
      ];

  static String _called(ScreenSession session) {
    final seen = <String>[];
    for (final exchange in session.exchanges) {
      if (exchange.response == null) continue;
      final line = '${exchange.request.method} ${exchange.request.path}';
      if (!seen.contains(line)) seen.add(line);
    }
    return seen.isEmpty ? 'nothing' : seen.join(', ');
  }
}
