// Run schema 1.4: the run's preconditions.
//
// `result.json` is offered as the stable, versioned contract a cloud
// backend, a dashboard or a history would read. A history has to be able
// to answer "did this regress because the application changed, or
// because the scenario did?" - and until now it could not, because the
// artefact recorded neither.
//
// Two runs of the same flow, one against the default backing and one
// against `product_out_of_stock`, produced artefacts a reader could not
// tell apart, while every UI and API assertion in them had been measured
// against different data. `appVersion` and `buildMode` were the same
// story for the build: captured at the handshake, carried into
// `suite.json`, and absent from the run artefact beside it.
//
// Three additive keys, on the same terms as 1.1, 1.2 and 1.3 before
// them. Nothing that existed changes meaning, the suite schema does not
// move, and each key is omitted rather than filled in when the fact was
// not known - "no scenario was named" and "a scenario was named" are
// different facts, and a placeholder would erase the difference.
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

RunResult _run({
  String? fixture,
  String? appVersion,
  String? buildMode,
}) =>
    RunResult(
      flowName: 'checkout',
      appId: 'com.example.shop',
      device: 'pixel-7',
      startedAt: DateTime.utc(2026, 9, 18),
      duration: const Duration(seconds: 12),
      steps: const [
        StepOutcome(
          description: 'tap "cart.checkout"',
          kind: StepKind.tap,
          status: StepStatus.ok,
          durationMs: 40,
        ),
      ],
      screens: const [],
      fixture: fixture,
      appVersion: appVersion,
      buildMode: buildMode,
    );

/// A run recorded the way `FlowExecutor` records one that named a
/// scenario and read the build from the handshake.
RunResult _measured() => _run(
      fixture: 'product_out_of_stock',
      appVersion: '1.0.6',
      buildMode: 'debug',
    );

