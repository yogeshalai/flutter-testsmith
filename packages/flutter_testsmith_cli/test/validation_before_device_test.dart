// What a command does before it needs hardware.
//
// The repository says the rule three times - "before anything is
// launched" in `run_command`, `suite_file` and `mappings` - and three
// commands answered the same broken project differently. Measured
// against 6749e7f, one project with two mappings for `/home` and no
// device attached:
//
//   testsmith run         -> names the duplicate, exit 1
//   testsmith suite run   -> No usable device attached, exit 2
//   testsmith preflight   -> No usable device attached, exit 2
//
// and with duplicate Figma specs or a malformed mock scenario, even
// `run` reported only the device, because its own handlers for those sit
// below device selection and were never reached.
//
// Everything checkable from the project alone is now checked first. A
// project that is wrong is told so on a laptop with nothing plugged in.
//
// Offline throughout: no device, no network, no build. `suite run` is
// driven with `-d` naming a device that is not there, which is how
// `suite_command_exit_codes_test` already reaches that command's later
// stages without hardware.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/no_device_adb.dart';

late Directory _root;
late Directory _app;

const String _deviceError = 'No usable device attached';
const String _duplicate = 'Duplicate screen configuration';

void _write(String relative, String contents) {
  final file = File('${_app.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

String _spec(String figmaName) => '{"screen":"/home","nodeId":"1:1",'
    '"figmaName":"$figmaName","width":400.0,"height":800.0,'
    '"elements":[],"totalNodesWalked":1}';

String _mapping(String target) =>
    'screen: /home\nmappings:\n  - {target: $target, source: response.a}\n';

typedef Run = ({String output, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    // "Nothing plugged in" is arranged rather than assumed. With the host's
    // adb, a handset on the machine running this turned both controls
    // below into a real launch on it.
    environment: noDeviceEnvironment(_root),
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

Future<Run> _run(List<String> extra) => _testsmith([
      'run',
      '${_app.path}/tests/home.yaml',
      '--app',
      _app.path,
      ...extra,
    ]);

/// `suite run` with a serial that is not attached.
///
/// A named serial is how this command reaches its later stages with no
/// hardware: the context builder needs *a* serial, and preflight is what
/// later reports that it is not there.
Future<Run> _suite() => _testsmith([
      'suite',
      'run',
      '${_app.path}/suites/s.yaml',
      '-d',
      'no-such-device',
      '--out',
      '${_root.path}/out',
    ]);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('validate_first');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
    );
    _write(
      'suites/s.yaml',
      'suite: s\napp: {path: ..}\ndevice: {profile: p}\n'
      'tests:\n  - {id: home, flow: tests/home.yaml}\n',
    );
    _write(
      'device_profiles/p.yaml',
      'id: p\nmodel: Fixture\nos: Android 13\n'
      'physical: {width: 720, height: 1600}\n'
      'devicePixelRatio: 1.875\norientation: portrait\nbuildMode: debug\n',
    );
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('testsmith run, with nothing plugged in', () {
    test('a duplicate mapping is named, not the device', () async {
      _write('mappings/a.yaml', _mapping('t.a'));
      _write('mappings/z.yaml', _mapping('t.z'));

      final run = await _run(const []);

      expect(run.output, contains(_duplicate), reason: run.output);
      expect(run.output, isNot(contains(_deviceError)), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a duplicate Figma spec is named, not the device', () async {
      _write('figma/a.json', _spec('A'));
      _write('figma/z.json', _spec('Z'));

      final run = await _run(const []);

      expect(run.output, contains(_duplicate), reason: run.output);
      expect(run.output, contains('a.json'), reason: run.output);
      expect(run.output, contains('z.json'), reason: run.output);
      expect(run.output, isNot(contains(_deviceError)), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a malformed mock scenario is named, not the device', () async {
      _write('mock_api/scenarios/default.yaml', 'this: is: not: a: scenario\n');

      final run = await _run(const ['--mock-api', '8099']);

      expect(run.output, isNot(contains(_deviceError)), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a scenario that is not there is named, not the device', () async {
      _write('mock_api/scenarios/other.yaml', 'name: other\nendpoints: []\n');

      final run = await _run(const ['--mock-api', '8099', '--fixture', 'gone']);

      expect(run.output, contains('gone'), reason: run.output);
      expect(run.output, isNot(contains(_deviceError)), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });

    test('a valid project still reaches the device gate', () async {
      // The control. Reordering must not turn configuration into a
      // second reason to refuse a project that is fine.
      _write('mappings/home.yaml', _mapping('t.a'));
      _write('figma/home.json', _spec('Home'));

      final run = await _run(const []);

      expect(run.output, contains(_deviceError), reason: run.output);
      expect(run.output, isNot(contains(_duplicate)), reason: run.output);
      // 2 since RUN-ENV-EXIT: no device is the run being wrong. Which
      // also makes the code tell this apart from the duplicate cases
      // above, which stay 1.
      expect(run.code, 2, reason: run.output);
    });
  });

  group('testsmith suite run, with nothing plugged in', () {
    test('a duplicate mapping is named before the preflight verdict',
        () async {
      _write('mappings/a.yaml', _mapping('t.a'));
      _write('mappings/z.yaml', _mapping('t.z'));

      final run = await _suite();

      expect(run.output, contains(_duplicate), reason: run.output);
      expect(run.code, isNot(0), reason: run.output);
    });

    test('a duplicate Figma spec is named before the preflight verdict',
        () async {
      _write('figma/a.json', _spec('A'));
      _write('figma/z.json', _spec('Z'));

      final run = await _suite();

      expect(run.output, contains(_duplicate), reason: run.output);
      expect(run.code, isNot(0), reason: run.output);
    });

    test('a valid project still reaches the preflight verdict', () async {
      // Asserted on the report rather than only on the exit code: a
      // malformed fixture also exits 2, and this control has to fail if
      // the command stopped before preflight for any other reason.
      _write('mappings/home.yaml', _mapping('t.a'));

      final run = await _suite();

      expect(run.output, contains('preflight'), reason: run.output);
      expect(run.output, contains('no usable device is attached'),
          reason: run.output);
      expect(run.output, isNot(contains(_duplicate)), reason: run.output);
      expect(run.output, isNot(contains('Exception')), reason: run.output);
      expect(run.code, 2, reason: run.output);
    });
  });

  test('the fixture server is not bound before the project is checked',
      () async {
    // The resource half. A spec duplicate used to be found after
    // `MockApiServer.start`, so the run returned having opened a socket
    // that only `exit()` closed.
    _write('figma/a.json', _spec('A'));
    _write('figma/z.json', _spec('Z'));
    _write(
      'mock_api/scenarios/default.yaml',
      'name: default\nendpoints: []\n',
    );

    final run = await _run(const ['--mock-api', '8098']);

    expect(run.output, contains(_duplicate), reason: run.output);
    expect(run.output, isNot(contains('mock API on')),
        reason: 'the server was started before the project was checked:\n'
            '${run.output}');
  });
}
