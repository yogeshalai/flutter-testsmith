// The CI contract E-03 established, held to through E-04's rewiring.
//
// `testsmith suite run` now resolves its suite through the same code
// `testsmith preflight` does, and runs a preflight before starting anything.
// None of that may change what the command returns, because an exit code
// is the whole of what CI reads: 0 passed, 1 the application is wrong, 2
// the run is wrong, 64 the invocation is wrong.
//
// Driven through the real executable, because an exit code is not
// something a library call has.
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

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('suite_exit');
    addTearDown(() => _root.deleteSync(recursive: true));

    _write('proj/device_profiles/p.yaml', 'id: p\n');
    _write(
      'proj/flows/a.yaml',
      'appId: com.example.app\nflow: a\nsteps:\n  - launchApp\n',
    );
    _write('proj/lib/main_mytest.dart', 'void main() {}');
  });

  test('no argument is 64', () async {
    expect((await _mytest(['suite', 'run'])).exitCode, 64);
  });

  test('more than one argument is 64', () async {
    expect((await _mytest(['suite', 'run', 'a.yaml', 'b.yaml'])).exitCode, 64);
  });

  test('no such suite file is 2', () async {
    final result = await _mytest(['suite', 'run', '${_root.path}/nope.yaml']);

    expect(result.exitCode, 2);
    expect(result.stdout, contains('No such suite file'));
  });

  test('invalid syntax is 2', () async {
    _write('s.yaml', 'suite: s\ndevice: {profile: p}\ntests: []\n');

    final result = await _mytest(['suite', 'run', '${_root.path}/s.yaml']);

    expect(result.exitCode, 2);
    expect(result.stderr, isNot(contains('Unhandled exception')));
  });

  test('an unknown key is 2, because a typo that does nothing is worse than '
      'a refusal', () async {
    _write('s.yaml', '''
suite: s
app: {path: proj}
device: {profile: p}
tests:
  - {id: a, flow: flows/a.yaml, reste: clearState}
''');

    final result = await _mytest(['suite', 'run', '${_root.path}/s.yaml']);

    expect(result.exitCode, 2);
  });

  test('a missing flow is 2', () async {
    _write('s.yaml', '''
suite: s
app: {path: proj}
device: {profile: p}
tests:
  - {id: a, flow: flows/nowhere.yaml}
''');

    final result = await _mytest(['suite', 'run', '${_root.path}/s.yaml']);

    expect(result.exitCode, 2);
    expect(result.stdout, contains('nowhere.yaml'));
  });

  test('a device that is not attached is 2, and nothing is launched',
      () async {
    _write('s.yaml', '''
suite: s
app: {path: proj}
device: {profile: p}
tests:
  - {id: a, flow: flows/a.yaml}
''');

    final result = await _mytest(
      ['suite', 'run', '${_root.path}/s.yaml', '-d', 'no-such-device',
       '--out', '${_root.path}/out'],
    );

    expect(result.exitCode, 2);
    expect(result.stderr, isNot(contains('Unhandled exception')));
  });

  test('a blocked environment still writes a machine-readable report',
      () async {
    // CI wants an answer either way, and "we could not test it" is an
    // answer. A blocked run that wrote nothing would be indistinguishable
    // from a run that never happened.
    _write('s.yaml', '''
suite: s
app: {path: proj}
device: {profile: p}
tests:
  - {id: a, flow: flows/a.yaml}
''');

    final result = await _mytest(
      ['suite', 'run', '${_root.path}/s.yaml', '-d', 'no-such-device',
       '--out', '${_root.path}/out'],
    );

    expect(result.exitCode, 2);
    final report = File('${_root.path}/out/suite.json');
    expect(report.existsSync(), isTrue);

    final json = report.readAsStringSync();
    expect(json, contains('"blocked": true'));
    expect(json, contains('"classification": "environment"'));
    expect(json, contains('"fail": 0'));
    expect(File('${_root.path}/out/suite.html').existsSync(), isTrue);
  });
}
