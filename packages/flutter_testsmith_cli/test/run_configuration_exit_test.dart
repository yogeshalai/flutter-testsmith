// RUN-CONFIG-EXIT: `run` on configuration it cannot use.
//
// The CI contract is E-03's: 0 passed, 1 FAIL - the application is wrong,
// 2 ERROR - the run is wrong, 64 usage. E-03 files configuration under
// 2 ("no such suite file", "invalid syntax", "missing flow"), and `suite
// run` and `preflight` have always answered a broken mapping, flow or
// scenario that way. `run` answered 1 - the application's code - for
// every one of them. Measured at 48d9cac, offline:
//
//   malformed mapping / flow / scenario     run 1   preflight 2   suite 2
//   undecodable mapping / scenario          run 1   preflight 2   suite 2
//   no such flow file                       run 1   (no such suite: 2)
//
// That 1 was inherited from Phase 4 (6e32ef4), when `run` returned 1 for
// every failure including a missing device; nothing ever argued for it
// from the 0/1/2 contract. And once the application is running, `run`
// already answered 2 for the same class of mistake - a mapping bound to
// a Figma node the design does not have is an ERROR, which
// `exitCodeForRun` maps to 2. One mistake, two codes, depending only on
// when it was noticed.
//
// Offline, and no device except where the check sits behind one. Every
// case fails before anything is launched.
@Timeout(Duration(minutes: 8))
library;

import 'dart:io';

import 'package:flutter_testsmith_cli/src/flow_executor.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:test/test.dart';

late Directory _root;
late Directory _app;

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

void _writeBytes(String relative, List<int> bytes) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

/// [text] as UTF-16 LE with a byte-order mark, which `readAsString`
/// refuses outright.
List<int> _utf16leWithBom(String text) => [
      0xFF,
      0xFE,
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];

const String _flow = 'appId: com.example.x\nflow: home\nsteps:\n'
    '  - launchApp\n'
    '  - expectScreen:\n      id: /home\n';
const String _mapping = 'screen: /home\napi: GET /home\n'
    'mappings:\n  - {target: home.title, source: response.title}\n';
const String _scenario = '{"name":"default","routes":{}}';

const String _serial = 'FAKESERIAL1';

