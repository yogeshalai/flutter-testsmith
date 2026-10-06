// Gathering the environment facts a suite depends on.
//
// Against a fake device and a scratch project, deliberately. Whether a
// run should stop before it starts is a decision, and a decision that can
// only be checked by somebody holding a handset is a decision nobody
// checks. The adb probes themselves are covered by the parsers in
// flutter_testsmith_engine; what is covered here is which questions get asked, when,
// and what the answers add up to.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/preflight_runner.dart';
import 'package:flutter_testsmith/src/cli/secrets/env_secret_resolver.dart';
import 'package:flutter_testsmith/engine.dart';

/// Every environment fact, under the test's control. No adb.
class FakeEnvironment implements DeviceEnvironment {
  FakeEnvironment({
    this.installed = true,
    this.permissions = const {},
    this.network = NetworkInterfaceState.up,
  });

  bool installed;
  Map<String, bool> permissions;
  NetworkInterfaceState network;

  final List<String> asked = <String>[];

  @override
  Future<bool> isInstalled(String appId) async {
    asked.add('isInstalled');
    return installed;
  }

  @override
  Future<Map<String, bool>> runtimePermissions(String appId) async {
    asked.add('runtimePermissions');
    return permissions;
  }

  @override
  Future<NetworkInterfaceState> networkInterface() async {
    asked.add('networkInterface');
    return network;
  }
}

late Directory _project;

