// Run schema 1.6: which clock the network durations were measured on.
//
// From an SDK that advertises `monotonicNetworkTiming`, `durationMs` is
// the difference of two readings of a monotonic source, starting before
// the connection was opened. From an older SDK it was the difference of
// two wall-clock readings, starting after the connection was established.
// Same key, same type, different measurements - so the record says which,
// from what the connected SDK advertised, and a 1.5 artefact that says
// nothing is never relabelled as either.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

RunResult _run(NetworkRecord? network) => RunResult(
      flowName: 'browse',
      appId: 'com.example.shop',
      device: 'pixel-7',
      startedAt: DateTime.utc(2026, 10, 3, 9),
      duration: const Duration(seconds: 3),
      steps: const [],
      screens: const [],
      network: network,
    );

NetworkRecord _record(NetworkDurationClock? clock) => NetworkRecord(
      state: NetworkCaptureState.active,
      durationClock: clock,
      exchanges: [
        NetworkExchange(
          requestId: 'r1',
          method: 'GET',
          url: 'http://api/products',
          requestedAt: DateTime.utc(2026, 10, 3, 9, 0, 1),
          statusCode: 200,
          durationMs: 290,
          outcome: ExchangeOutcome.success,
        ),
      ],
    );

Map<String, Object?> _roundTrip(RunResult run) =>
    jsonDecode(jsonEncode(run.toJson())) as Map<String, Object?>;

void main() {
  group('the version', () {
    test('the run schema is 1.6', () {
      expect(RunResult.schemaVersion, '1.6');
      expect(_run(null).toJson()['resultSchemaVersion'], '1.6');
    });

    test('the suite schema does not move', () {
      expect(SuiteResult.schemaVersion, '1.1');
    });
  });

  group('durationClock through a JSON round trip', () {
    test('monotonic survives encode and decode', () {
      final json = _roundTrip(_run(_record(NetworkDurationClock.monotonic)));

      expect((json['network'] as Map)['durationClock'], 'monotonic');
    });

    test('wall survives encode and decode', () {
      final json = _roundTrip(_run(_record(NetworkDurationClock.wall)));

      expect((json['network'] as Map)['durationClock'], 'wall');
    });

    test('an unrecorded clock stays absent rather than defaulting', () {
      final json = _roundTrip(_run(_record(null)));

      expect(json['network'] as Map, isNot(contains('durationClock')));
    });

    test('the duration itself is unchanged in key and type', () {
      final json = _roundTrip(_run(_record(NetworkDurationClock.monotonic)));
      final exchange =
          ((json['network'] as Map)['exchanges'] as List).single as Map;

      expect(exchange['durationMs'], 290);
    });
  });

  group('no monotonic offsets reach the file', () {
    test('only a duration is carried, never a tick', () {
      final text =
          jsonEncode(_run(_record(NetworkDurationClock.monotonic)).toJson());

      expect(text, isNot(contains('Micros')));
      expect(text, isNot(contains('startedAtTick')));
    });
  });

  group('the executor reads the capability, not a version', () {
    // FlowExecutor needs a launched application; these pin the wiring the
    // unit tests above cannot reach, as the 1.4 and 1.5 schema tests do.
    final executor =
        _source('flutter_testsmith/lib/src/cli/flow_executor.dart');

    test('monotonic timing comes from the handshake', () {
      // Whitespace removed, so line endings and wrapping cannot decide it.
      final compact = executor.replaceAll(RegExp(r'\s+'), '');

      expect(
        compact,
        contains('monotonicTiming:session.handshake.capabilities'
            ".contains('monotonicNetworkTiming')"),
      );
      expect(executor, isNot(contains('sdkVersion')));
    });
  });
}
