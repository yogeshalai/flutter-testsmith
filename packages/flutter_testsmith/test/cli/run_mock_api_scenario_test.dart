// RUN-MOCK-API: `run --mock-api` on a scenario it cannot use.
//
// `run` called `ScenarioLibrary.load` *outside* the clause that catches
// `ScenarioFormatException`; only `library.resolve` was inside it. The
// load is where a scenario file is read and parsed, so a file that was
// not JSON - or, since SCENARIO-DECODE, one in an encoding that cannot
// be read - reached `bin/testsmith.dart` as an unhandled exception and
// exit 255. Measured at 0a0a570 on Windows for both. `preflight`,
// `generate` and `suite run` already reported the same files.
//
// Now the load is guarded the way `resolve` was: the exception's own
// sentence, which names the file. That was exit 1, then the code `run`
// gave every failure before launching; since RUN-CONFIG-EXIT it is 2,
// because a scenario that cannot be used is the run being wrong.
//
// Offline throughout. The scenario is read before a device is looked
// for, so nothing here needs a handset, adb, or a free port.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

/// A value that must never appear in any output.
const String _secret = 'RUN_MOCK_API_SENTINEL_VALUE';

/// A flow that names no fixture, so `--mock-api` serves `default`.
const String _flowText = 'appId: com.example.x\nflow: home\nsteps:\n'
    '  - launchApp\n'
    '  - expectScreen:\n      id: /home\n';

/// A sound `default` scenario that carries [_secret] in a response body,
/// so a report that quoted a scenario would be caught quoting it.
const String _scenarioText = '{"name":"default","routes":{"GET /home":'
    '{"status":200,"body":{"token":"$_secret"}}}}';

/// [text] as UTF-16 LE with a byte-order mark: `FF FE` is not valid
/// UTF-8, so `readAsStringSync` refuses the file outright.
List<int> _utf16leWithBom(String text) => [
      0xFF,
      0xFE,
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];

late Directory _root;
late Directory _app;

String get _scenarioPath => '${_app.path}/mock_api/scenarios/default.json';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

typedef Run = ({String stdout, String stderr, int code});

/// `run --mock-api` with a PATH holding the Dart SDK and nothing else, so
/// no adb is reachable and a handset on the host cannot change an
/// answer. The port is never bound: the scenario is read first.
Future<Run> _runMockApi() async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'run',
      '--app',
      _app.path,
      '--mock-api',
      '8552',
      '${_app.path}/tests/home.yaml',
    ],
    environment: {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}';

/// No crash and nothing from the scenario, on either stream.
void _expectClean(Run run) {
  for (final stream in [run.stdout, run.stderr]) {
    expect(stream, isNot(contains('Unhandled exception')), reason: _both(run));
    expect(stream, isNot(contains('#0 ')), reason: _both(run));
    expect(stream, isNot(contains('file:///')), reason: _both(run));
    expect(stream, isNot(contains('FileSystemException')), reason: _both(run));
    expect(stream, isNot(contains(_secret)), reason: _both(run));
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('run_mock_api');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('tests/home.yaml', _flowText);
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('run --mock-api, on a scenario it cannot use', () {
    test('invalid JSON is reported and exits 2', () async {
      _write(
        'mock_api/scenarios/default.json',
        '{"name":"default","routes":{"token":"$_secret"',
      );

      final run = await _runMockApi();

      _expectClean(run);
      // The file is named as `listSync` spelled it, which on Windows
      // joins the last segment with a backslash - so the name, not the
      // whole path.
      expect(run.stdout, contains('ScenarioFormatException in '),
          reason: _both(run));
      expect(run.stdout, contains('default.json: invalid JSON'),
          reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });

    test('an undecodable file is reported and exits 2', () async {
      File(_scenarioPath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(_utf16leWithBom(_scenarioText));

      final run = await _runMockApi();

      _expectClean(run);
      expect(run.stdout, contains('ScenarioFormatException in '),
          reason: _both(run));
      expect(run.stdout, contains('default.json: Failed to decode'),
          reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });
  });

  group('what the guard must not have changed', () {
    test('a readable scenario still gets the run to the device stage',
        () async {
      _write('mock_api/scenarios/default.json', _scenarioText);

      final run = await _runMockApi();

      _expectClean(run);
      expect(run.stdout, isNot(contains('ScenarioFormatException')),
          reason: _both(run));
      // The resolver's sentence since AUDIT-2: nothing was found.
      expect(run.stdout, contains('adb could not be found'),
          reason: _both(run));
      // The device stage, which since RUN-ENV-EXIT is exit 2.
      expect(run.code, 2, reason: _both(run));
    });

    test('a scenario nobody wrote is still its own sentence', () async {
      final run = await _runMockApi();

      _expectClean(run);
      expect(run.stdout, contains('No API scenario named "default".'),
          reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });

    test('a scenario that will not resolve is still reported by resolve',
        () async {
      _write(
        'mock_api/scenarios/default.json',
        '{"name":"default","inherits":"missing","routes":{}}',
      );

      final run = await _runMockApi();

      _expectClean(run);
      expect(run.stdout, contains('ScenarioFormatException in '),
          reason: _both(run));
      expect(run.stdout, contains('missing.json: no such scenario'),
          reason: _both(run));
      expect(run.code, 2, reason: _both(run));
    });
  });
}
