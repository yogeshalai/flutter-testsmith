// `testsmith preflight`, and the promise that a configuration mistake is a
// classified result rather than a crash.
//
// Driven through the real executable, because what is under test is an
// exit code and a message - neither of which a library call has. Measured
// before any of this existed: a malformed scenario file threw straight
// through `testsmith suite run`, which exited **255** with a stack trace. An
// environment problem reported as a crash is the exact failure mode E-04
// exists to remove.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> _mytest(List<String> arguments) => Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/testsmith.dart', ...arguments],
      workingDirectory: Directory.current.path,
    );

late Directory _root;

void _write(String path, String contents) {
  File('${_root.path}/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// A project with everything a suite needs except whatever the test breaks.
void _project() {
  _write('proj/device_profiles/p.yaml', 'id: p\n');
  _write(
    'proj/flows/a.yaml',
    'appId: com.example.app\nflow: a\nsteps:\n  - launchApp\n',
  );
  _write('proj/lib/main_mytest.dart', 'void main() {}');
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('preflight_cmd');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  test('no argument is a usage error', () async {
    final result = await _mytest(['preflight']);

    expect(result.exitCode, 64);
  });

  test('a missing suite file is exit 2, not a stack trace', () async {
    final result = await _mytest(['preflight', '${_root.path}/nope.yaml']);

    expect(result.exitCode, 2);
    expect(result.stdout, contains('No such suite file'));
    expect(result.stderr, isNot(contains('Unhandled exception')));
  });

  test('invalid suite syntax is exit 2, not a stack trace', () async {
    _project();
    _write('s.yaml', 'suite: s\ndevice: {profile: p}\ntests: []\n');

    final result = await _mytest(['preflight', '${_root.path}/s.yaml']);

    expect(result.exitCode, 2);
    expect(result.stderr, isNot(contains('Unhandled exception')));
  });

  test('a flow the suite names but does not have is exit 2', () async {
    _project();
    _write('s.yaml', '''
suite: s
app: {path: proj}
device: {profile: p}
tests:
  - {id: a, flow: flows/nowhere.yaml}
''');

    final result = await _mytest(['preflight', '${_root.path}/s.yaml']);

    expect(result.exitCode, 2);
    expect(result.stdout, contains('nowhere.yaml'));
    expect(result.stderr, isNot(contains('Unhandled exception')));
  });

  test('an unknown device profile is exit 2', () async {
    _project();
    _write('s.yaml', '''
suite: s
app: {path: proj}
device: {profile: not-a-profile}
tests:
  - {id: a, flow: flows/a.yaml}
''');

    final result = await _mytest(['preflight', '${_root.path}/s.yaml']);

    expect(result.exitCode, 2);
    expect(result.stdout, contains('not-a-profile'));
    expect(result.stderr, isNot(contains('Unhandled exception')));
  });

  test('a malformed scenario is a classified block, never a crash', () async {
    _project();
    _write('proj/mock_api/scenarios/default.json',
        '{"name": "default", "routes": []}');
    _write('s.yaml', '''
suite: s
app: {path: proj}
device: {profile: p}
mockApi: {port: 8080}
tests:
  - {id: a, flow: flows/a.yaml}
''');

    final result = await _mytest(
      ['preflight', '${_root.path}/s.yaml', '-d', 'no-such-device'],
    );

    expect(result.exitCode, 2);
    expect(result.stderr, isNot(contains('Unhandled exception')));
    expect(result.stderr, isNot(contains('ScenarioFormatException')));
    expect(result.stdout, contains('preflight'));
  });

  test('reports the device as blocked when the named one is not attached',
      () async {
    _project();
    _write('s.yaml', '''
suite: s
app: {path: proj}
device: {profile: p}
tests:
  - {id: a, flow: flows/a.yaml}
''');

    final result = await _mytest(
      ['preflight', '${_root.path}/s.yaml', '-d', 'no-such-device'],
    );

    expect(result.exitCode, 2);
    expect(result.stdout, contains('device'));
    expect(result.stderr, isNot(contains('Unhandled exception')));
  });
}
