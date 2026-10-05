import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/flow_runner.dart';
import 'package:flutter_testsmith_cli/src/suite_runner.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Suite orchestration: ordering, lifecycle, fail-fast, aggregation.
///
/// Runs against a fake execution and a fake device, deliberately. None
/// of this is about a screen being right - it is about whether the
/// runner does what the suite says, in the order it says it, and reports
/// the result honestly. Tying that to a physical handset would mean it
/// could only be checked by someone holding one.
class FakeExecution implements FlowExecution {
  FakeExecution(this.outcomes);

  /// Test id (taken from the flow name) to whether it passes, or an
  /// error to throw.
  final Map<String, Object> outcomes;

  final List<String> executed = <String>[];
  final List<String?> fixtures = <String?>[];

  /// The route the application was on when the flow finished, or null
  /// when it reached none. What the suite reads to tell "this screen is
  /// wrong" apart from "the device was never ready to be asked".
  String? lastScreen;

  @override
  Future<RunResult> execute({
    required TestFlow flow,
    required Directory outputDirectory,
    String? fixture,
    void Function(BaselineEnvironment environment, DeviceFacts facts)?
        onDescribed,
    void Function(List<String> screenHistory)? onScreensObserved,
  }) async {
    executed.add(flow.name);
    fixtures.add(fixture);

    onDescribed?.call(
      const BaselineEnvironment(appVersion: '1.0.6', buildMode: 'debug'),
      const DeviceFacts(model: 'SM-M127G'),
    );
    onScreensObserved?.call(lastScreen == null ? const [] : [lastScreen!]);

    final outcome = outcomes[flow.name] ?? true;
    if (outcome is Exception) throw outcome;
    // A whole result, for a test that needs a shape `true`/`false`
    // cannot express - an observation failure, for instance.
    if (outcome is RunResult) return outcome;

    return RunResult(
      flowName: flow.name,
      appId: flow.appId,
      device: 'fake',
      startedAt: DateTime.utc(2026),
      duration: Duration.zero,
      steps: [
        StepOutcome(
          description: 'launch the app',
          kind: StepKind.launchApp,
          status: outcome == true ? StepStatus.ok : StepStatus.failed,
          durationMs: 0,
        ),
      ],
      screens: const [],
    );
  }
}

/// Records the lifecycle calls a suite makes, and nothing else.
class FakeDevice implements DeviceController {
  final List<String> calls = <String>[];

  @override
  Future<void> clearAppState(String appId) async {
    calls.add('clear $appId');
  }

  /// Whether `pm grant` should fail, as it does for a permission the
  /// application never declared.
  bool failGrants = false;

