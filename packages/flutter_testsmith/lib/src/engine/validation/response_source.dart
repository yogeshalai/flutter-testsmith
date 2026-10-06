import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../session/screen_session.dart';

/// A `METHOD /path` naming one endpoint.
///
/// A path segment may be `*`, so a screen bound to `GET /api/orders/*`
/// keeps working when the id changes.
@immutable
class ApiEndpoint {
  const ApiEndpoint(this.method, this.path);

  final String method;
  final String path;

  static final RegExp _pattern = RegExp(r'^\s*([A-Za-z]+)\s+(/\S*)\s*$');

  /// Parses `GET /a/b`, or null for anything else.
  static ApiEndpoint? tryParse(String? declaration) {
    if (declaration == null) return null;
    final match = _pattern.firstMatch(declaration);
    if (match == null) return null;
    return ApiEndpoint(match.group(1)!.toUpperCase(), match.group(2)!);
  }

  bool matches(String method, String path) {
    if (method.toUpperCase() != this.method) return false;
    if (path == this.path) return true;

    final wanted = _segments(this.path);
    final actual = _segments(path);
    if (wanted.length != actual.length) return false;

    for (var i = 0; i < wanted.length; i++) {
      if (wanted[i] == '*') continue;
      if (wanted[i] != actual[i]) return false;
    }
    return true;
  }

  static List<String> _segments(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  @override
  String toString() => '$method $path';
}

/// Which of several matching responses a declaration means.
///
/// [only] is the default and the safe one: more than one candidate is
/// an ambiguity the platform refuses to resolve on its own. [first] and
/// [last] exist so a person can state the rule explicitly - which is
/// different in kind from the platform guessing by recency.
enum ResponseOccurrence {
  only('only'),
  first('first'),
  last('last');

  const ResponseOccurrence(this.wire);

  final String wire;

  static ResponseOccurrence? tryParse(String value) {
    for (final occurrence in values) {
      if (occurrence.wire == value) return occurrence;
    }
    return null;
  }
}

/// Where a screen's data came from, as declared by a person.
///
/// The problem this exists for: a screen frequently renders data it did
/// not fetch. Measured on a real application - a profile screen whose
/// request happened during splash, and which itself called only a
/// third-party geocoding endpoint.
///
/// The declaration is deliberately **explicit**. Searching the session
/// for "the most recent response that fits" would make a stale reply
/// from minutes earlier indistinguishable from a fresh one, which is the
/// class of quiet wrongness the platform exists to avoid.
@immutable
class ResponseSource {
  const ResponseSource({
    required this.endpoint,
    this.occurrence = ResponseOccurrence.only,
    this.capturedOn,
    this.maxAge,
  });

  final ApiEndpoint endpoint;

  /// How to choose when more than one response matches.
  final ResponseOccurrence occurrence;

  /// Only consider responses captured while this screen was current.
  final String? capturedOn;

  /// How old the response may be when the screen was entered.
  ///
  /// Null means no limit, which is honest rather than lax: the platform
  /// does not know what "too old" means for a given field, so it makes
  /// a team say so. The age is reported either way.
  final Duration? maxAge;

  @override
  String toString() => '$endpoint'
      '${capturedOn == null ? '' : ' captured on $capturedOn'}'
      '${occurrence == ResponseOccurrence.only ? '' : ' (${occurrence.wire})'}';
}

/// A response, and everything known about where it came from.
@immutable
class ResolvedResponse {
  const ResolvedResponse({
    required this.payload,
    required this.endpoint,
    required this.capturedOnScreen,
    required this.capturedAt,
    required this.requestId,
    required this.age,
  });

  final ApiResponsePayload payload;

  /// The endpoint as it was actually called, not as it was declared.
  final String endpoint;

  /// The screen that was current when the request was made.
  final String capturedOnScreen;

  final DateTime capturedAt;
  final String requestId;

  /// How long before the rendering screen was entered this was captured.
  ///
  /// Never negative: a response that arrived after the screen opened is
  /// zero seconds old, not minus five.
  final Duration age;
}

/// The outcome of looking for a declared response.
///
/// A sealed result rather than a nullable one, for the same reason
/// validation distinguishes skip from error: "it is not there" and "there
/// are three of them" are different facts and need different words.
@immutable
sealed class ResponseResolution {
  const ResponseResolution();
}

final class ResponseResolved extends ResponseResolution {
  const ResponseResolved(this.response);