void main() {
  group('the version', () {
    // `fixture`, `appVersion` and `buildMode` arrived at 1.4; the
    // current version has moved on since, and every schema test pins
    // where it is now.
    test('the run schema is 1.6', () {
      expect(RunResult.schemaVersion, '1.6');
      expect(_run().toJson()['resultSchemaVersion'], '1.6');
    });

    test('the suite schema does not move', () {
      // Nothing about a suite changed. `suite.json` already carried the
      // build, and it says nothing new about a scenario.
      expect(SuiteResult.schemaVersion, '1.1');
    });
  });

  group('a run that named a scenario says so', () {
    test('the fixture is serialised', () {
      expect(_measured().toJson()['fixture'], 'product_out_of_stock');
    });

    test('two runs of one flow against different scenarios differ', () {
      // The whole point of the key. Without it these two artefacts are
      // indistinguishable, and every comparison between them is unsound.
      final a = _run(fixture: 'product_out_of_stock').toJson();
      final b = _run(fixture: 'api_500').toJson();

      expect(a['fixture'], isNot(b['fixture']));
      expect(a['flow'], b['flow']);
    });
  });

  group('a run that named none claims none', () {
    test('the key is absent, not null and not invented', () {
      final json = _run().toJson();

      expect(json.containsKey('fixture'), isFalse);
      for (final invented in const ['unknown', 'default', 'none', 'null']) {
        expect(json.values, isNot(contains(invented)), reason: invented);
      }
    });

    test('absence is the same shape as every other optional key', () {
      // `detail` on a step and `apiChecks` on a run are both omitted
      // rather than nulled. This follows them.
      final json = _run().toJson();

      expect(json.containsKey('appVersion'), isFalse);
      expect(json.containsKey('buildMode'), isFalse);
    });
  });

  group('the build under test', () {
    test('appVersion is serialised', () {
      expect(_measured().toJson()['appVersion'], '1.0.6');
    });

    test('buildMode is serialised', () {
      expect(_measured().toJson()['buildMode'], 'debug');
    });

    test('a device that would not say is recorded as not having said', () {
      // `describe` returns an empty environment when the device cannot
      // be read, and never fails the run for it. The artefact records
      // less rather than recording something untrue.
      final json = _run(fixture: 'product_out_of_stock').toJson();

      expect(json['fixture'], 'product_out_of_stock');
      expect(json.containsKey('appVersion'), isFalse);
      expect(json.containsKey('buildMode'), isFalse);
    });

    test('one known and one unknown is possible', () {
      final json = _run(appVersion: '1.0.6').toJson();

      expect(json['appVersion'], '1.0.6');
      expect(json.containsKey('buildMode'), isFalse);
    });
  });

  group('nothing that existed changes', () {
    test('every 1.3 key is still there, meaning what it meant', () {
      final json = _measured().toJson();

      expect(json['flow'], 'checkout');
      expect(json['appId'], 'com.example.shop');
      expect(json['device'], 'pixel-7');
      expect(json['startedAt'], '2026-09-18T00:00:00.000Z');
      expect(json['durationMs'], 12000);
      expect(json['passed'], isTrue);
      expect(json['overall'], 'pass');
      expect(json['dimensions'], isNotNull);
      expect(json['steps'], isNotEmpty);
    });

    test('the step block is untouched', () {
      final step = ((_measured().toJson()['steps']! as List).single! as Map)
          .cast<String, Object?>();

      expect(
        step.keys.toSet(),
        {'description', 'kind', 'status', 'durationMs'},
      );
    });

    test('the verdict does not depend on the preconditions', () {
      // A precondition is a fact about the run, not evidence about the
      // application. Recording it must not be able to move a verdict.
      final with_ = _measured();
      final without = _run();

      expect(with_.overall, without.overall);
      expect(with_.passed, without.passed);
      expect(
        with_.dimensions[ValidationDimension.ui]!.status,
        without.dimensions[ValidationDimension.ui]!.status,
      );
    });

    test('only three keys were added', () {
      final added = _measured().toJson().keys.toSet()
        ..removeAll(_run().toJson().keys);

      expect(added, {'fixture', 'appVersion', 'buildMode'});
    });
  });

  group('attaching an analysis does not cost the preconditions', () {
    test('withAnalysis carries all three', () {
      // A copy that dropped them would mean asking a model for an
      // explanation silently changed what the artefact says it measured.
      final json = _measured()
          .withAnalysis(const AnalysisUnavailable('no provider'))
          .toJson();

      expect(json['fixture'], 'product_out_of_stock');
      expect(json['appVersion'], '1.0.6');
      expect(json['buildMode'], 'debug');
    });
  });

  group('a 1.3 artefact still renders', () {
    Map<String, Object?> legacy() => {
          'resultSchemaVersion': '1.3',
          'flow': 'checkout',
          'passed': true,
          'overall': 'pass',
          'steps': [
            {
              'description': 'tap "a"',
              'kind': 'tap',
              'status': 'ok',
              'durationMs': 12,
            },
          ],
          'screens': <Object?>[],
        };

    test('the page renders it, with no preconditions to show', () {
      final html = const HtmlReporter().render(legacy());

      expect(html, contains('checkout'));
      expect(html, contains('tap &quot;a&quot;'));
    });

    test('nothing is fabricated for the keys it does not carry', () {
      final html = const HtmlReporter().render(legacy());

      for (final invented in const ['unknown', 'product_out_of_stock']) {
        expect(html, isNot(contains(invented)), reason: invented);
      }
    });
  });

  group('one production path, and it records the effective values', () {
    // The wiring cannot be exercised without a device, so it is pinned
    // at the source. Two things matter and neither is visible from a
    // constructed `RunResult`:
    //
    //   * there is one place a run is built from a live execution, and
    //     it passes the preconditions it was handed;
    //   * the fixture it records is the *effective* one. `testsmith run`
    //     takes `--fixture` as an override of the flow's own
    //     `fixture:`, so a recorder that read `flow.fixture` would write
    //     down a scenario the run did not use.
    test('the executor records what it was handed, not what was declared',
        () {
      final executor = _source('flutter_testsmith_cli/lib/src/flow_executor.dart');

      expect(executor, contains('fixture: fixture'));
      expect(executor, contains('appVersion: appVersion'));
      expect(executor, contains('buildMode: buildMode'));
      expect(executor, isNot(contains('flow.fixture')));
    });

    test('the runner hands it the effective scenario and the handshake', () {
      final runner = _source('flutter_testsmith_cli/lib/src/flow_runner.dart');

      expect(runner, contains('fixture: fixture'));
      expect(runner, contains('appVersion: described.environment.appVersion'));
      expect(runner, contains('buildMode: described.environment.buildMode'));
    });

    test('the build is the same value the suite records', () {
      // `suite_runner` reads `environment.appVersion` / `.buildMode`
      // from the same `onDescribed` callback the runner fills from
      // `described.environment`. One source, two artefacts.
      final suite = _source('flutter_testsmith_cli/lib/src/suite_runner.dart');

      expect(suite, contains('environment.appVersion'));
      expect(suite, contains('environment.buildMode'));
    });

    test('no second fixture representation was introduced', () {
      // One field on `RunResult`, one on `FlowExecutor`, and the
      // parameter the execution interface already had.
      final result = _source('flutter_testsmith_engine/lib/src/reporting/run_result.dart');

      expect("'fixture'".allMatches(result).length, 1);
    });
  });

  group('the preconditions carry no secret', () {
    test('a fixture is an identifier, and the reports stay clean', () {
      // A scenario name is a file name in `mock_api/scenarios`, resolved
      // through `ScenarioLibrary` before a run is allowed to proceed. It
      // is a config key, never a value read out of the environment.
      const seeded = 'SEEDED_ACCESS_TOKEN_8a17fc';
      final run = _measured();
      final json = run.toJson().toString();
      final html = const HtmlReporter().render(run.toJson());
      final cli = const E2eSummary().render(run);

      for (final text in [json, html, cli]) {
        expect(text, isNot(contains(seeded)));
        for (final forbidden in const [
          'Authorization',
          'Cookie',
          'Bearer',
          'requestBody',
          'responseBody',
        ]) {
          expect(text, isNot(contains(forbidden)), reason: forbidden);
        }
      }
    });

    test('no environment variable value can arrive through these keys', () {
      // The three are a scenario name and two handshake strings. A
      // `SecretRef` renders as a reference wherever one appears, and
      // none of these is one - but if a value ever reached them, this
      // says so.
      final json = _run(
        fixture: 'product_out_of_stock',
        appVersion: '1.0.6',
        buildMode: 'debug',
      ).toJson();

      for (final key in const ['fixture', 'appVersion', 'buildMode']) {
        expect(json[key], isA<String>());
        expect('${json[key]}', isNot(contains('=')));
        expect('${json[key]}', isNot(contains('token')));
      }
    });
  });
}