void _write(String path, String contents) {
  File('${_project.path}/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

void _flow(String id, {String? fixture, String? photographs}) {
  _write('flows/$id.yaml', '''
appId: com.example.app
flow: $id
${fixture == null ? '' : 'fixture: $fixture'}
steps:
  - launchApp
${photographs == null ? '' : '''
  - expectScreen:
      id: $photographs
  - validateScreen:
      visual: true
'''}
''');
}

/// A flow that reaches [reaches] and compares it against its design.
///
/// `validateScreen` with nothing named runs every dimension, figma
/// included, which is the shape a project actually writes.
void _figmaFlow(String id, {String? reaches}) {
  _write('flows/$id.yaml', '''
appId: com.example.app
flow: $id
steps:
  - launchApp
${reaches == null ? '  - validateScreen' : '''
  - expectScreen:
      id: $reaches
  - validateScreen
'''}
''');
}

/// A mapping for [screen], optionally declaring a design.
void _mapping(String file, String screen, {String? nodeMapping}) {
  _write('mappings/$file.yaml', '''
screen: $screen
${nodeMapping == null ? '' : '''
figmaSource:
  url: "https://www.figma.com/design/ABC123/App?node-id=1-2"
  token: env:FIGMA_TOKEN
  mapping: $nodeMapping
'''}
mappings:
  - {target: t.a, source: response.a}
''');
}

void _scenario(String name) {
  _write(
    'mock_api/scenarios/$name.json',
    '{"name": "$name", "routes": {"GET /a": {"status": 200}}}',
  );
}

const _minimal = '''
suite: s
app: {target: lib/main_mytest.dart}
device: {profile: p}
tests:
  - {id: home, flow: flows/home.yaml}
''';

Future<PreflightReport> _run(
  String suiteYaml, {
  FakeEnvironment? environment,
  List<AdbDevice>? attached,
  String? requested,
  DeviceFacts facts = const DeviceFacts(model: 'SM-M127G'),
  bool portFree = true,
  bool flutterOnPath = true,
  Map<String, String> environmentVariables = const {'FIGMA_TOKEN': 'abc'},
}) {
  return PreflightRunner(
    suite: SuiteFile.parse(suiteYaml, source: 'suite.yaml'),
    projectDirectory: _project,
    profile: DeviceProfile.parse('id: p\nmodel: SM-M127G\n', source: 'p'),
    deviceEnvironment: environment ?? FakeEnvironment(),
    attachedDevices: attached ??
        const [AdbDevice(serial: 'S1', model: 'SM-M127G', state: 'device')],
    requestedSerial: requested,
    deviceFacts: facts,
    portProbe: (_) async => portFree,
    flutterOnPath: flutterOnPath,
    // The real resolver with its environment injected, rather than a
    // second implementation of presence: `EnvSecretResolver` already
    // takes one so tests need not mutate the process environment, which
    // Dart cannot do.
    secrets: EnvSecretResolver(environment: environmentVariables),
  ).run();
}

PreflightCheck _check(PreflightReport report, String name) =>
    report.checks.firstWhere(
      (check) => check.name == name,
      orElse: () => throw StateError(
        'no check named "$name"; there are '
        '${report.checks.map((c) => c.name).join(', ')}',
      ),
    );

void main() {
  setUp(() {
    _project = Directory.systemTemp.createTempSync('preflight');
    addTearDown(() => _project.deleteSync(recursive: true));
    _flow('home');
    _write('lib/main_mytest.dart', 'void main() {}');
  });

  test('a healthy environment blocks nothing', () async {
    final report = await _run(_minimal);

    expect(report.isBlocked, isFalse, reason: '${report.blockers}');
    expect(report.exitCode, 0);
  });

  group('device missing', () {
    test('blocks when nothing is attached', () async {
      final report = await _run(_minimal, attached: const []);

      expect(_check(report, 'device').outcome, PreflightOutcome.blocked);
      expect(report.isBlocked, isTrue);
      expect(report.exitCode, 2);
    });

    test('asks the device nothing when there is no device to ask', () async {
      // With nothing attached every answer would be "could not read",
      // which says nothing the device check has not already said - and
      // would arrive as three more blockers pointing at one cause.
      final environment = FakeEnvironment();

      await _run(_minimal, attached: const [], environment: environment);

      expect(environment.asked, isEmpty);
    });
  });

  test('profile mismatch blocks', () async {
    final report =
        await _run(_minimal, facts: const DeviceFacts(model: 'Pixel 7'));

    expect(_check(report, 'device profile').outcome, PreflightOutcome.blocked);
  });

  test('a device that reported nothing does not satisfy the profile',
      () async {
    // A handset adb lists but cannot be read from: `readDeviceFacts`
    // catches the failure and answers with an empty DeviceFacts. Every
    // comparison is skipped for want of an actual value, so the report
    // used to carry `[ok] device profile` having checked nothing at all.
    final report = await _run(_minimal, facts: const DeviceFacts());

    final check = _check(report, 'device profile');
    expect(check.outcome, PreflightOutcome.deferred);
    expect(check.outcome, isNot(PreflightOutcome.satisfied));
    // An admission, not a verdict: the exit code is unchanged.
    expect(check.isBlocking, isFalse);
  });

  group('figma prerequisites', () {
    const suiteYaml = '''
suite: s
app: {target: lib/main_mytest.dart}
device: {profile: p}
tests:
  - {id: home, flow: flows/home.yaml}
''';

    test('a reachable design with token and mapping present is satisfied',
        () async {
      _figmaFlow('home', reaches: '/home');
      _mapping('home', '/home', nodeMapping: 'figma/home.nodes.yaml');
      _write('figma/home.nodes.yaml', 'screen: /home\nnodes: {}\n');

      final report = await _run(suiteYaml);

      expect(
        _check(report, 'figma sources').outcome,
        PreflightOutcome.satisfied,
      );
    });

    test('a reachable design with no token blocks', () async {
      _figmaFlow('home', reaches: '/home');
      _mapping('home', '/home', nodeMapping: 'figma/home.nodes.yaml');
      _write('figma/home.nodes.yaml', 'screen: /home\nnodes: {}\n');

      final report = await _run(suiteYaml, environmentVariables: const {});

      final check = _check(report, 'figma sources');
      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('FIGMA_TOKEN'));
      expect(check.detail, contains('/home'));
    });

    test('a reachable design with no node mapping blocks', () async {
      _figmaFlow('home', reaches: '/home');
      _mapping('home', '/home', nodeMapping: 'figma/absent.nodes.yaml');

      final report = await _run(suiteYaml);

      final check = _check(report, 'figma sources');
      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('figma/absent.nodes.yaml'));
    });

    test('a design on a screen the suite never reaches does not block',
        () async {
      // The whole point of the reachability walk. `resolveFigmaSources`
      // reports this one at run time; preflight must not refuse the
      // suite over a design no test in it will ever ask for.
      _figmaFlow('home', reaches: '/home');
      _mapping('home', '/home');
      _mapping('other', '/other', nodeMapping: 'figma/other.nodes.yaml');

      final report = await _run(suiteYaml, environmentVariables: const {});

      final check = _check(report, 'figma sources');
      expect(check.outcome, PreflightOutcome.satisfied);
      expect(check.detail, isNot(contains('/other')));
    });

    test('an unreachable design with no node mapping does not block',
        () async {
      _figmaFlow('home', reaches: '/home');
      _mapping('home', '/home');
      _mapping('other', '/other', nodeMapping: 'figma/absent.nodes.yaml');

      final report = await _run(suiteYaml);

      expect(
        _check(report, 'figma sources').outcome,
        PreflightOutcome.satisfied,
      );
    });

    test('a validateScreen with no expectScreen before it says nothing',
        () async {
      // Unattributable: the screen a validateScreen compares is whichever
      // one the application is on, and with nothing asserted a file
      // cannot say which. `_missingBaselines` reports nothing here for
      // the same reason - a blocker invented from a guess would refuse a
      // suite that works.
      _figmaFlow('home');
      _mapping('home', '/home', nodeMapping: 'figma/absent.nodes.yaml');

      final report = await _run(suiteYaml, environmentVariables: const {});

      expect(
        _check(report, 'figma sources').outcome,
        PreflightOutcome.satisfied,
      );
    });

    test('an optional test alone is a notice', () async {
      _figmaFlow('home', reaches: '/home');
      _mapping('home', '/home', nodeMapping: 'figma/absent.nodes.yaml');

      final report = await _run('''
suite: s
app: {target: lib/main_mytest.dart}
device: {profile: p}
tests:
  - {id: home, flow: flows/home.yaml, optional: true}
''');

      final check = _check(report, 'figma sources');
      expect(check.outcome, PreflightOutcome.notice);
      expect(check.isBlocking, isFalse);
    });
  });

  test('permission missing blocks and names the grant that would fix it',
      () async {
    final report = await _run('''
suite: s
app: {target: lib/main_mytest.dart}
device:
  profile: p
  permissions: [android.permission.ACCESS_FINE_LOCATION]
tests:
  - {id: home, flow: flows/home.yaml}
''',
        environment: FakeEnvironment(
          permissions: const {
            'android.permission.ACCESS_FINE_LOCATION': false,
          },
        ));

    final check = _check(report, 'permissions');
    expect(check.outcome, PreflightOutcome.blocked);
    expect(check.remedy, contains('pm grant com.example.app'));
  });

  test('network interface missing blocks, and says no backend is needed',
      () async {
    final report = await _run(
      _minimal,
      environment: FakeEnvironment(network: NetworkInterfaceState.down),
    );

    final check = _check(report, 'network interface');
    expect(check.outcome, PreflightOutcome.blocked);
    expect(check.detail, contains('NETWORK_INTERFACE_REQUIRED'));
    expect(check.remedy, contains('No backend'));
  });

  group('mock server', () {
    const suite = '''
suite: s
app: {target: lib/main_mytest.dart}
device: {profile: p}
mockApi: {port: 8080}
tests:
  - {id: home, flow: flows/home.yaml}
''';

    test('an occupied port blocks', () async {
      _scenario('default');

      final report = await _run(suite, portFree: false);

      expect(_check(report, 'mock API').outcome, PreflightOutcome.blocked);
    });

    test('a malformed scenario blocks instead of crashing', () async {
      // Measured before this existed: ScenarioLibrary.load threw straight
      // through `testsmith suite run`, which exited 255 with a stack trace -
      // a configuration mistake reported as a crash.
      _write('mock_api/scenarios/default.json',
          '{"name": "default", "routes": []}');

      final report = await _run(suite);

      final check = _check(report, 'mock API');
      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('routes'));
    });

    test('a missing default scenario blocks', () async {
      final report = await _run(suite);

      expect(_check(report, 'mock API').outcome, PreflightOutcome.blocked);
    });

    test('a flow naming an API state no scenario provides blocks', () async {
      _scenario('default');
      _flow('home', fixture: 'nowhere');

      final report = await _run(suite);

      final check = _check(report, 'mock API');
      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.detail, contains('nowhere'));
    });

    test('a suite declaring no mock API is satisfied without looking',
        () async {
      final report = await _run(_minimal);

      expect(_check(report, 'mock API').outcome, PreflightOutcome.satisfied);
    });
  });

  test('a missing application build blocks', () async {
    File('${_project.path}/lib/main_mytest.dart').deleteSync();

    final report = await _run(_minimal);

    expect(
      _check(report, 'application build').outcome,
      PreflightOutcome.blocked,
    );
  });

  group('baseline', () {
    test('a missing one is a notice and never blocks', () async {
      _flow('home', photographs: '/home');

      final report = await _run(_minimal);

      final check = _check(report, 'baselines');
      expect(check.outcome, PreflightOutcome.notice);
      expect(check.detail, contains('/home'));
      expect(report.isBlocked, isFalse);
    });

    test('a present one is satisfied', () async {
      _flow('home', photographs: '/home');
      _write('visual_baselines/p/home.png', 'not really a png');

      final report = await _run(_minimal);

      expect(_check(report, 'baselines').outcome, PreflightOutcome.satisfied);
    });

    test('a screen the flow never names is not reported as missing', () async {
      // A validateScreen with no expectScreen before it photographs
      // whatever the application is on, which the file does not say. A
      // notice invented from a guess is noise.
      _write('flows/home.yaml', '''
appId: com.example.app
flow: home
steps:
  - launchApp
  - validateScreen:
      visual: true
''');

      final report = await _run(_minimal);

      expect(_check(report, 'baselines').outcome, PreflightOutcome.satisfied);
    });
  });

  group('authentication', () {
    test('is deferred and names the tests that need it', () async {
      final report = await _run('''
suite: s
app: {target: lib/main_mytest.dart}
device: {profile: p}
preconditions:
  authenticated: {unmetOn: [/login]}
tests:
  - {id: home, flow: flows/home.yaml, requires: [authenticated]}
''');

      final check = _check(report, 'authentication');
      expect(check.outcome, PreflightOutcome.deferred);
      expect(check.detail, contains('home'));
      expect(report.isBlocked, isFalse);
    });

    test('is satisfied when nothing in the suite requires a session',
        () async {
      final report = await _run(_minimal);

      expect(
        _check(report, 'authentication').outcome,
        PreflightOutcome.satisfied,
      );
    });
  });

  group('application installed', () {
    test('is a notice when the first launch would install it anyway',
        () async {
      final report =
          await _run(_minimal, environment: FakeEnvironment(installed: false));

      expect(_check(report, 'application installed').isBlocking, isFalse);
      expect(report.isBlocked, isFalse);
    });

    test('blocks when the suite must touch it before launching', () async {
      final report = await _run('''
suite: s
app: {target: lib/main_mytest.dart}
device:
  profile: p
  permissions: [android.permission.CAMERA]
tests:
  - {id: home, flow: flows/home.yaml}
''', environment: FakeEnvironment(installed: false));

      expect(_check(report, 'application installed').isBlocking, isTrue);
    });

    test('blocks when a test declares clearState', () async {
      final report = await _run('''
suite: s
app: {target: lib/main_mytest.dart}
device: {profile: p}
tests:
  - {id: home, flow: flows/home.yaml, reset: clearState}
''', environment: FakeEnvironment(installed: false));

      expect(_check(report, 'application installed').isBlocking, isTrue);
    });
  });

  group('a project fact preflight could not read', () {
    // The three conditions this group covers are the same shape: a fact
    // knowable from the project alone, before any device is touched,
    // that `testsmith run` already refuses outright. Preflight answered
    // "nothing blocking" for all three - and for two of them it did
    // worse than stay quiet, printing `[ok]` about a question it had
    // not answered.
    const twoTests = '''
suite: s
app: {target: lib/main_mytest.dart}
device: {profile: p}
tests:
  - {id: home, flow: flows/home.yaml}
  - {id: extra, flow: flows/extra.yaml, optional: true}
''';

    test('a mapping that will not parse blocks the screen check', () async {
      _write('mappings/home.yaml', 'screen: [this is not a screen\n');

      final report = await _run(_minimal);

      final check = _check(report, 'screen configuration');
      expect(check.outcome, PreflightOutcome.blocked, reason: check.detail);
      expect(check.detail, contains('home.yaml'));
      expect(report.exitCode, 2);
    });

    test('and never claims one configuration per screen instead', () async {
      _write('mappings/home.yaml', 'screen: [this is not a screen\n');

      final report = await _run(_minimal);

      expect(
        _check(report, 'screen configuration').detail,
        isNot(contains('one configuration per screen')),
      );
    });

    test('a mapping that reads is untouched', () async {
      _write(
        'mappings/home.yaml',
        'screen: /home\nmappings:\n  - {target: t.a, source: response.a}\n',
      );

      final report = await _run(_minimal);

      expect(_check(report, 'screen configuration').outcome,
          PreflightOutcome.satisfied);
    });

    test('a required flow that will not parse blocks', () async {
      _write('flows/home.yaml', 'appId: [oops\n');

      final report = await _run(_minimal);

      final check = _check(report, 'flows');
      expect(check.outcome, PreflightOutcome.blocked, reason: check.detail);
      expect(check.detail, contains('home'));
      expect(report.exitCode, 2);
    });

    test('an optional one is a notice, and still reported', () async {
      _flow('extra');
      _write('flows/extra.yaml', 'appId: [oops\n');

      final report = await _run(twoTests);

      final check = _check(report, 'flows');
      expect(check.outcome, PreflightOutcome.notice, reason: check.detail);
      expect(check.detail, contains('extra'));
      expect(report.isBlocked, isFalse, reason: '${report.blockers}');
    });

    test('one good flow does not cover for a broken one', () async {
      // The case that made this invisible: with something to parse,
      // every other check ran and the report read as though the suite
      // were sound.
      _flow('extra');
      _write('flows/extra.yaml', 'appId: [oops\n');

      final report = await _run(
        twoTests.replaceFirst(', optional: true', ''),
      );

      expect(_check(report, 'flows').outcome, PreflightOutcome.blocked);
    });

    test('and its status is deferred rather than asserted', () async {
      // `flow status` reads `isProposed`, which needs a parsed flow. It
      // may not report that every flow has been accepted when one of
      // them was never read.
      _write('flows/home.yaml', 'appId: [oops\n');

      final report = await _run(_minimal);

      expect(_check(report, 'flow status').outcome, PreflightOutcome.deferred);
    });

    test('flows that all read are satisfied', () async {
      final report = await _run(_minimal);

      expect(_check(report, 'flows').outcome, PreflightOutcome.satisfied);
    });

    test('a required test needing an API state with no server blocks',
        () async {
      _flow('home', fixture: 'signed_in');

      final report = await _run(_minimal);

      final check = _check(report, 'mock API');
      expect(check.outcome, PreflightOutcome.blocked, reason: check.detail);
      expect(check.detail, contains('signed_in'));
      expect(report.exitCode, 2);
    });

    test('and never says the suite declares no mock API instead', () async {
      _flow('home', fixture: 'signed_in');

      final report = await _run(_minimal);

      expect(
        _check(report, 'mock API').detail,
        isNot(contains('declares no mock API')),
      );
    });

    test('an optional test needing one is a notice', () async {
      _flow('extra', fixture: 'signed_in');

      final report = await _run(twoTests);

      final check = _check(report, 'mock API');
      expect(check.outcome, PreflightOutcome.notice, reason: check.detail);
      expect(check.detail, contains('extra'));
      expect(report.isBlocked, isFalse, reason: '${report.blockers}');
    });

    test('a suite that declares a port keeps the behaviour it had',
        () async {
      // The control for the whole group: with a server declared, the
      // question is whether the state resolves, which is unchanged.
      _flow('home', fixture: 'signed_in');
      _scenario('default');
      _scenario('signed_in');

      final report = await _run('''
suite: s
app: {target: lib/main_mytest.dart}
device: {profile: p}
mockApi: {port: 8080}
tests:
  - {id: home, flow: flows/home.yaml}
''');

      expect(_check(report, 'mock API').outcome, PreflightOutcome.satisfied);
    });
  });

  test('no check anywhere carries a device serial', () async {
    final report = await _run(
      _minimal,
      attached: const [
        AdbDevice(serial: 'RZ8T11QETWM', model: 'SM-M127G', state: 'device'),
      ],
      requested: 'RZ8T11QETWM',
    );

    for (final check in report.checks) {
      expect(check.detail, isNot(contains('RZ8T11QETWM')), reason: check.name);
      expect(check.remedy, isNot(contains('RZ8T11QETWM')), reason: check.name);
    }
  });
}
