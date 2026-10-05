import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// What a suite's verdict is, given what its tests did.
///
/// Precedence is **ERROR > FAIL > PASS**, and SKIP outranks nothing.
///
/// ERROR above FAIL because the two say different things: a FAIL is a
/// defect somebody can act on, while an ERROR is the absence of an
/// answer. A suite that could not evaluate a required test does not know
/// whether it passes, and reporting that as a plain failure would claim
/// knowledge it does not have.
///
/// SKIP below everything because a skip is the easiest verdict to
/// produce by accident - a missing file, a stopped run, a typo in an id -
/// and a skip that could outrank a failure would be a suite that goes
/// green by not running.
final _profile = DeviceProfile.parse(
  'id: samsung-m127g\nmodel: SM-M127G\n',
  source: 'test',
);

/// Builds a result with the given verdict through whichever constructor
/// is allowed to produce it.
///
/// There is deliberately no constructor that takes a verdict directly:
/// PASS and FAIL are statements about the application, ERROR and SKIP are
/// statements about the run, and a single constructor taking either would
/// make the distinction a convention rather than a property of the type.
SuiteTestResult _test(
  String id,
  TestVerdict verdict, {
  bool required = true,
  String? reason,
}) =>
    switch (verdict) {
      TestVerdict.pass => SuiteTestResult.product(
          id: id,
          passed: true,
          required: required,
          duration: const Duration(seconds: 1),
        ),
      TestVerdict.fail => SuiteTestResult.product(
          id: id,
          passed: false,
          required: required,
          duration: const Duration(seconds: 1),
        ),
      TestVerdict.error => SuiteTestResult.environment(
          id: id,
          kind: EnvironmentKind.error,
          required: required,
          duration: const Duration(seconds: 1),
          reason: reason ?? 'the run could not answer the question',
        ),
      TestVerdict.skip => SuiteTestResult.skipped(
          id: id,
          required: required,
          reason: reason ?? 'not run',
        ),
    };

SuiteResult _suite(List<SuiteTestResult> tests) => SuiteResult(
      suiteName: 's',
      profile: _profile,
      startedAt: DateTime.utc(2026, 9, 13),
      duration: const Duration(seconds: 10),
      tests: tests,
    );

