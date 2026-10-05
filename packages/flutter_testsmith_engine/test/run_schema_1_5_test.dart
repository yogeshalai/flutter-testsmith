// Run schema 1.5: the run's network record.
//
// A run captured every request the application made on the paths the
// SDK hooks, and the report showed only those belonging to a screen a
// step validated - with no timestamp, no request id, no statement of
// whether capture was even on, and `durationMs: 0` for a request that
// was never answered. An empty API table read as "the app made no
// calls" whether it had or not.
//
// 1.5 adds `network`, `sessionId` and each step's `startedOffsetMs`,
// additively, and corrects the one fabricated value: an unanswered
// exchange omits `durationMs` instead of claiming 0.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

final _network = NetworkRecord(
  state: NetworkCaptureState.active,
  exchanges: [
    NetworkExchange(
      requestId: 'r1',
      method: 'GET',
      url: 'http://api/products',
      screenId: '/home',
      requestedAt: DateTime.utc(2026, 10, 2, 9, 0, 1),
      respondedAt: DateTime.utc(2026, 10, 2, 9, 0, 1, 80),
      statusCode: 200,
      durationMs: 80,
      outcome: ExchangeOutcome.success,
    ),
  ],
);

RunResult _run({
  NetworkRecord? network,
  String? sessionId,
  int? startedOffsetMs,
  List<ScreenResult> screens = const [],
}) =>
    RunResult(
      flowName: 'browse',
      appId: 'com.example.shop',
      device: 'pixel-7',
      startedAt: DateTime.utc(2026, 10, 2, 9),
      duration: const Duration(seconds: 3),
      steps: [
        StepOutcome(
          description: 'tap "home.open_product"',
          kind: StepKind.tap,
          status: StepStatus.ok,
          durationMs: 40,
          startedOffsetMs: startedOffsetMs,
        ),
      ],
      screens: screens,
      network: network,
      sessionId: sessionId,
    );

void main() {
  group('the version', () {
    // `network`, `sessionId` and `startedOffsetMs` arrived at 1.5; the
    // current version has moved on since, and every schema test pins
    // where it is now.
    test('the run schema is 1.6', () {
      expect(RunResult.schemaVersion, '1.6');
      expect(_run().toJson()['resultSchemaVersion'], '1.6');
    });

    test('the suite schema does not move', () {
      // A suite references each test's result.json; nothing in suite.json
      // itself changed.
      expect(SuiteResult.schemaVersion, '1.1');
    });
  });

  group('additive keys', () {
    test('each is omitted when the run did not record it', () {
      final json = _run().toJson();

      expect(json.containsKey('network'), isFalse);
      expect(json.containsKey('sessionId'), isFalse);
      expect((json['steps'] as List).single,
          isNot(contains('startedOffsetMs')));
    });

    test('each is written when it was recorded', () {
      final json = _run(
        network: _network,
        sessionId: 'session-1',
        startedOffsetMs: 1200,
      ).toJson();

      expect(json['sessionId'], 'session-1');
      expect((json['network'] as Map)['capture'], 'active');
      expect(((json['steps'] as List).single as Map)['startedOffsetMs'], 1200);
    });

    test('every key that existed at 1.4 is still there', () {
      final json = _run(network: _network).toJson();

      for (final key in [
        'resultSchemaVersion', 'flow', 'appId', 'device', 'startedAt',
        'durationMs', 'passed', 'overall', 'dimensions', 'steps', 'screens',
      ]) {
        expect(json, contains(key));
      }
    });

    test('an analysis copy keeps the network record and the session', () {
      final copy = _run(network: _network, sessionId: 'session-1')
          .withAnalysis(const AnalysisUnavailable('no key'));

      expect(copy.network, same(_network));
      expect(copy.sessionId, 'session-1');
    });
  });

  group('no verdict reads the network record', () {
    test('a run whose every request failed still passes on its own terms', () {
      // The API dimension is decided by expectApi and the validators.
      // A failed request nobody asserted on is context, not a verdict.
      final failing = NetworkRecord(
        state: NetworkCaptureState.partial,
        reasons: const ['x'],
        exchanges: [
          NetworkExchange(
            requestId: 'r1',
            method: 'GET',
            url: 'http://api/a',
            requestedAt: DateTime.utc(2026),
            statusCode: 500,
            durationMs: 5,
            outcome: ExchangeOutcome.httpError,
          ),
        ],
      );

      expect(_run(network: failing).passed, _run().passed);
      expect(_run(network: failing).overall, _run().overall);
    });
  });

  group('the corrected per-screen duration', () {
    ScreenResult screen(int? durationMs) => ScreenResult(
          screenId: '/home',
          report: ValidationReport(const []),
          exchanges: [
            ExchangeSummary(
              requestId: 'r1',
              method: 'GET',
              path: '/hangs',
              durationMs: durationMs,
            ),
          ],
        );

    test('an unanswered exchange omits durationMs instead of claiming 0', () {
      final exchange = (screen(null).toJson()['exchanges'] as List).single;

      expect(exchange, isNot(contains('durationMs')));
      expect((exchange as Map)['requestId'], 'r1');
    });

    test('an answered one still carries it', () {
      final exchange = (screen(120).toJson()['exchanges'] as List).single;

      expect((exchange as Map)['durationMs'], 120);
    });
  });

  group('the executor records it from what the session already knows', () {
    // FlowExecutor needs a launched application and is exercised by the
    // device runs. These pin the wiring that the unit tests above cannot
    // reach, as the 1.4 schema test does for the run's preconditions.
    final executor =
        _source('flutter_testsmith_cli/lib/src/flow_executor.dart');

    test('capture state comes from the handshake capability', () {
      expect(executor,
          contains("session.handshake.capabilities.contains('network')"));
      expect(executor,
          contains('droppedEventCount: session.handshake.droppedEventCount'));
      expect(executor,
          contains('protocolFailure: session.transport.protocol.failure'));
      expect(executor, contains('TransportLiveness.disconnected'));
    });

    test('no 0 stands in for an unmeasured duration any more', () {
      expect(executor, isNot(contains('durationMs ?? 0')));
    });

    test('step offsets are read off the run stopwatch, not the wall clock',
        () {
      expect(executor,
          contains('final startedOffsetMs = overall.elapsedMilliseconds'));
    });
  });
}