/// An adb that reports one attached device, for the one check that sits
/// behind the device gate. Portable per A-3.
String _fakeAdb() {
  final directory = Directory('${_root.path}/fake_adb')..createSync();
  const line = '$_serial            device product:f model:Fake device:f';
  if (Platform.isWindows) {
    return (File('${directory.path}/adb.bat')
          ..writeAsStringSync(
            '@echo off\r\necho List of devices attached\r\necho $line\r\n',
          ))
        .path;
  }
  final file = File('${directory.path}/adb')
    ..writeAsStringSync(
      '#!/bin/sh\necho "List of devices attached"\necho "$line"\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

Map<String, String> get _offline => {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    };

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _run(
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'run',
      ...arguments,
    ],
    environment: environment ?? _offline,
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

/// `run` on the sound project, plus [extra], against its flow.
Future<Run> _runFlow({
  List<String> extra = const [],
  Map<String, String>? environment,
}) =>
    _run(
      ['--app', _app.path, ...extra, '${_app.path}/tests/home.yaml'],
      environment: environment,
    );

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}';

/// A configuration answer: exit 2, [says] on stdout, no crash, and no
/// device or launch reached - the refusal came from the project.
void _expectConfiguration(Run run, String says) {
  expect(run.code, 2, reason: _both(run));
  expect(run.stdout, contains(says), reason: _both(run));
  for (final stream in [run.stdout, run.stderr]) {
    expect(stream, isNot(contains('Unhandled exception')), reason: _both(run));
    expect(stream, isNot(contains('#0 ')), reason: _both(run));
  }
  expect(run.stdout, isNot(contains('launching app')), reason: _both(run));
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('run_config_exit');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('tests/home.yaml', _flow);
    _write('mappings/home.yaml', _mapping);
    _write('mock_api/scenarios/default.json', _scenario);
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('run on configuration it cannot use exits 2', () {
    test('no such flow file', () async {
      final run =
          await _run(['--app', _app.path, '${_app.path}/tests/no.yaml']);

      _expectConfiguration(run, 'No such flow file');
    });

    test('not inside a Flutter project', () async {
      // Standing in a directory with no pubspec anywhere above it, and
      // naming no application.
      final elsewhere = Directory('${_root.path}/elsewhere')..createSync();
      File('${elsewhere.path}/home.yaml').writeAsStringSync(_flow);

      final run = await _run(['${elsewhere.path}/home.yaml']);

      _expectConfiguration(run, 'not inside a Flutter project');
    });

    test('a malformed flow', () async {
      _write('tests/home.yaml', 'appId: com.example.x\nflow: home\nsteps: 7\n');

      final run = await _runFlow();

      _expectConfiguration(run, 'FlowFormatException');
    });

    test('an undecodable flow', () async {
      _writeBytes('tests/home.yaml', _utf16leWithBom(_flow));

      final run = await _runFlow();

      _expectConfiguration(run, 'could not be read');
    });

    test('a proposed flow', () async {
      _write('tests/home.yaml', 'status: proposed\n$_flow');

      final run = await _runFlow();

      _expectConfiguration(run, 'status: proposed');
    });

    test('a malformed mapping', () async {
      _write('mappings/home.yaml', 'screen: [not a screen\n');

      final run = await _runFlow();

      _expectConfiguration(run, 'MappingsFormatException');
    });

    test('an undecodable mapping', () async {
      _writeBytes('mappings/home.yaml', _utf16leWithBom(_mapping));

      final run = await _runFlow();

      _expectConfiguration(run, 'MappingsFormatException');
    });

    test('two configurations for one screen', () async {
      _write('mappings/home_copy.yaml', _mapping);

      final run = await _runFlow();

      _expectConfiguration(run, 'Duplicate screen configuration');
    });

    test('a fixture the flow needs and no server to arrange it', () async {
      _write(
        'tests/home.yaml',
        _flow.replaceFirst('flow: home\n', 'flow: home\nfixture: default\n'),
      );

      final run = await _runFlow();

      _expectConfiguration(run, 'needs the "default" API state');
    });

    test('a malformed mock API scenario', () async {
      _write('mock_api/scenarios/default.json', '{"name":"default","routes":');

      final run = await _runFlow(extra: const ['--mock-api', '8571']);

      _expectConfiguration(run, 'invalid JSON');
    });

    test('an undecodable mock API scenario', () async {
      _writeBytes(
        'mock_api/scenarios/default.json',
        _utf16leWithBom(_scenario),
      );

      final run = await _runFlow(extra: const ['--mock-api', '8571']);

      _expectConfiguration(run, 'Failed to decode');
    });

    test('a mock API scenario that is not there', () async {
      File('${_app.path}/mock_api/scenarios/default.json').deleteSync();

      final run = await _runFlow(extra: const ['--mock-api', '8571']);

      _expectConfiguration(run, 'No API scenario named "default"');
    });

    test('an undecodable .env', () async {
      // Loaded after the device gate, so given a device to pass it.
      _writeBytes('.env', _utf16leWithBom('MYTEST_AUTH_PIN=0000\n'));

      final run = await _runFlow(
        extra: const ['--device', _serial],
        environment: {..._offline, 'MYTEST_ADB': _fakeAdb()},
      );

      _expectConfiguration(run, '.env: Failed to decode');
    });
  });

  group('the codes that do not move', () {
    test('usage is still 64', () async {
      final run = await _run(const []);

      expect(run.code, 64, reason: _both(run));
    });

    // One class of mistake - a mapping that does not fit the project -
    // caught before launch and after it. Before, it is a mapping that
    // will not parse (above: 2). After, it is a mapping bound to a Figma
    // node the design does not have, which the engine reports as an
    // ERROR because "a mapping that points at a deleted layer is a
    // broken tool configuration, not a broken application". Both are
    // the run being wrong. A value the screen shows wrongly is the
    // application being wrong, and stays 1.
    RunResult validating(ValidationResult check) => RunResult(
          flowName: 'f',
          appId: 'a',
          device: 'd',
          startedAt: DateTime.utc(2026),
          duration: Duration.zero,
          steps: const [
            StepOutcome(
              description: 's',
              kind: StepKind.tap,
              status: StepStatus.ok,
              durationMs: 0,
            ),
          ],
          screens: [
            ScreenResult(screenId: '/s', report: ValidationReport([check])),
          ],
        );

    test('the same mistake found after launch is 2 as well', () {
      expect(
        exitCodeForRun(validating(const ValidationResult.error(
          validatorId: 'figma-mapping',
          message: 'the mapping binds Figma node "1:2", which is not in '
              'the "Home" frame.',
          dimension: ValidationDimension.figma,
        ))),
        2,
      );
    });

    test('an application failure is still 1', () {
      expect(
        exitCodeForRun(validating(const ValidationResult.fail(
          validatorId: 'api-to-ui',
          message: 'the price is wrong',
          dimension: ValidationDimension.ui,
        ))),
        1,
      );
    });
  });
}
