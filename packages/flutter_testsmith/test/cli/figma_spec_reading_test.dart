// A file in `<app>/figma` that is not a design, through the commands.
//
// `loadFigmaSpecs` has always said what happens to a spec it cannot
// read - report it through `onProblem` and skip it, because a file that
// describes no screen takes nothing away from another - and it catches
// `FormatException` to do that.
//
// The schema underneath was read with `!` and `as`, so a document that
// was valid JSON and not a spec raised a `TypeError` instead. That is
// not a `FormatException`, and not an `Exception` at all, so it walked
// past the guard, past `bin/testsmith.dart` (which catches
// `UsageException` and nothing else) and ended the process. Measured on
// one project with `{"a": 1}` in `<app>/figma`:
//
//   testsmith run        Unhandled exception: Null check operator ...  255
//   testsmith suite run  Unhandled exception: Null check operator ...  255
//   testsmith preflight  Unhandled exception: Null check operator ...  255
//
// `preflight` acquired it at 636c690, which is when it started reading
// the directory at all; `run` and `suite run` had it already.
//
// Offline throughout, and deliberately with no device: the fake adb
// below reports one handset and every command is pointed at a different
// serial, so each one reaches the design directory and then stops for a
// reason that is the same on every machine.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

const String _attached = 'FAKESERIAL1';
const String _requested = 'NOSUCHDEVICE';

/// A document that is valid JSON and describes no screen.
const String _stray = '{"a": 1}';

