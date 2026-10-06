// A suite said "error" and could not say about what.
//
// The audit corrected the premise here, and it is worth recording:
// `checks` already carried `failures`, `errors` **and** `skips`, each
// naming its screen, validator and message. So an ERROR was not
// invisible - its message was there.
//
// Two facts were genuinely absent:
//
//   * a screen that PASSED appears in none of those three lists, so
//     "screen A passed, screen B could not be checked" could only be
//     inferred from absence - the re-derive-it-yourself problem this
//     architecture has been removing level by level;
//   * the dimension verdicts were not serialised at all, so "the API
//     answered correctly and the UI could not be read" was unavailable.
//     `SuiteTestResult.dimensions` existed as a getter and went nowhere.
//
// Both are now carried, from the canonical sources - `ScreenResult.status`
// and `RunResult.dimensions` - and nothing is recomputed here. The suite
// summarises the run; it does not replace it, and `output` still points
// at the full artefact.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

ValidationResult _r(ValidationStatus status, ValidationDimension dimension) =>
    switch (status) {
      ValidationStatus.pass => ValidationResult.pass(
          validatorId: 'ui-presence', message: 'ok', dimension: dimension),
      ValidationStatus.fail => ValidationResult.fail(
          validatorId: 'api-to-ui',
          message: 'the UI shows "Rs 2,599", the API returned 2999',
          dimension: dimension),
      ValidationStatus.error => ValidationResult.error(
          validatorId: 'visual',
          message: 'cannot photograph deterministically: 1 unexpected '
              'animation running',
          dimension: dimension),
      ValidationStatus.skip => ValidationResult.skip(
          validatorId: 'figma',
          message: 'no design is configured',
          dimension: dimension),
    };

ScreenResult _screen(String id, List<ValidationResult> results) =>
    ScreenResult(screenId: id, report: ValidationReport(results));

RunResult _run(
  List<ScreenResult> screens, {
  List<ApiExpectationOutcome> apiChecks = const [],
}) =>
    RunResult(
      flowName: 'f',
      appId: 'com.example.app',
      device: 'fake',
      startedAt: DateTime.utc(2026, 9, 18),
      duration: Duration.zero,
      steps: const [
        StepOutcome(description: 'launch', kind: StepKind.launchApp, status: StepStatus.ok, durationMs: 0),
      ],
      apiChecks: apiChecks,
      screens: screens,
    );

SuiteTestResult _product(RunResult run) => SuiteTestResult.product(
      id: 't',
      passed: run.passed,
      required: true,
      duration: Duration.zero,
      run: run,
      outputDirectory: 't',
    );

SuiteTestResult _environment(RunResult run, String reason) =>
    SuiteTestResult.environment(
      id: 't',
      kind: EnvironmentKind.error,
      required: true,
      duration: Duration.zero,
      reason: reason,
      run: run,
      outputDirectory: 't',
    );

List<Object?> _screens(SuiteTestResult test) =>
    (test.toJson()['screens'] as List?) ?? const [];

Map<String, Object?> _dimensions(SuiteTestResult test) =>
    ((test.toJson()['dimensions'] as Map?) ?? const {})
        .cast<String, Object?>();

String _statusOf(SuiteTestResult test, String dimension) =>
    '${(_dimensions(test)[dimension]! as Map)['status']}';

