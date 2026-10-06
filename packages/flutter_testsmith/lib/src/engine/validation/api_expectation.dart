import 'dart:convert';

import 'package:meta/meta.dart';

import '../dsl/steps.dart';
import '../session/screen_session.dart';
import 'response_source.dart';

/// One assertion about a field of a captured response.
///
/// Exactly one of [equals], [count] and [present] is meaningful; the
/// flow parser refuses an entry that sets none or several, so this class
/// never has to decide which wins.
@immutable
final class ApiExpectation {
  const ApiExpectation({
    required this.path,
    this.equals,
    this.count,
    this.present,
  });

  /// A dotted path into the JSON body. A numeric segment indexes a list.
  final String path;

  /// The value the field must hold.
  final Object? equals;

  /// How many entries the list at [path] must hold.
  final int? count;

  /// Whether the field must be there at all.
  ///
  /// The assertion to use for a token or a session id: pinning the
  /// value would mean writing the secret into the test and into every
  /// report the test produces.
  final bool? present;

  /// Whether what was read satisfies this - or why not, in one line.
  ///
  /// [found] is carried separately from [value] because `null` is a
  /// legitimate JSON value: "the field holds null" and "there is no such
  /// field" are different facts and `present:` turns on the difference.
  String? check(Object? value, {required bool found}) {
    final wantedPresent = present;
    if (wantedPresent != null) {
      if (found == wantedPresent) return null;
      return wantedPresent
          ? '"$path" is not in the response body'
          : '"$path" is in the response body and should not be';
    }

    if (!found) return '"$path" is not in the response body';

    final wantedCount = count;
    if (wantedCount != null) {
      if (value is! List) {
        return '"$path" holds ${render(value)}, which is not a list, so '
            'there is nothing to count';
      }
      if (value.length == wantedCount) return null;
      return '"$path" holds ${value.length} '
          '${value.length == 1 ? 'entry' : 'entries'}, expected $wantedCount';
    }

    if (value == equals) return null;
    return '"$path" is ${render(value)}, expected ${render(equals)}';
  }

  /// How a value appears in a failure message.
  ///
  /// A list or an object is described by its size rather than printed.
  /// A dashboard response is 40KB, and a failure nobody can read is a
  /// failure nobody acts on - and a printed body is also how a token
  /// ends up in a report.
  static String render(Object? value) => switch (value) {
        null => 'null',
        final String text => '"$text"',
        final List<Object?> list => 'a list of ${list.length}',
        final Map<Object?, Object?> map => 'an object of ${map.length} keys',
        _ => '$value',
      };

  @override
  String toString() => 'ApiExpectation($path)';
}

/// What asserting on one endpoint produced.
///
/// Carries the endpoint, the status and the failures - and deliberately
/// **not** the response body. A report is a file people paste into
/// tickets, and a step that asserts a token exists must not be the thing
/// that publishes it.
@immutable
final class ApiExpectationOutcome {
  const ApiExpectationOutcome({
    required this.endpoint,
    required this.failures,
    this.status,
    this.screenId,
    this.durationMs,
  });

  /// The endpoint as the application actually called it, when one was
  /// found; as it was declared, when none was.
  final String endpoint;

  /// Every reason this did not hold. Empty when it did.
  final List<String> failures;

  /// The status the application received, or null when nothing answered.
  final int? status;

  /// The screen that was current when the request went out.
  ///
  /// Reported rather than checked: a dashboard whose data was fetched on
  /// the splash screen is normal in a real application, and STOP-1
  /// exists because the platform used to treat that as an error.
  final String? screenId;

  final int? durationMs;

  bool get satisfied => failures.isEmpty;

  String describe() {
    if (satisfied) {
      return '$endpoint $status'
          '${screenId == null ? '' : ' (requested on $screenId)'}';
    }
    return '$endpoint: ${failures.join('; ')}';
  }

  Map<String, Object?> toJson() => {
        'endpoint': endpoint,
        if (status != null) 'status': status,
        if (screenId != null) 'screenId': screenId,
        if (durationMs != null) 'durationMs': durationMs,
        'satisfied': satisfied,
        if (failures.isNotEmpty) 'failures': failures,
      };

  @override
  String toString() => describe();
}

/// Checks one `expectApi` step against what the application captured.
///
/// Reads the **SDK's** exchanges, not the fixture server's log. The two
/// answer different questions: the server's log says what was sent, and
/// this says what the application received. A response served from the
/// app's own cache appears in one and not the other, and that difference
/// is the whole reason this exists.
///
/// Every rule here is a comparison. Nothing samples a clock, and nothing
/// consults a model.
class ApiExpectationEvaluator {
  const ApiExpectationEvaluator();