String _spec(String screen, String name) => jsonEncode({
      'screen': screen,
      'nodeId': '1:1',
      'figmaName': name,
      'width': 400.0,
      'height': 800.0,
      'elements': const <Object>[],
      'totalNodesWalked': 1,
    });

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// An adb that reports one attached device and nothing else.
///
/// The same instrument `fixture_server_startup_test` uses, and for the
/// same reason: `MYTEST_ADB` is the operator contract `resolveAdb`
/// already honours, so reaching device-gated code needs no hardware and
/// no change to discovery.
String _fakeAdb() {
  final directory = Directory('${_root.path}/bin')..createSync(recursive: true);
  if (Platform.isWindows) {
    final file = File('${directory.path}/adb.bat')
      ..writeAsStringSync(
        '@echo off\r\n'
        'echo List of devices attached\r\n'
        'echo $_attached            device product:fake model:Fake '
        'device:fake\r\n',
      );
    return file.path;
  }
  final file = File('${directory.path}/adb')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'echo "List of devices attached"\n'
      'echo "$_attached            device product:fake model:Fake device:fake"\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

typedef Run = ({String output, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {'MYTEST_ADB': _fakeAdb()},
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

/// What reading a design directory must never do, whichever command did
/// it.
void expectSurvived(Run run) {
  expect(run.output, isNot(contains('Unhandled exception')), reason: run.output);
  expect(run.output, isNot(contains('Null check operator')),
      reason: run.output);
  expect(run.code, isNot(255), reason: run.output);
}

/// The advisory line the loader already emits for a spec it skipped.
void expectReported(Run run, String file) {
  expect(run.output, contains('ignoring'), reason: run.output);
  expect(run.output, contains(file), reason: run.output);
}

/// The same, for a root that is not an object at all.
///
/// A superset of [expectSurvived]: that one was written when the only
/// escape was a `Null check operator`, and this shape left a cast error
/// with a stack behind it instead. The two extra readings are what the
/// crash actually put in front of somebody - frames, and this tool's own
/// install path - neither of which says anything about their project.
void expectRefusedNotCrashed(Run run, {required int code}) {
  expectSurvived(run);
  expect(run.output, isNot(contains(RegExp(r'^#\d', multiLine: true))),
      reason: run.output);
  expect(run.output, isNot(contains('file:///')), reason: run.output);
  expect(run.output, contains('stray.json'), reason: run.output);
  expect(run.code, code, reason: run.output);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('figma_spec_reading');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
    );
    _write(
      'suites/s.yaml',
      'suite: s\napp: {path: .., target: lib/main_mytest.dart}\n'
      'device: {profile: p}\n'
      'tests:\n  - {id: home, flow: tests/home.yaml}\n',
    );
    _write(
      'device_profiles/p.yaml',
      'id: p\nmodel: Fake\nos: Android 13\n'
      'physical:\n  width: 720\n  height: 1600\n'
      'devicePixelRatio: 1.875\norientation: portrait\nbuildMode: debug\n',
    );
    _write('figma/home.json', _spec('/home', 'Home'));
    _write('figma/stray.json', _stray);
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  test('testsmith run reports it and carries on', () async {
    final run = await _testsmith(
      ['run', '${_app.path}/tests/home.yaml', '--app', _app.path,
        '-d', _requested],
    );

    expectSurvived(run);
    expectReported(run, 'stray.json');
    // It got past the designs: the run ended at the device it was told
    // to use, which is the next thing it does.
    expect(run.output, contains(_requested), reason: run.output);
  });

  test('testsmith suite run reports it and carries on', () async {
    final run = await _testsmith(
      ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _requested],
    );

    expectSurvived(run);
    expectReported(run, 'stray.json');
    expect(run.output, contains('preflight'), reason: run.output);
  });

  test('testsmith preflight finishes its report', () async {
    final run = await _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _requested],
    );

    expectSurvived(run);
    // Every check still ran and the verdict was still reached. The
    // directory is read by the screen-configuration check, which is the
    // one that would have died reading it.
    expect(run.output, contains('screen configuration'), reason: run.output);
    expect(run.output, contains('authentication'), reason: run.output);
  });

  test('and the design it could not read blocks nothing', () async {
    // The severity that must not move. A malformed spec is advisory;
    // only two *readable* files claiming one screen is fatal. Asserted
    // on the check's own row rather than on the exit code, because the
    // device this is pointed at is deliberately not there.
    //
    // R16 moved the row from `[ok]` to `[note]`, which is not a change of
    // severity - a notice blocks nothing and the exit code is the same -
    // but of honesty. `[ok] one configuration per screen` was an
    // affirmative about a directory holding a file nobody could read.
    final run = await _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _requested],
    );

    expect(
      run.output,
      contains(RegExp(r'\[note\]\s+screen configuration')),
      reason: run.output,
    );
    expect(run.output, isNot(contains(RegExp(r'\[BLOCK\]\s+screen config'))),
        reason: run.output);
    expect(run.output.toLowerCase(), isNot(contains('duplicate')),
        reason: run.output);
  });

  test('preflight names the design it skipped', () async {
    // R16. `run` and `suite run` have printed this line since c9c4532;
    // preflight read the same directory through the same loader and
    // discarded the report, so the one command whose entire output is a
    // report said nothing about it at all.
    final run = await _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _requested],
    );

    expect(run.output, contains('stray.json'), reason: run.output);
    // The file name, not the absolute path: a preflight row is one
    // column-aligned line.
    expect(run.output, isNot(contains('! ignoring ')), reason: run.output);
  });

  test('a blocked suite carries the skipped design into suite.json',
      () async {
    // Machine-readable, for the same reason M-1 gives: a gate reads the
    // report rather than the terminal, and an advisory nobody can parse
    // is an advisory nobody acts on.
    final run = await _testsmith(
      ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _requested],
    );

    expectSurvived(run);
    final file = File('${_app.path}/out/suite/suite.json');
    expect(file.existsSync(), isTrue, reason: run.output);

    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final checks = (json['preflight']! as Map<String, Object?>)['checks']!
        as List<Object?>;
    final row = checks
        .cast<Map<String, Object?>>()
        .firstWhere((c) => c['name'] == 'screen configuration');

    expect(row['outcome'], 'notice', reason: '$json');
    expect(row['detail'], contains('stray.json'), reason: '$json');
  });

  test('a project whose designs all read keeps the plain affirmative',
      () async {
    // The control. Without it every assertion above would also hold for
    // a row that had simply stopped saying [ok].
    File('${_app.path}/figma/stray.json').deleteSync();

    final run = await _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _requested],
    );

    expect(
      run.output,
      contains(RegExp(r'\[ok\]\s+screen configuration')),
      reason: run.output,
    );
    expect(run.output, contains('one configuration per screen'),
        reason: run.output);
  });

  test('while two readable designs for one screen still block', () async {
    // The other half of the same rule, in the same project: the stray
    // file is still there, and the blocker is the pair that can be read.
    _write('figma/home_again.json', _spec('/home', 'Home again'));

    final run = await _testsmith(
      ['preflight', '${_app.path}/suites/s.yaml', '-d', _requested],
    );

    expectSurvived(run);
    expect(
      run.output,
      contains(RegExp(r'\[BLOCK\]\s+screen configuration')),
      reason: run.output,
    );
    expect(run.output, contains('home.json'), reason: run.output);
    expect(run.output, contains('home_again.json'), reason: run.output);
    expect(run.code, 2, reason: run.output);
  });

  test('a mapping that will not parse is still refused outright', () async {
    // Unchanged, and the contrast worth keeping: a malformed *mapping*
    // is fatal to a run and always has been. Only designs are advisory.
    _write('mappings/home.yaml', 'screen: [this is not a screen\n');

    final run = await _testsmith(
      ['run', '${_app.path}/tests/home.yaml', '--app', _app.path,
        '-d', _requested],
    );

    expect(run.output, contains('MappingsFormatException'), reason: run.output);
    expect(run.code, 2, reason: run.output);
  });

  // A design that is valid JSON and whose root is not an object.
  //
  // The third shape, and the one nothing in this repository ever wrote.
  // Every malformed fixture above is one of two kinds: text that is not
  // JSON, which `jsonDecode` refuses with a `FormatException`, or a JSON
  // *object* that is not a spec, which `FigmaScreenSpec.fromJson`
  // refuses with a `FormatException`. The loader catches that type and
  // reports, so both are advisory and both name the file.
  //
  // A document whose root is a list, a string, a number, a boolean or
  // null satisfies `jsonDecode` and then fails `as Map` - a `TypeError`,
  // which is not a `FormatException` and not an `Exception` at all, so
  // it walked past the guard that catches the other two and past
  // `bin/testsmith.dart`, which catches `UsageException` and nothing
  // else.
  //
  // Measured against 450104e on every root below: exit 255, an unhandled
  // exception, four to six frames, the offending file named nowhere, and
  // `file:///...` - this tool's own install path, not the project's - in
  // the trace.
  group('a design whose JSON root is not an object', () {
    for (final root in const [
      '[]',
      '[1,2,3]',
      '"a string"',
      '42',
      'true',
      'null',
    ]) {
      test('$root through run', () async {
        _write('figma/stray.json', root);

        final run = await _testsmith(
          ['run', '${_app.path}/tests/home.yaml', '--app', _app.path,
            '-d', _requested],
        );

        // 2 since RUN-ENV-EXIT: it ends at the device, not at the design.
        expectRefusedNotCrashed(run, code: 2);
        expectReported(run, 'stray.json');
        // It got past the designs: the run ended at the device it was
        // told to use, exactly as the object above it does.
        expect(run.output, contains(_requested), reason: run.output);
      });

      test('$root through suite run', () async {
        _write('figma/stray.json', root);

        final run = await _testsmith(
          ['suite', 'run', '${_app.path}/suites/s.yaml', '-d', _requested],
        );

        expectRefusedNotCrashed(run, code: 2);
        expectReported(run, 'stray.json');
      });

      test('$root through preflight', () async {
        _write('figma/stray.json', root);

        final run = await _testsmith(
          ['preflight', '${_app.path}/suites/s.yaml', '-d', _requested],
        );

        expectRefusedNotCrashed(run, code: 2);
        // The severity that must not move. A design that cannot be read
        // is advisory whatever shape it is; only two *readable* files
        // claiming one screen is fatal.
        expect(
          run.output,
          contains(RegExp(r'\[note\]\s+screen configuration')),
          reason: run.output,
        );
      });
    }
  });

  // The second reader of the same directories. `impact` does not go
  // through `loadFigmaSpecs` at all: `ProjectIndexer` reads
  // `<app>/figma` and `<app>/visual_baselines` itself, for the screen
  // each file names, through a cast of its own and behind a guard of the
  // same shape. It needs neither git nor a device to get there, because
  // `--changed` supplies the change set.
  group('and the index impact builds from the same directories', () {
    test('a design whose root is not an object is reported, not fatal',
        () async {
      _write('figma/stray.json', '[]');

      final run = await _testsmith(
        ['impact', '--app', _app.path, '--changed', 'lib/main.dart'],
      );

      expectRefusedNotCrashed(run, code: 0);
    });

    test('and so is a visual baseline whose root is not an object',
        () async {
      // The other directory the indexer reads, and the one no other
      // test in this file touches. A baseline names its own screen,
      // which is why it is indexed beside the designs.
      _write('visual_baselines/home.json', 'null');

      final run = await _testsmith(
        ['impact', '--app', _app.path, '--changed', 'lib/main.dart'],
      );

      expectSurvived(run);
      expect(run.output, isNot(contains(RegExp(r'^#\d', multiLine: true))),
          reason: run.output);
      expect(run.output, isNot(contains('file:///')), reason: run.output);
      expect(run.output, contains('home.json'), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });

    test('while a readable project still indexes and selects', () async {
      // The control. Without it the two above would also hold for an
      // indexer that had quietly stopped reading either directory.
      _write('visual_baselines/home.json',
          '{"screen": "/home", "width": 720, "height": 1600}');

      final run = await _testsmith(
        ['impact', '--app', _app.path, '--changed', 'lib/main.dart'],
      );

      expectSurvived(run);
      expect(run.output, isNot(contains('ignoring')), reason: run.output);
      expect(run.code, 0, reason: run.output);
    });
  });
}