String _source(String underPackages) {
  for (final candidate in ['packages/$underPackages', '../$underPackages']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $underPackages');
}

void main() {
  group('what the suite already said, it still says', () {
    test('a passing test keeps its shape', () {
      final json = _product(
        _run([_screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)])]),
      ).toJson();

      expect(json['verdict'], TestVerdict.pass.wire);
      expect(json['classification'], ResultClassification.product.wire);
      expect(json['output'], 't');
      expect((json['checks']! as Map)['steps'], 1);
    });

    test('a product failure keeps its failure list', () {
      final json = _product(
        _run([_screen('/a', [_r(ValidationStatus.fail, ValidationDimension.ui)])]),
      ).toJson();
      final failures = (json['checks']! as Map)['failures']! as List;

      expect(json['verdict'], TestVerdict.fail.wire);
      expect(failures, hasLength(1));
      expect((failures.single! as Map)['screen'], '/a');
    });

    test('an environment error keeps its classification and reason', () {
      final json = _environment(
        _run([_screen('/a', [_r(ValidationStatus.error, ValidationDimension.visual)])]),
        '/a: cannot photograph deterministically',
      ).toJson();

      expect(json['verdict'], TestVerdict.error.wire);
      expect(json['classification'], ResultClassification.environment.wire);
      expect(json['environment'], EnvironmentKind.error.wire);
      expect(json['reason'], contains('/a'));
    });

    test('the existing error and skip lists are still there', () {
      // The audit found these already present. Pinned so the addition
      // below cannot quietly replace them.
      final json = _environment(
        _run([
          _screen('/a', [
            _r(ValidationStatus.error, ValidationDimension.visual),
            _r(ValidationStatus.skip, ValidationDimension.figma),
          ]),
        ]),
        'r',
      ).toJson();
      final checks = (json['checks']! as Map).cast<String, Object?>();

      expect(checks['errors'], hasLength(1));
      expect(checks['skips'], hasLength(1));
    });
  });

  group('a screen carries its own canonical status', () {
    test('a passing screen is present, not merely absent from a list', () {
      final test = _product(
        _run([_screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)])]),
      );

      expect(_screens(test), hasLength(1));
      expect((_screens(test).single! as Map)['screenId'], '/a');
      expect(
        (_screens(test).single! as Map)['status'],
        ValidationStatus.pass.wire,
      );
    });

    test('the status is the one the screen itself reports', () {
      final run = _run([
        _screen('/a', [_r(ValidationStatus.error, ValidationDimension.visual)]),
      ]);
      final test = _environment(run, 'r');

      expect(
        (_screens(test).single! as Map)['status'],
        run.screens.single.status.wire,
      );
    });

    test('every status uses the existing wire spelling', () {
      for (final status in ValidationStatus.values) {
        final run = _run([_screen('/a', [_r(status, ValidationDimension.ui)])]);
        expect(
          (_screens(_product(run)).single! as Map)['status'],
          status.wire,
        );
      }
    });
  });

  group('the motivating case: API passed, the UI could not be read', () {
    SuiteTestResult subject() => _environment(
          _run(
            [
              _screen('/a', [
                _r(ValidationStatus.pass, ValidationDimension.api),
                _r(ValidationStatus.error, ValidationDimension.ui),
                _r(ValidationStatus.skip, ValidationDimension.figma),
                _r(ValidationStatus.skip, ValidationDimension.visual),
              ]),
            ],
          ),
          '/a: the tree could not be read',
        );

    test('the test is an environment error', () {
      expect(subject().verdict, TestVerdict.error);
      expect(subject().classification, ResultClassification.environment);
    });

    test('the API evidence survives as PASS', () {
      expect(_statusOf(subject(), 'api'), ValidationStatus.pass.wire);
    });

    test('the UI is ERROR, and not FAIL', () {
      expect(_statusOf(subject(), 'ui'), ValidationStatus.error.wire);
      expect(_statusOf(subject(), 'ui'), isNot(ValidationStatus.fail.wire));
    });

    test('the unchecked dimensions stay SKIP', () {
      expect(_statusOf(subject(), 'figma'), ValidationStatus.skip.wire);
      expect(_statusOf(subject(), 'visual'), ValidationStatus.skip.wire);
    });

    test('the detail says what could not be observed', () {
      final errors =
          (subject().toJson()['checks']! as Map)['errors']! as List;

      expect(errors, hasLength(1));
      expect((errors.single! as Map)['message'], contains('cannot photograph'));
    });
  });

  group('a measured contradiction stays distinguishable from it', () {
    test('API PASS with a UI FAIL is a product failure', () {
      final test = _product(
        _run([
          _screen('/a', [
            _r(ValidationStatus.pass, ValidationDimension.api),
            _r(ValidationStatus.fail, ValidationDimension.ui),
          ]),
        ]),
      );

      expect(test.verdict, TestVerdict.fail);
      expect(test.classification, ResultClassification.product);
      expect(_statusOf(test, 'api'), ValidationStatus.pass.wire);
      expect(_statusOf(test, 'ui'), ValidationStatus.fail.wire);
    });

    test('the two cases differ in the file, not only in the verdict', () {
      final failing = _product(
        _run([
          _screen('/a', [_r(ValidationStatus.fail, ValidationDimension.ui)]),
        ]),
      ).toJson();
      final erroring = _environment(
        _run([
          _screen('/a', [_r(ValidationStatus.error, ValidationDimension.ui)]),
        ]),
        'r',
      ).toJson();

      expect(
        (failing['screens']! as List).single,
        isNot((erroring['screens']! as List).single),
      );
    });
  });

  group('several screens keep their own answers', () {
    SuiteTestResult mixed() => _environment(
          _run([
            _screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)]),
            _screen('/b', [_r(ValidationStatus.error, ValidationDimension.visual)]),
            _screen('/c', [_r(ValidationStatus.fail, ValidationDimension.ui)]),
          ]),
          '/b: could not be photographed',
        );

    test('all three statuses are preserved', () {
      final byId = {
        for (final raw in _screens(mixed()))
          (raw! as Map)['screenId']: (raw as Map)['status'],
      };

      expect(byId['/a'], ValidationStatus.pass.wire);
      expect(byId['/b'], ValidationStatus.error.wire);
      expect(byId['/c'], ValidationStatus.fail.wire);
    });

    test('the test verdict is the existing aggregate, unchanged', () {
      expect(mixed().verdict, TestVerdict.error);
    });

    test('the summary does not rewrite the individual evidence', () {
      // A verdict of ERROR at the top must not turn the failing screen
      // into an error, nor the passing one into anything else.
      expect(_screens(mixed()), hasLength(3));
    });
  });

  group('the suite artefact stays a summary', () {
    test('it points at the full run rather than copying it', () {
      final json = _product(
        _run([_screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)])]),
      ).toJson();

      expect(json['output'], 't');
      // No step list, no per-result blocks, no exchanges: those live in
      // the run artefact the `output` path names.
      expect(json.containsKey('steps'), isFalse);
      expect((json['screens']! as List).single, isA<Map<String, Object?>>());
      expect(
        ((json['screens']! as List).single! as Map).keys.toSet(),
        {'screenId', 'status'},
      );
    });

    test('no request or response payload is introduced', () {
      final text = jsonEncode(
        _environment(
          _run([
            _screen('/a', [_r(ValidationStatus.error, ValidationDimension.ui)]),
          ]),
          'r',
        ).toJson(),
      );

      for (final forbidden in const [
        'body',
        'headers',
        'authorization',
        'cookie',
        'token',
      ]) {
        expect(text.toLowerCase(), isNot(contains(forbidden)));
      }
    });
  });

  group('the schema records the addition', () {
    test('the suite version moves to 1.1', () {
      // The repository's rule, demonstrated twice on the run contract:
      // keys were added, nothing existing changed meaning, and the
      // version says so. Suite and run are versioned separately - the
      // run is at 1.2 and that is not mirrored here.
      final suite = SuiteResult(
        suiteName: 's',
        profile: const DeviceProfile(id: 'p', model: 'm'),
        startedAt: DateTime.utc(2026, 9, 18),
        duration: Duration.zero,
        tests: const [],
      );

      expect(suite.toJson()['suiteSchemaVersion'], '1.1');
    });

    test('the run schema is untouched at 1.4', () {
      expect(
        _run(const []).toJson()['resultSchemaVersion'],
        '1.6',
      );
    });

    test('the new keys are exactly the two that were added', () {
      final json = _product(
        _run([_screen('/a', [_r(ValidationStatus.pass, ValidationDimension.ui)])]),
      ).toJson();

      expect(json.containsKey('screens'), isTrue);
      expect(json.containsKey('dimensions'), isTrue);
      // And every key that was there before is still there.
      expect(
        json.keys.toSet().containsAll({
          'id',
          'verdict',
          'classification',
          'required',
          'durationMs',
          'output',
          'checks',
        }),
        isTrue,
      );
    });

    test('a test that never ran carries neither', () {
      // Nothing was observed, so there is nothing to summarise - and an
      // empty block would read as evidence.
      final json = const SuiteTestResult.skipped(
        id: 't',
        required: true,
        reason: 'the suite stopped first',
      ).toJson();

      expect(json.containsKey('screens'), isFalse);
      expect(json.containsKey('dimensions'), isFalse);
    });
  });

  group('nothing recomputes what the run already decided', () {
    test('the suite serialiser reads the canonical screen status', () {
      final source = _source('flutter_testsmith/lib/src/engine/reporting/suite_result.dart');

      expect(source, contains('screen.status.wire'));
      // Not re-derived from the report's own internals.
      expect(source, isNot(contains('aggregateStatus(')));
    });

    test('the suite CLI still tells ERROR from FAIL', () {
      final source = _source('flutter_testsmith/lib/src/cli/commands/suite_command.dart');

      expect(source, contains("TestVerdict.error => output.yellow('ERROR')"));
      expect(source, contains("TestVerdict.fail => output.red('FAIL "));
    });
  });
}