  @override
  Future<void> grantPermission(String appId, String permission) async {
    if (failGrants) throw StateError('not a declared permission');
    calls.add('grant $appId $permission');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('the suite must not touch the device otherwise');
}

late Directory _root;

/// Writes a flow file whose `flow:` name is [id], so the fake can tell
/// which one it was handed.
void _flow(String id, {String? fixture}) {
  File('${_root.path}/$id.yaml').writeAsStringSync('''
appId: com.example.app
flow: $id
${fixture == null ? '' : 'fixture: $fixture'}
steps:
  - launchApp
''');
}

Future<SuiteResult> _run(
  String suiteYaml, {
  Map<String, Object> outcomes = const {},
  FakeDevice? device,
  FakeExecution? execution,
  PreflightReport? preflight,
  Map<String, Future<void> Function()> teardown = const {},
}) async {
  final suite = SuiteFile.parse(suiteYaml, source: 'suite.yaml');
  return SuiteRunner(
    suite: suite,
    projectDirectory: _root,
    profile: DeviceProfile.parse('id: p\nmodel: SM-M127G\n', source: 'p'),
    device: device ?? FakeDevice(),
    execution: execution ?? FakeExecution(outcomes),
    outputDirectory: Directory('${_root.path}/out'),
    preflight: preflight,
    teardown: teardown,
    log: (_) {},
  ).run();
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('suite_runner');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('ordering', () {
    test('runs the tests in the order the suite declares', () async {
      _flow('a');
      _flow('b');
      _flow('c');
      final execution = FakeExecution(const {});

      await _run('''
suite: s
device: {profile: p}
tests:
  - {id: c, flow: c.yaml}
  - {id: a, flow: a.yaml}
  - {id: b, flow: b.yaml}
''', execution: execution);

      expect(execution.executed, ['c', 'a', 'b']);
    });

    test('reports results in the same order', () async {
      _flow('a');
      _flow('b');

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: b, flow: b.yaml}
  - {id: a, flow: a.yaml}
''');

      expect(result.tests.map((t) => t.id), ['b', 'a']);
    });
  });

  group('lifecycle', () {
    test('does nothing to the device unless the suite says so', () async {
      // The default has to be "leave it alone". A suite that cleared
      // state between every test would spend its life re-signing-in,
      // and each test's real precondition would become invisible.
      _flow('a');
      final device = FakeDevice();

      await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', device: device);

      expect(device.calls, isEmpty);
    });

    test('clears state and grants permissions where declared', () async {
      _flow('login');
      _flow('home');
      final device = FakeDevice();

      await _run('''
suite: s
device: {profile: p}
tests:
  - id: login
    flow: login.yaml
    reset: clearState
    grant: [android.permission.POST_NOTIFICATIONS]
  - {id: home, flow: home.yaml}
''', device: device);

      expect(device.calls, [
        'clear com.example.app',
        'grant com.example.app android.permission.POST_NOTIFICATIONS',
      ]);
    });
  });

  group('fail-fast', () {
    test('stops after the first failure and skips the rest', () async {
      _flow('a');
      _flow('b');
      _flow('c');
      final execution = FakeExecution(const {'b': false});

      final result = await _run('''
suite: s
device: {profile: p}
onFailure: stop
tests:
  - {id: a, flow: a.yaml}
  - {id: b, flow: b.yaml}
  - {id: c, flow: c.yaml}
''', execution: execution);

      expect(execution.executed, ['a', 'b']);
      expect(
        result.tests.map((t) => t.verdict),
        [TestVerdict.pass, TestVerdict.fail, TestVerdict.skip],
      );
      expect(result.tests.last.reason, contains('stopped'));
    });

    test('a skip from fail-fast cannot make the suite pass', () async {
      // The skipped test is required, and it did not run. The suite
      // already holds a FAIL, and nothing about skipping the rest makes
      // that better.
      _flow('a');
      _flow('b');

      final result = await _run('''
suite: s
device: {profile: p}
onFailure: stop
tests:
  - {id: a, flow: a.yaml}
  - {id: b, flow: b.yaml}
''', outcomes: const {'a': false});

      expect(result.verdict, SuiteVerdict.fail);
      expect(result.exitCode, 1);
    });
  });

  group('continue on failure', () {
    test('runs every test even after one fails', () async {
      // The default, because a suite exists to say everything that is
      // wrong. Stopping at the first failure hides the rest behind it.
      _flow('a');
      _flow('b');
      _flow('c');
      final execution = FakeExecution(const {'a': false});

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
  - {id: b, flow: b.yaml}
  - {id: c, flow: c.yaml}
''', execution: execution);

      expect(execution.executed, ['a', 'b', 'c']);
      expect(result.verdict, SuiteVerdict.fail);
    });
  });

  group('errors', () {
    test('a flow that would not run is an ERROR, not a FAIL', () async {
      // The application not starting is not the screen being wrong.
      _flow('a');

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': Exception('the app did not start')});

      expect(result.tests.single.verdict, TestVerdict.error);
      expect(result.tests.single.reason, contains('did not start'));
      expect(result.exitCode, 2);
    });

    test('a device that is not the profile is an ERROR', () async {
      _flow('a');

      final suite = SuiteFile.parse('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', source: 'suite.yaml');

      final result = await SuiteRunner(
        suite: suite,
        projectDirectory: _root,
        // The profile says one handset; the fake reports another.
        profile: DeviceProfile.parse('id: p\nmodel: Pixel 7\n', source: 'p'),
        device: FakeDevice(),
        execution: FakeExecution(const {}),
        outputDirectory: Directory('${_root.path}/out'),
        log: (_) {},
      ).run();

      expect(result.tests.single.verdict, TestVerdict.error);
      expect(result.tests.single.reason, contains('Pixel 7'));
    });

    test('a flow naming an API state with no server is an ERROR', () async {
      _flow('a', fixture: 'populated');

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''');

      expect(result.tests.single.verdict, TestVerdict.error);
      expect(result.tests.single.reason, contains('populated'));
    });
  });

  group('per-test reports', () {
    test('writes each test its own result.json and report.html', () async {
      // The suite result names an `output` directory per test and the
      // HTML links to it. Recording a path to a report nobody wrote is
      // worse than recording nothing: it looks like evidence.
      _flow('a');

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''');

      expect(
        File('${_root.path}/out/a/result.json').existsSync(),
        isTrue,
        reason: 'the suite records output "a" but wrote no result there',
      );
      expect(File('${_root.path}/out/a/report.html').existsSync(), isTrue);
      expect(result.tests.single.outputDirectory, 'a');
    });

    test('writes a report even for a test that failed', () async {
      _flow('a');

      await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: const {'a': false});

      expect(File('${_root.path}/out/a/result.json').existsSync(), isTrue);
    });

    test('writes nothing for a test that never ran', () async {
      // An errored test has no result to write. A directory holding an
      // empty report would read as "we looked and found nothing wrong".
      _flow('a');

      await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': Exception('the app did not start')});

      expect(File('${_root.path}/out/a/result.json').existsSync(), isFalse);
    });
  });

  group('the app identity', () {
    test('is recorded from what the run reported', () async {
      _flow('a');

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''');

      expect(result.appVersion, '1.0.6');
      expect(result.buildMode, 'debug');
    });
  });

  // ── E-04: environment, and the lifecycle around a test ──────────────
  group('suite setup', () {
    Future<List<String>> grant(String suiteYaml) async {
      final device = FakeDevice();
      await grantDeclaredPermissions(
        suite: SuiteFile.parse(suiteYaml, source: 'suite.yaml'),
        projectDirectory: _root,
        device: device,
        log: (_) {},
      );
      return device.calls;
    }

    test('grants the permissions the suite declares, in order, once', () async {
      _flow('a');
      _flow('b');

      final calls = await grant('''
suite: s
device:
  profile: p
  permissions:
    - android.permission.ACCESS_FINE_LOCATION
    - android.permission.ACCESS_COARSE_LOCATION
tests:
  - {id: a, flow: a.yaml}
  - {id: b, flow: b.yaml}
''');

      expect(calls, [
        'grant com.example.app android.permission.ACCESS_FINE_LOCATION',
        'grant com.example.app android.permission.ACCESS_COARSE_LOCATION',
      ]);
    });

    test('a suite declaring none touches the device at all', () async {
      // The default E-03 lifecycle: nothing happens to the device that
      // the suite did not ask for, because a runner that tidied up
      // between tests would make each test's real precondition invisible.
      _flow('a');

      final calls = await grant('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''');

      expect(calls, isEmpty);
    });

    test('reads the application id from the flow, not from the suite',
        () async {
      _flow('a');
      File('${_root.path}/a.yaml').writeAsStringSync('''
appId: com.other.app
flow: a
steps:
  - launchApp
''');

      final calls = await grant('''
suite: s
device:
  profile: p
  permissions: [android.permission.CAMERA]
tests:
  - {id: a, flow: a.yaml}
''');

      expect(calls.single, contains('com.other.app'));
    });

    test('a grant that fails is reported, not raised', () async {
      // A grant that did not work is a finding for preflight to make
      // against the device, with the real reason - not an exception from
      // here with a guess at one.
      _flow('a');
      final device = FakeDevice()..failGrants = true;
      final messages = <String>[];

      await grantDeclaredPermissions(
        suite: SuiteFile.parse('''
suite: s
device:
  profile: p
  permissions: [android.permission.CAMERA]
tests:
  - {id: a, flow: a.yaml}
''', source: 'suite.yaml'),
        projectDirectory: _root,
        device: device,
        log: messages.add,
      );

      expect(messages.single, contains('could not grant'));
    });

    test('the runner itself no longer grants anything', () async {
      // Setup moved ahead of preflight, so that a fresh device is not
      // refused over a state the very next step was about to establish.
      _flow('a');
      final device = FakeDevice();

      await _run('''
suite: s
device:
  profile: p
  permissions: [android.permission.CAMERA]
tests:
  - {id: a, flow: a.yaml}
''', device: device);

      expect(device.calls, isEmpty);
    });
  });

  group('preflight', () {
    const blocked = PreflightReport([
      PreflightCheck.blocked(
        'network interface',
        klass: PrerequisiteClass.devicePrerequisite,
        detail: 'NETWORK_INTERFACE_REQUIRED',
        remedy: 'Turn on Wi-Fi.',
      ),
    ]);

    test('a blocked preflight runs nothing at all', () async {
      _flow('a');
      _flow('b');
      final execution = FakeExecution(const {});
      final device = FakeDevice();

      await _run('''
suite: s
device:
  profile: p
  permissions: [android.permission.CAMERA]
tests:
  - {id: a, flow: a.yaml}
  - {id: b, flow: b.yaml}
''', execution: execution, device: device, preflight: blocked);

      expect(execution.executed, isEmpty);
      // Nothing is cleared, nothing is launched. A blocked environment is
      // one the runner has decided not to act in.
      expect(device.calls, isEmpty);
    });

    test('reports every test as an environment result, and none as a failure',
        () async {
      _flow('a');
      _flow('b');

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
  - {id: b, flow: b.yaml}
''', preflight: blocked);

      expect(result.tests, hasLength(2));
      expect(
        result.tests.map((t) => t.classification),
        everyElement(ResultClassification.environment),
      );
      expect(
        result.tests.map((t) => t.environmentKind),
        everyElement(EnvironmentKind.blocked),
      );
      expect(result.countOf(TestVerdict.fail), 0);
      expect(result.verdict, SuiteVerdict.error);
      expect(result.exitCode, 2);
      expect(result.tests.first.reason, contains('network interface'));
    });

    test('carries the report into the result', () async {
      _flow('a');

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', preflight: blocked);

      expect(result.preflight, same(blocked));
    });

    test('an unblocked preflight changes nothing', () async {
      _flow('a');
      const clear = PreflightReport([
        PreflightCheck.satisfied(
          'device',
          klass: PrerequisiteClass.devicePrerequisite,
          detail: 'SM-M127G',
        ),
      ]);

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', preflight: clear);

      expect(result.verdict, SuiteVerdict.pass);
      expect(result.tests.single.classification, ResultClassification.product);
    });
  });

  group('preconditions', () {
    const suiteYaml = '''
suite: s
device: {profile: p}
preconditions:
  authenticated:
    description: a session obtained through the real login flow
    unmetOn: [/login, /onboarding]
    remedy: Sign in on the device through the real application UI.
tests:
  - {id: home, flow: home.yaml, requires: [authenticated]}
''';

    test('an unmet precondition is PRECONDITION, not FAIL', () async {
      _flow('home');
      final execution = FakeExecution({'home': false})..lastScreen = '/login';

      final result = await _run(suiteYaml, execution: execution);

      final test = result.tests.single;
      expect(test.verdict, TestVerdict.error);
      expect(test.classification, ResultClassification.environment);
      expect(test.environmentKind, EnvironmentKind.precondition);
      expect(test.reason, contains('/login'));
      expect(test.reason, contains('Sign in'));
      expect(result.verdict, SuiteVerdict.error);
      expect(result.exitCode, 2);
      expect(result.countOf(TestVerdict.fail), 0);
    });

    test('an unmet precondition keeps what the run did establish', () async {
      // Reclassified, not discarded. The run happened and checked the
      // API before ending up somewhere the precondition rules out, and
      // a row saying only "not signed in" throws that away.
      _flow('home');
      final execution = FakeExecution({
        'home': RunResult(
          flowName: 'home',
          appId: 'com.example.app',
          device: 'fake',
          startedAt: DateTime.utc(2026),
          duration: Duration.zero,
          steps: const [
            StepOutcome(
              description: 'expect to be on "/home"',
              kind: StepKind.expectScreen,
              status: StepStatus.failed,
              durationMs: 0,
              detail: 'the application is on "/login"',
            ),
          ],
          screens: [
            ScreenResult(
              screenId: '/login',
              report: ValidationReport(const [
                ValidationResult.pass(
                  validatorId: 'api-to-ui',
                  message: 'the session endpoint answered 401 as declared',
                  dimension: ValidationDimension.api,
                ),
              ]),
            ),
          ],
        ),
      })
        ..lastScreen = '/login';

      final result = await _run(suiteYaml, execution: execution);
      final json = result.tests.single.toJson();

      // Still a precondition problem, said the same way as before.
      expect(result.tests.single.environmentKind,
          EnvironmentKind.precondition);
      expect(result.tests.single.verdict, TestVerdict.error);
      expect(result.exitCode, 2);

      // And the evidence survives alongside it.
      expect(
        (json['dimensions']! as Map)['api'],
        containsPair('status', 'pass'),
      );
      expect((json['screens']! as List).first,
          containsPair('screenId', '/login'));
    });

    test('a met precondition leaves a product FAIL exactly as it was',
        () async {
      _flow('home');
      final execution = FakeExecution({'home': false})..lastScreen = '/home';

      final result = await _run(suiteYaml, execution: execution);

      expect(result.tests.single.verdict, TestVerdict.fail);
      expect(result.tests.single.classification, ResultClassification.product);
      expect(result.exitCode, 1);
    });

    test('a passing test is never reclassified, whatever route it ended on',
        () async {
      // The safety property that makes this sound: reclassification only
      // ever moves a result *up* the precedence ladder, FAIL to ERROR. A
      // suite can never go greener by declaring a precondition.
      _flow('home');
      final execution = FakeExecution({'home': true})..lastScreen = '/login';

      final result = await _run(suiteYaml, execution: execution);

      expect(result.tests.single.verdict, TestVerdict.pass);
      expect(result.tests.single.classification, ResultClassification.product);
      expect(result.exitCode, 0);
    });

    test('a test declaring no precondition is never reclassified', () async {
      _flow('home');
      _flow('login');
      final execution = FakeExecution({'login': false})..lastScreen = '/login';

      final result = await _run('''
suite: s
device: {profile: p}
preconditions:
  authenticated: {unmetOn: [/login]}
tests:
  - {id: login, flow: login.yaml}
''', execution: execution);

      expect(result.tests.single.verdict, TestVerdict.fail);
      expect(result.tests.single.classification, ResultClassification.product);
    });

    test('a route the precondition does not name leaves a FAIL alone',
        () async {
      _flow('home');
      final execution = FakeExecution({'home': false})..lastScreen = '/orders';

      final result = await _run(suiteYaml, execution: execution);

      expect(result.tests.single.verdict, TestVerdict.fail);
    });

    test('a test that reached no route at all is not reclassified', () async {
      // Nothing was observed, so nothing is concluded. The failure keeps
      // whatever it already said.
      _flow('home');
      final execution = FakeExecution({'home': false})..lastScreen = null;

      final result = await _run(suiteYaml, execution: execution);

      expect(result.tests.single.verdict, TestVerdict.fail);
    });
  });

  group('cleanup', () {
    test('runs every declared teardown and records it', () async {
      _flow('a');
      final undone = <String>[];

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', teardown: {
        'fixture server': () async => undone.add('fixture server'),
      });

      expect(undone, ['fixture server']);
      expect(result.cleanup.single.name, 'fixture server');
      expect(result.cleanup.single.succeeded, isTrue);
    });

    test('runs teardown after a failing test too', () async {
      _flow('a');
      final undone = <String>[];

      await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': false}, teardown: {
        'fixture server': () async => undone.add('fixture server'),
      });

      expect(undone, ['fixture server']);
    });

    test('a teardown that fails is recorded, never raised', () async {
      // Teardown must not throw over whatever caused it. When a run fails
      // because the device vanished, every cleanup step fails too, and an
      // exception from one of those would replace the real cause.
      _flow('a');

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', teardown: {
        'fixture server': () async => throw StateError('already closed'),
      });

      final step = result.cleanup.single;
      expect(step.succeeded, isFalse);
      expect(step.detail, contains('already closed'));
      // And the suite's own verdict is untouched by a teardown problem.
      expect(result.verdict, SuiteVerdict.pass);
    });

    test('runs teardown even when preflight blocked the whole suite',
        () async {
      _flow('a');
      final undone = <String>[];

      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''',
          preflight: const PreflightReport([
            PreflightCheck.blocked(
              'device',
              klass: PrerequisiteClass.devicePrerequisite,
              detail: 'none attached',
              remedy: 'Attach one.',
            ),
          ]),
          teardown: {
            'fixture server': () async => undone.add('fixture server'),
          });

      expect(undone, ['fixture server']);
      expect(result.cleanup, hasLength(1));
    });
  });

  group('an observation failure is a statement about the run', () {
    // The suite layer has had this vocabulary since E-03/E-04:
    // `SuiteTestResult.environment` is ERROR and carries
    // `ResultClassification.environment`, and there is deliberately no
    // constructor that lets an environment problem report FAIL. What was
    // missing was the runner marking the run, so the suite could see it.
    RunResult observationFailed(String flow) => RunResult(
          flowName: flow,
          appId: 'com.example.app',
          device: 'fake',
          startedAt: DateTime.utc(2026),
          duration: Duration.zero,
          steps: const [
            StepOutcome(
              description: 'tap "cta"',
              kind: StepKind.tap,
              status: StepStatus.observationFailed,
              durationMs: 0,
              detail: 'the engine has lost its connection to the application',
            ),
          ],
          screens: const [],
        );

    /// A run that answered one question before it stopped being able to
    /// ask the next: the API was checked and held, then the UI could not
    /// be read.
    RunResult partiallyEstablished(String flow) => RunResult(
          flowName: flow,
          appId: 'com.example.app',
          device: 'fake',
          startedAt: DateTime.utc(2026),
          duration: Duration.zero,
          steps: const [
            StepOutcome(
              description: 'tap "cta"',
              kind: StepKind.tap,
              status: StepStatus.observationFailed,
              durationMs: 0,
              detail: 'the engine has lost its connection to the application',
            ),
          ],
          screens: [
            ScreenResult(
              screenId: '/a',
              report: ValidationReport(const [
                ValidationResult.pass(
                  validatorId: 'api-to-ui',
                  message: 'the price matches the response',
                  dimension: ValidationDimension.api,
                ),
                ValidationResult.error(
                  validatorId: 'ui-presence',
                  message: 'the UI tree could not be read',
                  dimension: ValidationDimension.ui,
                ),
              ]),
            ),
          ],
        );

    test('it is an ERROR, not a product FAIL', () async {
      _flow('a');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': observationFailed('a')});

      expect(result.tests.single.verdict, TestVerdict.error);
      expect(result.tests.single.verdict, isNot(TestVerdict.fail));
    });

    test('it is classified as being about the run, not the application',
        () async {
      _flow('a');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': observationFailed('a')});

      expect(
        result.tests.single.classification,
        ResultClassification.environment,
      );
    });

    test('it names the kind of environment problem', () async {
      _flow('a');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': observationFailed('a')});

      expect(result.tests.single.environmentKind, EnvironmentKind.error);
    });

    test('the cause survives into the suite result', () async {
      _flow('a');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': observationFailed('a')});

      expect(result.tests.single.reason, contains('lost its connection'));
    });

    test('the suite exits 2 - wrong with the run - not 1', () async {
      _flow('a');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': observationFailed('a')});

      expect(result.verdict.exitCode, 2);
    });

    test('an ordinary failure is still a product FAIL', () async {
      _flow('a');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: const {'a': false});

      expect(result.tests.single.verdict, TestVerdict.fail);
      expect(result.tests.single.classification, ResultClassification.product);
    });

    test('what the run did establish survives into the suite row', () async {
      // `SuiteTestResult.environment` has always taken an optional run,
      // and the `overall == error` branch has always passed one - with a
      // comment saying that an API which answered before the screenshot
      // could not be taken is evidence, and losing it would make the row
      // read as though nothing had happened. This branch did not pass
      // one, so the commonest environment failure was the one that lost
      // the most.
      _flow('a');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': partiallyEstablished('a')});

      final json = result.tests.single.toJson();

      // The API answered correctly before the connection went.
      expect(
        (json['dimensions']! as Map)['api'],
        containsPair('status', 'pass'),
      );
      // The UI is what could not be read.
      expect(
        (json['dimensions']! as Map)['ui'],
        containsPair('status', 'error'),
      );
      // And the screen it got to is named.
      expect(json['screens'], isNotEmpty);
      expect((json['screens']! as List).first, containsPair('screenId', '/a'));
    });

    test('carrying the run does not change what the row says it is',
        () async {
      _flow('a');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''', outcomes: {'a': partiallyEstablished('a')});

      final test = result.tests.single;

      expect(test.verdict, TestVerdict.error);
      expect(test.verdict, isNot(TestVerdict.fail));
      expect(test.classification, ResultClassification.environment);
      expect(test.environmentKind, EnvironmentKind.error);
      expect(result.exitCode, 2);
    });

    test('a mixed suite keeps each result as what it was', () async {
      // ERROR outranks FAIL, so the suite reports the run problem - and
      // every individual verdict is preserved rather than folded.
      _flow('a');
      _flow('b');
      _flow('c');
      final result = await _run('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
  - {id: b, flow: b.yaml}
  - {id: c, flow: c.yaml}
''', outcomes: {'a': true, 'b': false, 'c': observationFailed('c')});

      final byId = {for (final t in result.tests) t.id: t};
      expect(byId['a']!.verdict, TestVerdict.pass);
      expect(byId['b']!.verdict, TestVerdict.fail);
      expect(byId['c']!.verdict, TestVerdict.error);
      expect(result.verdict, SuiteVerdict.error);
    });
  });

  group('a validation that could not be established is not a product FAIL',
      () {
    // The last gap in the chain. `ValidationReport.passed` is false for a
    // screen that was contradicted and equally false for one whose check
    // could not be run, and the suite asked only that boolean:
    //
    //     SuiteTestResult.product(passed: result.passed)
    //
    // So a screen the tool could not photograph deterministically was
    // reported as evidence that the application was wrong, and the suite
    // exited 1 - sending someone to read a screen nobody had measured.
    //
    // `SuiteTestResult` has refused to let an environment problem report
    // FAIL since E-03: there is deliberately no constructor for it. Only
    // the caller had to choose the right one.
    RunResult runWith({
      required String flow,
      List<ValidationResult> results = const [],
      List<ApiExpectationOutcome> apiChecks = const [],
    }) =>
        RunResult(
          flowName: flow,
          appId: 'com.example.app',
          device: 'fake',
          startedAt: DateTime.utc(2026, 9, 18),
          duration: Duration.zero,
          steps: const [
            StepOutcome(
              description: 'launch the app',
              kind: StepKind.launchApp,
              status: StepStatus.ok,
              durationMs: 0,
            ),
          ],
          apiChecks: apiChecks,
          screens: [
            ScreenResult(
              screenId: '/product/details',
              report: ValidationReport(results),
            ),
          ],
        );

    const uiPass = ValidationResult.pass(
      validatorId: 'ui-presence',
      message: 'product.name is present',
      dimension: ValidationDimension.ui,
    );
    const uiFail = ValidationResult.fail(
      validatorId: 'api-to-ui',
      message: 'the UI shows "Rs 2,599", the API returned 2999',
      dimension: ValidationDimension.ui,
    );
    const visualError = ValidationResult.error(
      validatorId: 'visual',
      message: 'cannot photograph "/product/details" deterministically: '
          '1 unexpected animation running',
      dimension: ValidationDimension.visual,
    );
    const figmaSkip = ValidationResult.skip(
      validatorId: 'figma',
      message: 'no design is configured for this screen',
      dimension: ValidationDimension.figma,
    );
    const apiPass = ApiExpectationOutcome(
      endpoint: 'GET /api/product',
      status: 200,
      failures: [],
    );

    Future<SuiteResult> suiteOf(Map<String, Object> outcomes) async {
      for (final id in outcomes.keys) {
        _flow(id);
      }
      final entries =
          outcomes.keys.map((id) => '  - {id: $id, flow: $id.yaml}').join('\n');
      return _run('suite: s\ndevice: {profile: p}\ntests:\n$entries\n',
          outcomes: outcomes);
    }

    group('classification', () {
      test('a validation ERROR becomes an environment result', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass, visualError]),
        });

        expect(result.tests.single.classification,
            ResultClassification.environment);
        expect(result.tests.single.verdict, TestVerdict.error);
      });

      test('it is never reported as a product failure', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [visualError]),
        });

        expect(result.tests.single.classification,
            isNot(ResultClassification.product));
        expect(result.tests.single.verdict, isNot(TestVerdict.fail));
      });

      test('it uses the existing environment kind', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [visualError]),
        });

        expect(result.tests.single.environmentKind, EnvironmentKind.error);
      });

      test('the reason names the screen and what could not be done', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [visualError]),
        });

        expect(result.tests.single.reason, contains('/product/details'));
        expect(result.tests.single.reason, contains('cannot photograph'));
      });

      test('a genuine validation FAIL is still a product failure', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass, uiFail]),
        });

        expect(
            result.tests.single.classification, ResultClassification.product);
        expect(result.tests.single.verdict, TestVerdict.fail);
      });

      test('a passing run is still a product pass', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass]),
        });

        expect(
            result.tests.single.classification, ResultClassification.product);
        expect(result.tests.single.verdict, TestVerdict.pass);
      });

      test('an unchecked dimension is not reinterpreted as an error',
          () async {
        // SKIP is not ERROR. "Nothing was checked" must not start
        // reading as "something went wrong".
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass, figmaSkip]),
        });

        expect(result.tests.single.verdict, TestVerdict.pass);
        expect(
            result.tests.single.classification, ResultClassification.product);
      });
    });

    group('several dimensions at once', () {
      test('API PASS with a UI ERROR is an environment error', () async {
        final result = await suiteOf({
          'a': runWith(
            flow: 'a',
            apiChecks: const [apiPass],
            results: const [
              ValidationResult.error(
                validatorId: 'ui-presence',
                message: 'the tree could not be read',
                dimension: ValidationDimension.ui,
              ),
            ],
          ),
        });

        expect(result.tests.single.verdict, TestVerdict.error);
      });

      test('API PASS with a UI FAIL is still a product failure', () async {
        final result = await suiteOf({
          'a': runWith(
            flow: 'a',
            apiChecks: const [apiPass],
            results: const [uiFail],
          ),
        });

        expect(result.tests.single.verdict, TestVerdict.fail);
        expect(
            result.tests.single.classification, ResultClassification.product);
      });

      test('a satisfied API check is not turned into a failure', () async {
        final result = await suiteOf({
          'a': runWith(
            flow: 'a',
            apiChecks: const [apiPass],
            results: const [visualError, figmaSkip],
          ),
        });

        final dimensions = result.tests.single.dimensions!;
        expect(
            dimensions[ValidationDimension.api]!.status, ValidationStatus.pass);
      });

      test('unchecked dimensions stay SKIP beside an error', () async {
        final result = await suiteOf({
          'a': runWith(
            flow: 'a',
            apiChecks: const [apiPass],
            results: const [visualError, figmaSkip],
          ),
        });

        final dimensions = result.tests.single.dimensions!;
        expect(dimensions[ValidationDimension.figma]!.status,
            ValidationStatus.skip);
      });

      test('a FAIL and an ERROR together keep ERROR, and keep the FAIL '
          'visible', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiFail, visualError]),
        });

        // ERROR > FAIL, unchanged. The failure is still in the run this
        // result carries, so nothing is lost by classifying the test as
        // an environment error.
        expect(result.tests.single.verdict, TestVerdict.error);
        expect(result.tests.single.run!.screens.single.report.failCount, 1);
      });
    });

    group('mixed suites keep every result as what it was', () {
      test('all pass', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass]),
          'b': runWith(flow: 'b', results: const [uiPass]),
        });

        expect(result.verdict, SuiteVerdict.pass);
        expect(result.verdict.exitCode, 0);
      });

      test('pass and a product failure', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass]),
          'b': runWith(flow: 'b', results: const [uiFail]),
        });

        expect(result.verdict, SuiteVerdict.fail);
        expect(result.verdict.exitCode, 1);
      });

      test('pass and an observation error', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass]),
          'b': runWith(flow: 'b', results: const [visualError]),
        });

        expect(result.verdict, SuiteVerdict.error);
        expect(result.verdict.exitCode, 2);
      });

      test('a product failure and an observation error', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiFail]),
          'b': runWith(flow: 'b', results: const [visualError]),
        });

        final byId = {for (final t in result.tests) t.id: t};
        expect(byId['a']!.verdict, TestVerdict.fail);
        expect(byId['a']!.classification, ResultClassification.product);
        expect(byId['b']!.verdict, TestVerdict.error);
        expect(byId['b']!.classification, ResultClassification.environment);
        expect(result.verdict, SuiteVerdict.error);
      });

      test('pass, product failure and observation error together', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass]),
          'b': runWith(flow: 'b', results: const [uiFail]),
          'c': runWith(flow: 'c', results: const [visualError]),
        });

        final byId = {for (final t in result.tests) t.id: t};
        expect(byId['a']!.verdict, TestVerdict.pass);
        expect(byId['b']!.verdict, TestVerdict.fail);
        expect(byId['c']!.verdict, TestVerdict.error);
        expect(result.verdict, SuiteVerdict.error);
        expect(result.verdict.exitCode, 2);
      });

      test('a skip beside a pass', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass, figmaSkip]),
          'b': runWith(flow: 'b', results: const [uiPass]),
        });

        expect(result.verdict, SuiteVerdict.pass);
      });

      test('a skip beside an observation error', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiPass, figmaSkip]),
          'b': runWith(flow: 'b', results: const [visualError]),
        });

        final byId = {for (final t in result.tests) t.id: t};
        expect(byId['a']!.verdict, TestVerdict.pass);
        expect(byId['b']!.verdict, TestVerdict.error);
        expect(result.verdict, SuiteVerdict.error);
      });
    });

    group('the file a reader consumes says which it was', () {
      test('an environment error serialises as one', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [visualError]),
        });
        final json = result.tests.single.toJson();

        expect(json['verdict'], TestVerdict.error.wire);
        expect(json['classification'], ResultClassification.environment.wire);
        expect(json['environment'], EnvironmentKind.error.wire);
      });

      test('a product failure still serialises as one', () async {
        final result = await suiteOf({
          'a': runWith(flow: 'a', results: const [uiFail]),
        });
        final json = result.tests.single.toJson();

        expect(json['verdict'], TestVerdict.fail.wire);
        expect(json['classification'], ResultClassification.product.wire);
        expect(json.containsKey('environment'), isFalse);
      });
    });
  });
}
