// SUITE-OUT-UNUSABLE: `suite run` and an `--out` it cannot write into.
//
// ff3c323 gave `run` and `auth setup` one contract for `--out`: one that
// is a file, or sits under one, is refused before anything is looked
// at, and a write that fails anyway is reported at 2. `suite run`
// writes suite.json and suite.html on every outcome - a blocked one
// included, because CI wants an answer either way - through its own
// `_write`, which had neither. Measured at 26737da, offline, with no
// adb, so preflight blocks and the suite goes straight to writing:
//
//   suite run --out <a file>   preflight printed, then PathExistsException,
//                              a stack trace, exit 255
//
// The same check, from the same function, and the same guard.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _suiteRun(String out) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'suite',
      'run',
      '${_app.path}/suites/s.yaml',
      '--out',
      out,
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

void _expectNoCrash(Run run) {
  final both = '${run.stdout}${run.stderr}';
  expect(both, isNot(contains('Unhandled exception')), reason: both);
  expect(both, isNot(contains('package:flutter_testsmith')), reason: both);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('suite_out');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
    );
    _write(
      'suites/s.yaml',
      'suite: s\napp: {path: ..}\n'
      'device: {profile: p}\n'
      'tests:\n  - {id: home, flow: tests/home.yaml}\n',
    );
    _write('device_profiles/p.yaml', 'id: p\n');
    _write('blocker', 'a file, not a directory');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  test('an --out that is a file is refused before preflight', () async {
    final run = await _suiteRun('blocker');

    _expectNoCrash(run);
    expect(run.code, 2, reason: run.stdout);
    expect(run.stdout, contains('is a file'), reason: run.stdout);
    expect(run.stdout, isNot(contains('[BLOCK]')), reason: run.stdout);
  });

  test('an --out under a file is refused the same way', () async {
    final run = await _suiteRun('blocker/reports');

    _expectNoCrash(run);
    expect(run.code, 2, reason: run.stdout);
    expect(run.stdout, contains('is a file'), reason: run.stdout);
  });

  test('a write that fails anyway is reported, not a stack trace',
      () async {
    // Nothing rules the directory out, so it passes the check, and the
    // write is what fails: the name suite.json is taken by a directory.
    Directory('${_app.path}/taken/suite.json').createSync(recursive: true);

    final run = await _suiteRun('taken');

    _expectNoCrash(run);
    expect(run.code, 2, reason: run.stdout);
    expect(run.stdout, contains('[BLOCK]'), reason: run.stdout);
    expect(run.stdout, contains('could not be written'), reason: run.stdout);
  });

  test('control: a usable --out records the blocked suite', () async {
    final run = await _suiteRun('reports');

    _expectNoCrash(run);
    expect(run.code, 2, reason: run.stdout);
    expect(File('${_app.path}/reports/suite.json').existsSync(), isTrue,
        reason: run.stdout);
  });
}
