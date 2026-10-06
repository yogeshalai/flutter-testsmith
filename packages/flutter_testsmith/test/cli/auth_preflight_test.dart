// Auth setup asks E-04's questions, using E-04's check functions.
//
// Two things differ from a suite's preflight and both are deliberate:
// there is no mock API to check, because auth setup runs against the
// real backend; and that backend is `deferred` rather than probed - a
// probe from the host would be a network call the platform otherwise
// never makes, and it would prove only that the *host* can reach it.

import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/auth_preflight.dart';
import 'package:flutter_testsmith/engine.dart';

const String _yaml = '''
auth: t
app: {path: ., target: lib/main_uat.dart, flavor: f}
appId: com.example.app
device:
  profile: p
  permissions: [android.permission.ACCESS_FINE_LOCATION]
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/login]
login:
  - tap: {id: continue_button}
verify: {route: /home, element: home.body}
''';

class FakeEnvironment implements DeviceEnvironment {
  FakeEnvironment({
    this.installed = true,
    this.permissions = const {'android.permission.ACCESS_FINE_LOCATION': true},
    this.network = NetworkInterfaceState.up,
  });

  final bool installed;
  final Map<String, bool> permissions;
  final NetworkInterfaceState network;

  @override
  Future<bool> isInstalled(String appId) async => installed;

  @override
  Future<Map<String, bool>> runtimePermissions(String appId) async =>
      permissions;

  @override
  Future<NetworkInterfaceState> networkInterface() async => network;
}

late Directory _project;

Future<PreflightReport> _run({
  FakeEnvironment? environment,
  List<AdbDevice> attached = const [
    AdbDevice(serial: 'S1', model: 'M', state: 'device'),
  ],
  bool flutterOnPath = true,
}) =>
    AuthPreflightRunner(
      file: AuthFile.parse(_yaml, source: 'auth.yaml'),
      projectDirectory: _project,
      profile: const DeviceProfile(id: 'p'),
      deviceEnvironment: environment ?? FakeEnvironment(),
      attachedDevices: attached,
      requestedSerial: 'S1',
      deviceFacts: const DeviceFacts(),
      flutterOnPath: flutterOnPath,
    ).run();

void main() {
  setUp(() {
    _project = Directory.systemTemp.createTempSync('auth_preflight');
    addTearDown(() => _project.deleteSync(recursive: true));
    File('${_project.path}/lib/main_uat.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
  });

  test('a ready machine blocks nothing and exits 0', () async {
    final report = await _run();
    expect(report.isBlocked, isFalse);
    expect(report.exitCode, 0);
  });

  test(
      'it checks the build, the device, the profile, the permissions, '
      'the network and the backend', () async {
    final names = (await _run()).checks.map((c) => c.name).toList();
    expect(names, contains('application build'));
    expect(names, contains('device'));
    expect(names, contains('device profile'));
    expect(names, contains('permissions'));
    expect(names, contains('network interface'));
    expect(names, contains('authentication backend'));
  });

  test('and no mock API, because auth setup serves no fixtures', () async {
    final names = (await _run()).checks.map((c) => c.name).toList();
    expect(names, isNot(contains('mock API')));
  });

  test('the backend is deferred, never probed', () async {
    final backend = (await _run())
        .checks
        .firstWhere((c) => c.name == 'authentication backend');
    expect(backend.outcome, PreflightOutcome.deferred);
    expect(backend.klass, PrerequisiteClass.externalService);
    expect(backend.isBlocking, isFalse);
  });

  test('a denied permission blocks, and exits 2', () async {
    final report = await _run(
      environment: FakeEnvironment(
        permissions: const {
          'android.permission.ACCESS_FINE_LOCATION': false,
        },
      ),
    );
    expect(report.isBlocked, isTrue);
    expect(report.exitCode, 2);
  });

  test('no network interface blocks', () async {
    final report = await _run(
      environment: FakeEnvironment(network: NetworkInterfaceState.down),
    );
    expect(report.isBlocked, isTrue);
  });

  test('no device attached blocks', () async {
    expect((await _run(attached: const [])).isBlocked, isTrue);
  });

  test('every blocking check carries a remedy', () async {
    final report = await _run(attached: const []);
    for (final blocker in report.blockers) {
      expect(blocker.remedy, isNotEmpty, reason: blocker.name);
    }
  });

  test('nothing in the report names the serial or a credential', () async {
    final text = (await _run()).toJson().toString();
    expect(text, isNot(contains('S1')));
    expect(text, isNot(contains('MYTEST_AUTH_PIN')));
  });
}