void main() {
  group('aggregate verdict', () {
    test('PASS when every required test passed', () {
      expect(
        _suite([_test('a', TestVerdict.pass), _test('b', TestVerdict.pass)])
            .verdict,
        SuiteVerdict.pass,
      );
    });

    test('FAIL when a required test failed', () {
      expect(
        _suite([_test('a', TestVerdict.pass), _test('b', TestVerdict.fail)])
            .verdict,
        SuiteVerdict.fail,
      );
    });

    test('ERROR when a required test could not be evaluated', () {
      expect(
        _suite([_test('a', TestVerdict.pass), _test('b', TestVerdict.error)])
            .verdict,
        SuiteVerdict.error,
      );
    });

    test('ERROR outranks FAIL', () {
      expect(
        _suite([_test('a', TestVerdict.fail), _test('b', TestVerdict.error)])
            .verdict,
        SuiteVerdict.error,
      );
    });

    test('SKIP when everything skipped was optional', () {
      expect(
        _suite([
          _test('a', TestVerdict.skip, required: false),
          _test('b', TestVerdict.skip, required: false),
        ]).verdict,
        SuiteVerdict.skip,
      );
    });

    test('PASS when an optional test failed', () {
      // Optional means the suite can pass without it. It is still
      // reported.
      expect(
        _suite([
          _test('a', TestVerdict.pass),
          _test('b', TestVerdict.fail, required: false),
        ]).verdict,
        SuiteVerdict.pass,
      );
    });
  });

  group('SKIP cannot launder a result', () {
    test('a FAIL is not hidden by skips around it', () {
      expect(
        _suite([
          _test('a', TestVerdict.skip, required: false),
          _test('b', TestVerdict.fail),
          _test('c', TestVerdict.skip, required: false),
        ]).verdict,
        SuiteVerdict.fail,
      );
    });

    test('an ERROR is not hidden by skips around it', () {
      expect(
        _suite([
          _test('a', TestVerdict.skip, required: false),
          _test('b', TestVerdict.error),
          _test('c', TestVerdict.skip, required: false),
        ]).verdict,
        SuiteVerdict.error,
      );
    });

    test('a required test that was skipped is an ERROR, not a pass', () {
      // Fail-fast leaves later tests unrun. A required test that did not
      // run has not been shown to pass, and the suite must not claim it
      // did.
      expect(
        _suite([
          _test('a', TestVerdict.fail),
          _test('b', TestVerdict.skip, reason: 'the suite stopped at "a"'),
        ]).verdict,
        SuiteVerdict.fail,
      );
    });

    test('skipping every required test is an ERROR', () {
      expect(
        _suite([_test('a', TestVerdict.skip, reason: 'not run')]).verdict,
        SuiteVerdict.error,
      );
    });
  });

  group('exit codes', () {
    test('are the CI contract', () {
      expect(_suite([_test('a', TestVerdict.pass)]).exitCode, 0);
      expect(_suite([_test('a', TestVerdict.fail)]).exitCode, 1);
      expect(_suite([_test('a', TestVerdict.error)]).exitCode, 2);
      expect(
        _suite([_test('a', TestVerdict.skip, required: false)]).exitCode,
        0,
      );
    });
  });

  group('the machine-readable report', () {
    test('names the suite, the profile and the verdict', () {
      final json = _suite([_test('a', TestVerdict.pass)]).toJson();

      expect(json['suite'], 's');
      expect(json['verdict'], 'pass');
      expect((json['deviceProfile']! as Map)['id'], 'samsung-m127g');
      expect(json['exitCode'], 0);
    });

    test('lists every test with its verdict, in declared order', () {
      final json = _suite([
        _test('login', TestVerdict.fail),
        _test('home', TestVerdict.pass),
      ]).toJson();

      final tests = (json['tests']! as List).cast<Map<String, Object?>>();
      expect(tests.map((t) => t['id']), ['login', 'home']);
      expect(tests.first['verdict'], 'fail');
    });

    test('carries the counts, so a reader need not tally them', () {
      final json = _suite([
        _test('a', TestVerdict.pass),
        _test('b', TestVerdict.fail),
        _test('c', TestVerdict.error),
        _test('d', TestVerdict.skip, required: false),
      ]).toJson();

      expect((json['counts']! as Map)['pass'], 1);
      expect((json['counts']! as Map)['fail'], 1);
      expect((json['counts']! as Map)['error'], 1);
      expect((json['counts']! as Map)['skip'], 1);
    });

    test('says why a test errored or was skipped', () {
      final json = _suite([
        _test('a', TestVerdict.error, reason: 'the app did not start'),
      ]).toJson();

      expect(
        (json['tests']! as List).first,
        containsPair('reason', 'the app did not start'),
      );
    });
  });

  group('secrets', () {
    test('a suite report carries no environment and no credentials', () {
      // The suite knows the Figma token, the AI key and whatever else is
      // in the environment, because the process it runs in does. None of
      // that is part of what it tested, and a report is a file people
      // commit and paste into tickets.
      //
      // Asserted as an allow-list of what a report may contain rather
      // than a deny-list of known secrets: a deny-list only ever catches
      // the secrets somebody remembered.
      final json = _suite([_test('a', TestVerdict.pass)]).toJson();

      expect(
        json.keys,
        unorderedEquals([
          'suiteSchemaVersion',
          'suite',
          'deviceProfile',
          'startedAt',
          'durationMs',
          'verdict',
          'exitCode',
          'counts',
          'tests',
        ]),
      );
    });

    test('a profile carries only what a baseline needs', () {
      final profile = DeviceProfile.parse('''
id: samsung-m127g
model: SM-M127G
os: Android 13
physical: {width: 720, height: 1600}
devicePixelRatio: 1.875
''', source: 'test');

      expect(
        profile.toJson().keys,
        unorderedEquals([
          'id',
          'model',
          'os',
          'physical',
          'devicePixelRatio',
          'orientation',
        ]),
      );
    });
  });

  group('the report carries no device identity it does not need', () {
    test('records the profile, never a serial', () {
      // A serial is the handset on one desk. It is not part of what the
      // suite tested, and putting it in a committed report puts a
      // machine identifier into a repository for no reason.
      final json = _suite([_test('a', TestVerdict.pass)]).toJson();

      String flatten(Object? node) => node.toString();
      expect(flatten(json), isNot(contains('RZ8T11QETWM')));
      expect((json['deviceProfile']! as Map).keys, isNot(contains('device')));
    });
  });

  // ── E-04: the PRODUCT / ENVIRONMENT axis ────────────────────────────
  //
  // "Did the application fail, or could we not test it?" is not
  // answerable from a verdict alone, and answering it wrongly sends the
  // report to the wrong person. The axis is enforced by the constructors
  // rather than by a convention, so the two invariants below are
  // properties of the type.
  group('classification', () {
    SuiteTestResult product(String id, {required bool passed}) =>
        SuiteTestResult.product(
          id: id,
          passed: passed,
          required: true,
          duration: const Duration(seconds: 1),
        );

    SuiteTestResult environment(String id, EnvironmentKind kind) =>
        SuiteTestResult.environment(
          id: id,
          kind: kind,
          required: true,
          duration: const Duration(seconds: 1),
          reason: 'the device was not ready',
        );

    test('a product result is PASS or FAIL, and nothing else', () {
      expect(product('a', passed: true).verdict, TestVerdict.pass);
      expect(product('a', passed: false).verdict, TestVerdict.fail);
      expect(
        product('a', passed: false).classification,
        ResultClassification.product,
      );
      expect(product('a', passed: false).environmentKind, isNull);
    });

    test('an environment result is always ERROR, whatever its kind', () {
      for (final kind in EnvironmentKind.values) {
        final result = environment('a', kind);
        expect(result.verdict, TestVerdict.error, reason: kind.name);
        expect(result.classification, ResultClassification.environment);
        expect(result.environmentKind, kind);
      }
    });

    test('an environment result can never be a product FAIL', () {
      final results = [
        for (final kind in EnvironmentKind.values) environment(kind.name, kind),
      ];

      expect(results.map((r) => r.verdict), everyElement(TestVerdict.error));
      expect(
        results.where((r) => r.verdict == TestVerdict.fail),
        isEmpty,
      );
      expect(
        results.where((r) => r.classification == ResultClassification.product),
        isEmpty,
      );
    });

    test('a product FAIL beside an environment error stays a FAIL, and the '
        'suite reports the absence of an answer', () {
      final suite = _suite([
        product('login', passed: false),
        environment('orders', EnvironmentKind.precondition),
      ]);

      expect(suite.verdict, SuiteVerdict.error);
      expect(suite.exitCode, 2);
      // The failure is still in the report. An environment problem does
      // not absolve a screen that was measured and found wrong.
      expect(
        suite.tests.firstWhere((t) => t.id == 'login').verdict,
        TestVerdict.fail,
      );
      expect(suite.countOf(TestVerdict.fail), 1);
    });

    test('a suite of environment results reports no failures at all', () {
      final suite = _suite([
        environment('home', EnvironmentKind.blocked),
        environment('orders', EnvironmentKind.blocked),
      ]);

      expect(suite.countOf(TestVerdict.fail), 0);
      expect(suite.countOf(TestVerdict.error), 2);
      expect(suite.exitCode, 2);
    });

    test('a skipped test is an environment fact, not a product one', () {
      const skipped = SuiteTestResult.skipped(
        id: 'journey',
        required: false,
        reason: 'not run: the suite stopped at the first failure',
      );

      expect(skipped.verdict, TestVerdict.skip);
      expect(skipped.classification, ResultClassification.environment);
      expect(skipped.environmentKind, isNull);
    });

    test('records its classification in JSON', () {
      final json = _suite([product('home', passed: true)]).toJson();
      final test = (json['tests']! as List).single! as Map<String, Object?>;

      expect(test['classification'], 'product');
      expect(test.containsKey('environment'), isFalse);
    });

    test('records the environment kind in JSON when there is one', () {
      final json =
          _suite([environment('home', EnvironmentKind.precondition)]).toJson();
      final test = (json['tests']! as List).single! as Map<String, Object?>;

      expect(test['classification'], 'environment');
      expect(test['environment'], 'precondition');
    });
  });

  group('preflight in the suite result', () {
    test('is carried into the JSON when there is one', () {
      final suite = SuiteResult(
        suiteName: 's',
        profile: _profile,
        startedAt: DateTime.utc(2026),
        duration: Duration.zero,
        preflight: const PreflightReport([
          PreflightCheck.blocked(
            'network interface',
            klass: PrerequisiteClass.devicePrerequisite,
            detail: 'NETWORK_INTERFACE_REQUIRED',
            remedy: 'Turn on Wi-Fi.',
          ),
        ]),
        tests: [
          SuiteTestResult.environment(
            id: 'home',
            kind: EnvironmentKind.blocked,
            required: true,
            duration: Duration.zero,
            reason: 'preflight blocked: network interface',
          ),
        ],
      );

      final json = suite.toJson();
      expect((json['preflight']! as Map)['blocked'], isTrue);
      expect(suite.verdict, SuiteVerdict.error);
      expect(json['exitCode'], 2);
    });

    test('is absent from the JSON when no preflight ran', () {
      final json = _suite([_test('a', TestVerdict.pass)]).toJson();
      expect(json.containsKey('preflight'), isFalse);
    });
  });

  group('cleanup', () {
    test('records every step it attempted', () {
      final suite = SuiteResult(
        suiteName: 's',
        profile: _profile,
        startedAt: DateTime.utc(2026),
        duration: Duration.zero,
        tests: [_test('a', TestVerdict.pass)],
        cleanup: const [
          CleanupStep('fixture server', succeeded: true),
          CleanupStep(
            'adb reverse',
            succeeded: false,
            detail: 'the device went away',
          ),
        ],
      );

      final cleanup = suite.toJson()['cleanup']! as List<Object?>;
      expect(cleanup, hasLength(2));
      expect((cleanup.first! as Map)['succeeded'], isTrue);
      expect((cleanup.last! as Map)['detail'], 'the device went away');
    });

    test('is absent from the JSON when nothing was torn down', () {
      final json = _suite([_test('a', TestVerdict.pass)]).toJson();
      expect(json.containsKey('cleanup'), isFalse);
    });
  });
}
