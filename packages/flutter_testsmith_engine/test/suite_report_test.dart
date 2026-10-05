import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// The suite's human-readable report.
///
/// Rendered from the decoded JSON rather than from the objects, as the
/// run report already is: the page is then a pure function of the file
/// CI consumes, and the two cannot drift apart.
final _result = SuiteResult(
  suiteName: 'ecommerce-regression',
  profile: DeviceProfile.parse(
    'id: samsung-m127g\nmodel: SM-M127G\nos: Android 13\n',
    source: 'test',
  ),
  appVersion: '1.0.6',
  buildMode: 'debug',
  startedAt: DateTime.utc(2026, 9, 13, 12),
  duration: const Duration(minutes: 4, seconds: 12),
  tests: const [
    SuiteTestResult.product(
      id: 'login',
      passed: false,
      required: true,
      duration: Duration(seconds: 61),
    ),
    SuiteTestResult.product(
      id: 'home',
      passed: true,
      required: true,
      duration: Duration(seconds: 55),
    ),
    SuiteTestResult.skipped(
      id: 'journey',
      required: false,
      reason: 'not run: the suite stopped at the first failure',
    ),
  ],
);

void main() {
  test('names the suite, the profile and the verdict', () {
    final html = renderSuiteReport(_result);

    expect(html, contains('ecommerce-regression'));
    expect(html, contains('samsung-m127g'));
    expect(html, contains('SM-M127G'));
    expect(html, contains('FAIL'));
  });

  test('lists every test in declared order', () {
    final html = renderSuiteReport(_result);

    expect(
      html.indexOf('login'),
      lessThan(html.indexOf('home')),
    );
    expect(html, contains('journey'));
    expect(html, contains('the suite stopped at the first failure'));
  });

  test('records the app identity the run reported', () {
    expect(renderSuiteReport(_result), contains('1.0.6'));
  });

  test('carries no device serial', () {
    // A serial names the handset on one desk. It is no part of what the
    // suite tested, and a committed report should not carry a machine
    // identifier for nothing.
    expect(renderSuiteReport(_result), isNot(contains('RZ8T11QETWM')));
  });

  test('escapes what it renders', () {
    final html = renderSuiteReport(
      SuiteResult(
        suiteName: '<script>alert(1)</script>',
        profile: DeviceProfile.parse('id: p\n', source: 't'),
        startedAt: DateTime.utc(2026),
        duration: Duration.zero,
        tests: const [
          SuiteTestResult.product(
            id: 'a',
            passed: true,
            required: true,
            duration: Duration.zero,
          ),
        ],
      ),
    );

    expect(html, isNot(contains('<script>alert(1)</script>')));
    expect(html, contains('&lt;script&gt;'));
  });

  // ── E-04: the environment, in the page a person reads ───────────────
  group('preflight', () {
    SuiteResult blocked() => SuiteResult(
          suiteName: 'example-regression',
          profile: DeviceProfile.parse(
            'id: samsung-m127g\nmodel: SM-M127G\n',
            source: 't',
          ),
          startedAt: DateTime.utc(2026, 9, 13, 12),
          duration: Duration.zero,
          preflight: const PreflightReport([
            PreflightCheck.blocked(
              'permissions',
              klass: PrerequisiteClass.devicePrerequisite,
              detail: 'android.permission.ACCESS_FINE_LOCATION denied',
              remedy: 'adb shell pm grant com.example.app '
                  'android.permission.ACCESS_FINE_LOCATION',
            ),
            PreflightCheck.deferred(
              'authentication',
              klass: PrerequisiteClass.humanAction,
              detail: 'required by home, orders',
            ),
          ]),
          tests: const [
            SuiteTestResult.environment(
              id: 'home',
              kind: EnvironmentKind.blocked,
              required: true,
              duration: Duration.zero,
              reason: 'preflight blocked: permissions',
            ),
          ],
        );

    test('says what was blocked, and what would fix it', () {
      final html = renderSuiteReport(blocked());

      expect(html, contains('preflight'));
      expect(html, contains('ACCESS_FINE_LOCATION'));
      expect(html, contains('pm grant'));
    });

    test('records the class that owns each prerequisite', () {
      final html = renderSuiteReport(blocked());

      expect(html, contains('devicePrerequisite'));
      expect(html, contains('humanAction'));
    });

    test('shows a deferred check rather than hiding it', () {
      // "We could not know this yet" is a finding. Leaving it out would
      // let a reader believe everything had been checked.
      final html = renderSuiteReport(blocked());

      expect(html, contains('authentication'));
      expect(html, contains('deferred'));
    });

    test('a blocked suite reports no product failure anywhere on the page',
        () {
      final html = renderSuiteReport(blocked());

      expect(html, contains('ENVIRONMENT'));
      expect(html, contains('0 failed'));
      expect(html, contains('exit 2'));
    });

    test('is absent from a page for a run that had no preflight', () {
      final html = renderSuiteReport(_result);

      expect(html, isNot(contains('preflight')));
    });
  });

  group('product and environment', () {
    final mixed = SuiteResult(
      suiteName: 's',
      profile: DeviceProfile.parse('id: p\n', source: 't'),
      startedAt: DateTime.utc(2026),
      duration: Duration.zero,
      tests: const [
        SuiteTestResult.product(
          id: 'login',
          passed: false,
          required: true,
          duration: Duration(seconds: 53),
        ),
        SuiteTestResult.environment(
          id: 'home',
          kind: EnvironmentKind.precondition,
          required: true,
          duration: Duration(seconds: 41),
          reason: 'the precondition "authenticated" is not met',
        ),
      ],
    );

    test('distinguishes the two on the page', () {
      final html = renderSuiteReport(mixed);

      expect(html, contains('PRODUCT'));
      expect(html, contains('ENVIRONMENT'));
      expect(html, contains('precondition'));
    });

    test('the page agrees with the JSON about the verdict and the exit code',
        () {
      final json = mixed.toJson();
      final html = renderSuiteReport(mixed);

      expect(json['verdict'], 'error');
      expect(json['exitCode'], 2);
      expect(html, contains('exit 2'));
      expect(html, contains('ERROR'));
    });

    test('cleanup is shown when the suite undid anything', () {
      final html = renderSuiteReport(SuiteResult(
        suiteName: 's',
        profile: DeviceProfile.parse('id: p\n', source: 't'),
        startedAt: DateTime.utc(2026),
        duration: Duration.zero,
        cleanup: const [
          CleanupStep('fixture server', succeeded: true),
        ],
        tests: const [
          SuiteTestResult.product(
            id: 'a',
            passed: true,
            required: true,
            duration: Duration.zero,
          ),
        ],
      ));

      expect(html, contains('fixture server'));
    });
  });
}