  ApiExpectationOutcome evaluate({
    required ExpectApiStep step,
    required List<ScreenSession> history,
  }) {
    final candidates = <_Candidate>[];
    final called = <String>[];

    for (final session in history) {
      for (final exchange in session.exchanges) {
        final method = exchange.request.method;
        final path = exchange.request.path;
        final line = '$method $path';
        if (!called.contains(line)) called.add(line);

        // An exchange still in flight is not an answer. Treating one as
        // a missing status would report "expected 200, got none" about a
        // request that simply has not come back yet.
        if (exchange.response == null) continue;
        if (!step.endpoint.matches(method, path)) continue;

        candidates.add(_Candidate(exchange, session.screenId));
      }
    }

    if (candidates.isEmpty) {
      return ApiExpectationOutcome(
        endpoint: '${step.endpoint}',
        failures: [
          'the application did not call ${step.endpoint}. It called: '
              '${called.isEmpty ? 'nothing' : called.join(', ')}',
        ],
      );
    }

    candidates.sort((a, b) => a.at.compareTo(b.at));

    _Candidate? picked;
    if (candidates.length == 1) {
      picked = candidates.single;
    } else {
      switch (step.occurrence) {
        case ResponseOccurrence.only:
          // The same refusal `usesResponseFrom:` makes. Choosing the
          // most recent on the platform's own initiative is how a stale
          // response becomes indistinguishable from a fresh one.
          return ApiExpectationOutcome(
            endpoint: '${step.endpoint}',
            failures: [
              'the application called ${step.endpoint} '
                  '${candidates.length} times, so which one this step means '
                  'is ambiguous. Add `occurrence: first` or '
                  '`occurrence: last` to say which',
            ],
          );
        case ResponseOccurrence.first:
          picked = candidates.first;
        case ResponseOccurrence.last:
          picked = candidates.last;
      }
    }

    final chosen = picked;
    final response = chosen.exchange.response!;
    final endpoint =
        '${chosen.exchange.request.method} ${chosen.exchange.request.path}';

    ApiExpectationOutcome outcome(List<String> failures) =>
        ApiExpectationOutcome(
          endpoint: endpoint,
          failures: failures,
          status: response.statusCode,
          screenId: chosen.screenId,
          durationMs: response.durationMs,
        );

    // A transport error is not a status. "Expected 200, received null"
    // describes a refused connection badly enough to send someone
    // looking at the wrong layer.
    final error = response.error;
    if (error != null) {
      return outcome(['$endpoint did not complete: $error']);
    }

    final status = response.statusCode;
    if (status != step.status) {
      // Reported alone. A 500's body is an error document, so also
      // listing five missing fields buries the one fact that matters.
      return outcome(['$endpoint answered $status, expected ${step.status}']);
    }

    if (step.expectations.isEmpty) return outcome(const []);

    if (response.bodyTruncated) {
      return outcome([
        'the captured body of $endpoint was truncated, so nothing can be '
            'read out of it honestly',
      ]);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body ?? '');
    } on FormatException {
      return outcome([
        'the body of $endpoint is not JSON, so none of the '
            '${step.expectations.length} declared '
            '${step.expectations.length == 1 ? 'field' : 'fields'} could be '
            'read',
      ]);
    }

    return outcome([
      for (final expectation in step.expectations)
        ?_checkOne(expectation, decoded),
    ]);
  }

  String? _checkOne(ApiExpectation expectation, Object? body) {
    final read = _read(body, expectation.path);
    return expectation.check(read.value, found: read.found);
  }

  /// Walks a dotted path, distinguishing "absent" from "holds null".
  static ({bool found, Object? value}) _read(Object? body, String path) {
    Object? current = body;

    for (final segment in path.split('.')) {
      if (current is Map) {
        if (!current.containsKey(segment)) return (found: false, value: null);
        current = current[segment];
        continue;
      }
      if (current is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) {
          return (found: false, value: null);
        }
        current = current[index];
        continue;
      }
      return (found: false, value: null);
    }

    return (found: true, value: current);
  }
}

/// One exchange that matched, with the screen it was requested on.
@immutable
final class _Candidate {
  const _Candidate(this.exchange, this.screenId);

  final ApiExchange exchange;
  final String screenId;

  DateTime get at => exchange.respondedAt ?? exchange.requestedAt;
}