  final ResolvedResponse response;
}

/// Nothing matched. An **error**, never a failure: missing source data
/// is not evidence about the application.
final class ResponseUnavailable extends ResponseResolution {
  const ResponseUnavailable(this.reason);

  final String reason;
}

/// Several matched and the declaration does not say which.
final class ResponseAmbiguous extends ResponseResolution {
  const ResponseAmbiguous(this.reason, this.candidates);

  final String reason;
  final List<ResolvedResponse> candidates;
}

/// Finds the response a [ResponseSource] names, anywhere in a session.
///
/// The whole algorithm, stated so it can be argued with:
///
/// 1. Consider every **completed** exchange in every screen session, in
///    the order they were captured.
/// 2. Keep those whose method and path match the declared endpoint.
/// 3. If `capturedOn` is set, keep only those captured on that screen.
/// 4. If nothing remains, the result is *unavailable*.
/// 5. If more than one remains, `occurrence` decides: `only` refuses,
///    `first` takes the earliest, `last` the most recent.
/// 6. If `maxAge` is set and the chosen response is older than that
///    relative to the rendering screen's entry, the result is
///    *unavailable* with the age named.
///
/// Nothing here consults recency unless a person wrote `last`.
class ResponseResolver {
  const ResponseResolver();

  ResponseResolution resolve({
    required ResponseSource source,
    required List<ScreenSession> history,
    required DateTime renderedScreenEnteredAt,
  }) {
    final candidates = <ResolvedResponse>[];

    for (final session in history) {
      for (final exchange in session.exchanges) {
        final payload = exchange.response;
        if (payload == null) continue;

        final method = exchange.request.method;
        final path = exchange.request.path;
        if (!source.endpoint.matches(method, path)) continue;
        if (source.capturedOn != null &&
            session.screenId != source.capturedOn) {
          continue;
        }

        final capturedAt = exchange.respondedAt ?? exchange.requestedAt;
        final gap = renderedScreenEnteredAt.difference(capturedAt);

        candidates.add(
          ResolvedResponse(
            payload: payload,
            endpoint: '$method $path',
            capturedOnScreen: session.screenId,
            capturedAt: capturedAt,
            requestId: exchange.request.requestId,
            // A response that arrived after the screen opened is not
            // "minus five seconds old".
            age: gap.isNegative ? Duration.zero : gap,
          ),
        );
      }
    }

    candidates.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));

    if (candidates.isEmpty) {
      return ResponseUnavailable(
        'the mappings declare `usesResponseFrom: ${source.endpoint}`'
        '${source.capturedOn == null ? '' : ' captured on '
            '"${source.capturedOn}"'}, which was not captured anywhere in '
        'this session. Captured: ${_describe(history)}.',
      );
    }

    final ResolvedResponse chosen;
    if (candidates.length == 1) {
      chosen = candidates.single;
    } else {
      switch (source.occurrence) {
        case ResponseOccurrence.only:
          return ResponseAmbiguous(
            '${candidates.length} responses match '
            '`usesResponseFrom: ${source.endpoint}`, so which one this '
            'screen is showing is ambiguous. They were captured on: '
            '${candidates.map((c) => '${c.capturedOnScreen} at '
                '${formatUtcTimestamp(c.capturedAt)}').join('; ')}. '
            'Add `occurrence: first` or `occurrence: last`, or '
            '`capturedOn:`, to say which one is meant.',
            candidates,
          );
        case ResponseOccurrence.first:
          chosen = candidates.first;
        case ResponseOccurrence.last:
          chosen = candidates.last;
      }
    }

    final limit = source.maxAge;
    if (limit != null && chosen.age > limit) {
      return ResponseUnavailable(
        'the response for ${source.endpoint} was captured on '
        '"${chosen.capturedOnScreen}" ${chosen.age.inSeconds}s before this '
        'screen was entered, which is older than the declared '
        'maxAgeSeconds of ${limit.inSeconds}. Nothing recent enough was '
        'captured to judge this screen against.',
      );
    }

    return ResponseResolved(chosen);
  }

  /// What the session did capture, for a diagnostic.
  static String _describe(List<ScreenSession> history) {
    final seen = <String>[];
    for (final session in history) {
      for (final exchange in session.exchanges) {
        if (exchange.response == null) continue;
        final line = '${exchange.request.method} ${exchange.request.path} '
            '(on ${session.screenId})';
        if (!seen.contains(line)) seen.add(line);
      }
    }
    return seen.isEmpty ? 'nothing' : seen.join(', ');
  }
}
