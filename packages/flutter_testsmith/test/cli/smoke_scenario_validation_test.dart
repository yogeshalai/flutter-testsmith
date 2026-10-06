// SMOKE-SCENARIO: `smoke --mock-api` on a scenario it cannot serve.
//
// `run` reads, checks and resolves its fixture scenario before it looks
// for a device (5e9c169): a scenario file is a fact about the project,
// and nothing needs to be attached to discover it. `smoke` did it inside
// the runner, after the device gate and the Flutter check, so measured
// at 22dab36, offline:
//
//   malformed default.json, no adb       "adb could not be found."
//   malformed default.json, a device     adb devices, then "Smoke run
//                                        failed: ScenarioFormatException"
//   no default.json                      the same, "no such scenario"
//
// The scenario's problem was hidden behind whatever the machine lacked,
// and when it did surface it came through the catch-all for a run that
// had failed. It is now refused where `run` refuses it, in `run`'s words,
// at `smoke`'s code for a refusal: 1.
//
// Offline. A fake adb and a fake flutter record every call, so "nothing
// was asked of them" is read off their logs rather than inferred.
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';

late Directory _root;
late Directory _app;
late File _adbCalls;
late File _flutterCalls;

void _scenario(String name, String json) {
  File('${_app.path}/mock_api/scenarios/$name.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(json);
}

/// A PATH holding an adb that lists [_serial] and a flutter that exits,
/// each recording its calls. Portable per A-3.
String _fakeTools() {
  final directory = Directory('${_root.path}/tools')..createSync();
  if (Platform.isWindows) {
    File('${directory.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo %*>> "${_adbCalls.path}"\r\n'
      'if "%1"=="devices" (\r\n'
      '  echo List of devices attached\r\n'
      '  echo $_serial            device product:f model:Fake device:f\r\n'
      ')\r\n'
      'exit /b 0\r\n',
    );
    File('${directory.path}/flutter.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo %*>> "${_flutterCalls.path}"\r\n'
      'exit /b 0\r\n',
    );
  } else {
    final adb = File('${directory.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$*" >> "${_adbCalls.path}"\n'
        'if [ "\$1" = "devices" ]; then\n'
        '  echo "List of devices attached"\n'
        '  echo "$_serial            device product:f model:Fake device:f"\n'
        'fi\n'
        'exit 0\n',
      );
    final flutter = File('${directory.path}/flutter')
      ..writeAsStringSync(
        '#!/bin/sh\necho "\$*" >> "${_flutterCalls.path}"\nexit 0\n',
      );
    Process.runSync('chmod', ['+x', adb.path, flutter.path]);
  }
  return directory.path;
}

typedef Run = ({String stdout, String stderr, int code});

/// `smoke` against [_app]. [tools] false leaves adb and flutter off PATH
/// entirely, for the case where the machine is missing them as well.
Future<Run> _smoke({
  bool mockApi = true,
  bool tools = true,
}) async {
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'smoke',
      '--app',
      _app.path,
      '--app-id',
      'com.example.x',
      '--device',
      _serial,
      if (mockApi) ...['--mock-api', '0'],
    ],
    environment: {
      // No Dart directory: on a host whose Dart sits inside a Flutter SDK
      // it would put the real flutter on PATH.
      'PATH': [if (tools) _fakeTools(), system]
          .join(Platform.isWindows ? ';' : ':'),
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
  ).timeout(const Duration(seconds: 120));
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}\n'
    'adb: ${_adbCalls.existsSync() ? _adbCalls.readAsStringSync() : '-'}\n'
    'flutter: '
    '${_flutterCalls.existsSync() ? _flutterCalls.readAsStringSync() : '-'}';

/// Refused at 1 with [says], before anything outside the project was
/// asked: no adb call, no flutter call, no server, no catch-all.
void _expectRefusedFirst(Run run, String says) {
  expect(run.code, 1, reason: _both(run));
  expect(run.stdout, contains(says), reason: _both(run));
  expect(run.stderr, isEmpty, reason: _both(run));
  expect(_adbCalls.existsSync(), isFalse, reason: _both(run));
  expect(_flutterCalls.existsSync(), isFalse, reason: _both(run));
  for (final later in const [
    'mock API on',
    'waking device',
    'Smoke run failed',
    'No usable device',
    'adb could not be found',
    'flutter was not found',
  ]) {
    expect(run.stdout, isNot(contains(later)), reason: _both(run));
  }
  for (final stream in [run.stdout, run.stderr]) {
    expect(stream, isNot(contains('Unhandled exception')), reason: _both(run));
    expect(stream, isNot(contains('#0 ')), reason: _both(run));
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('smoke_scenario');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    File('${_app.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _adbCalls = File('${_root.path}/adb_calls.log');
    _flutterCalls = File('${_root.path}/flutter_calls.log');
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('smoke refuses a scenario it cannot serve before the device', () {
    test('a scenario that is not JSON', () async {
      _scenario('default', '{"name":"default","routes":');

      final run = await _smoke();

      _expectRefusedFirst(run, 'ScenarioFormatException');
      expect(run.stdout, contains('default.json'), reason: _both(run));
    });

    test('no default scenario, where others exist', () async {
      _scenario('other', '{"name":"other","routes":{}}');

      final run = await _smoke();

      // `run`'s sentence for the same mistake.
      _expectRefusedFirst(run, 'No API scenario named "default".');
      expect(run.stdout, contains('Available: other'), reason: _both(run));
    });

    test('no scenario directory at all', () async {
      final run = await _smoke();

      _expectRefusedFirst(run, 'No API scenario named "default".');
      expect(run.stdout, contains('Available: (none)'), reason: _both(run));
    });

    test('a default that inherits a scenario that is not there', () async {
      _scenario(
        'default',
        '{"name":"default","inherits":"base","routes":{}}',
      );

      final run = await _smoke();

      _expectRefusedFirst(run, 'no such scenario');
    });

    test('and ahead of a machine missing adb and flutter too', () async {
      // The scenario is the project's problem and is named first, rather
      // than hidden behind the machine's.
      _scenario('default', '{"name":"default","routes":');

      final run = await _smoke(tools: false);

      _expectRefusedFirst(run, 'ScenarioFormatException');
    });
  });

  group('what moving the check must not change', () {
    test('without --mock-api no scenario is read', () async {
      // As in `run`: a scenario is read only for a run that serves one.
      _scenario('default', '{"name":"default","routes":');

      final run = await _smoke(mockApi: false, tools: false);

      expect(run.code, 1, reason: _both(run));
      expect(run.stdout, contains('adb could not be found.'),
          reason: _both(run));
      expect(run.stdout, isNot(contains('Scenario')), reason: _both(run));
    });

    test('a sound scenario still reaches the device gate', () async {
      _scenario('default', '{"name":"default","routes":{}}');

      final run = await _smoke(tools: false);

      expect(run.code, 1, reason: _both(run));
      expect(run.stdout, contains('adb could not be found.'),
          reason: _both(run));
      expect(run.stdout, isNot(contains('No API scenario')),
          reason: _both(run));
    });
  });
}
