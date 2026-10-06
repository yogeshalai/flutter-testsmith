// `testsmith impact`, and the coordinate system its paths are expressed in.
//
// Measured, in a temporary repository holding an application at
// `<repo>/example/app` - an arrangement so ordinary that Flutter's own
// package template produces it. Run from the repository root the command
// narrowed two flows to one. Run from the application directory, one step
// further in, it indexed `tests/home.yaml` while git reported
// `example/app/lib/home.dart`, matched nothing, and selected **every
// flow, every time**. The analyser was doing exactly what it should -
// nothing can be ruled out on evidence that does not parse - but the tool
// had silently stopped being a test-selection tool.
//
// The second half was worse and hid behind the first. `git ls-files
// --others` lists only what is under the directory it runs in, so from
// `example/app` the untracked file at the repository root never appeared
// in the change set at all. Not unmatched: absent. A new platform
// manifest, or a new screen, that nobody is told about.
//
// Driven through the real executable against real git, because what is
// under test is which directory two processes each believe paths start
// from, and neither a fake runner nor a library call has one.
@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

late Directory _root;

/// The repository root of the fixture.
String get _repo => '${_root.path}/repo';

/// The application inside it, one directory further in.
String get _app => '$_repo/example/app';

void _write(String path, String contents) {
  File('$_repo/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// A screen the indexer can attribute: a route, and an id a flow names.
///
/// Deliberately nothing that looks like application wiring - no `main`,
/// no `MaterialApp` - because a file with those reaches every screen and
/// would select the whole suite for reasons that have nothing to do with
/// what these measure.
const String _homeSource = '''
class HomeScreen {
  static const route = '/home';
  final title = TestKey('home.title');
}
''';

ProcessResult _git(List<String> arguments, {String? from}) => Process.runSync(
      'git',
      ['-C', from ?? _repo, ...arguments],
    );

/// A repository with an application in it, two flows, and two screens.
///
/// Nothing here is a convention the tool invented: a pubspec marks the
/// application, and everything else is this platform's own layout.
void _repository() {
  Directory(_app).createSync(recursive: true);
  _git(['init', '-q', '.']);
  _git(['config', 'user.email', 'test@example.com']);
  _git(['config', 'user.name', 'test']);

  _write('README.md', 'a repository\n');
  _write('example/app/pubspec.yaml', 'name: myapp\n');
  _write('example/app/lib/home.dart', _homeSource);
  _write(
    'example/app/lib/orders.dart',
    '''
class OrdersScreen {
  static const route = '/orders';
  final total = TestKey('orders.total');
}
''',
  );
  _write(
    'example/app/tests/home.yaml',
    'appId: com.acme.myapp\n'
    'flow: Home\n'
    'steps:\n'
    '  - expectScreen:\n'
    '      id: /home\n'
    '  - expectElement:\n'
    '      id: home.title\n',
  );
  _write(
    'example/app/tests/orders.yaml',
    'appId: com.acme.myapp\n'
    'flow: Orders\n'
    'steps:\n'
    '  - expectScreen:\n'
    '      id: /orders\n'
    '  - expectElement:\n'
    '      id: orders.total\n',
  );

  _git(['add', '-A']);
  _git(['commit', '-qm', 'init']);
}

/// Runs `testsmith impact --json` from [from] and returns the selection.
Future<Map<String, Object?>> _impact(
  List<String> arguments, {
  required String from,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'impact',
      '--json',
      ...arguments,
    ],
    workingDirectory: from,
  );

  final stdout = result.stdout as String;
  final start = stdout.indexOf('{');
  if (start < 0) {
    fail('impact printed no JSON.\nstdout: $stdout\nstderr: ${result.stderr}');
  }
  return (jsonDecode(stdout.substring(start)) as Map).cast<String, Object?>();
}

List<String> _selectedFlows(Map<String, Object?> selection) => [
      for (final flow in selection['selected']! as List)
        (flow as Map)['flow']! as String,
    ]..sort();

List<String> _selectedPaths(Map<String, Object?> selection) => [
      for (final flow in selection['selected']! as List)
        (flow as Map)['path']! as String,
    ]..sort();

void _writeBytes(String path, List<int> bytes) {
  File('$_repo/$path')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

/// [text] as UTF-16 LE with a byte-order mark.
///
/// What Notepad writes as "Unicode" and what PowerShell redirection
/// writes by default, so an editing session on this platform produces
/// one without anybody choosing an encoding. The mark is what makes it
/// undecodable: `FF FE` is not valid UTF-8.
List<int> _utf16leWithBom(String text) => [
      0xFF,
      0xFE,
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];

/// [text] as UTF-8 with a byte-order mark, which Dart strips on read.
List<int> _utf8WithBom(String text) =>
    [0xEF, 0xBB, 0xBF, ...utf8.encode(text)];

/// [output] is stdout and stderr together, for what must appear in
/// neither; [out] is stdout alone, because the JSON selection is
/// printed there and `jsonDecode` will not accept stderr trailing it.
typedef Run = ({String output, String out, int code});

/// `testsmith impact --json`, kept whole.
///
/// [_impact] fails the test when no JSON is printed, which is the right
/// answer for the selections above and the wrong one here: what a file
/// the indexer cannot read must produce is an advisory line *and* a
/// selection, and both have to be read from the same run.
Future<Run> _impactRaw(
  List<String> arguments, {
  required String from,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'impact',
      '--json',
      ...arguments,
    ],
    workingDirectory: from,
  );
  return (
    output: '${result.stdout}${result.stderr}',
    out: result.stdout as String,
    code: result.exitCode,
  );
}

Map<String, Object?> _selectionIn(Run run) {
  final start = run.out.indexOf('{');
  if (start < 0) fail('impact printed no JSON.\n${run.output}');
  return (jsonDecode(run.out.substring(start)) as Map).cast<String, Object?>();
}

/// What a file the indexer cannot read must do, whichever directory it
/// is in: be named, be left out, and leave the rest of the index alone.
void expectReportedAndSkipped(Run run, String name) {
  expect(run.output, isNot(contains('Unhandled exception')), reason: run.output);
  expect(run.output, isNot(contains('#0 ')), reason: run.output);
  // The trace carried this tool's own install path and not a word about
  // the project's file; the advisory line must do the opposite.
  expect(run.output, isNot(contains('file:///')), reason: run.output);
  expect(run.output, contains('ignoring'), reason: run.output);
  expect(run.output, contains(name), reason: run.output);
  expect(run.code, 0, reason: run.output);
}

bool _gitIsAvailable() {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  final skip = _gitIsAvailable()
      ? null
      : 'git is not on PATH, and these measure what git reports';

  setUp(() {
    _root = Directory.systemTemp.createTempSync('impact_coords');
    addTearDown(() {
      // A fresh git repository on Windows leaves read-only objects that
      // refuse an ordinary delete.
      try {
        _root.deleteSync(recursive: true);
      } on FileSystemException {
        // A leftover temporary directory is not worth failing a run over.
      }
    });
    _repository();
    // One tracked file modified, so every case below has the same change
    // to reason about however it is asked for.
    _write('example/app/lib/home.dart', '// touched\n$_homeSource');
  });

  group('the same change selects the same flows', () {
    test('from the repository root', () async {
      final selection = await _impact(
        ['--app', 'example/app', '--changed', 'example/app/lib/home.dart'],
        from: _repo,
      );

      expect(selection['fullSuite'], isFalse);
      expect(_selectedFlows(selection), ['Home']);
      expect(selection['skipped'], ['Orders']);
    });

    test('from a directory nested inside it', () async {
      // The regression. This selected both flows, for as long as anyone
      // ran it from the application they were working in.
      final selection = await _impact(
        ['--changed', 'example/app/lib/home.dart'],
        from: _app,
      );

      expect(selection['fullSuite'], isFalse,
          reason: 'the index and git must agree on where a path starts');
      expect(_selectedFlows(selection), ['Home']);
      expect(selection['skipped'], ['Orders']);
    });

    test('from outside the repository, with --app naming the application',
        () async {
      final outside = Directory('${_root.path}/outside')..createSync();

      final selection = await _impact(
        ['--app', _app, '--changed', 'example/app/lib/home.dart'],
        from: outside.path,
      );

      expect(selection['fullSuite'], isFalse);
      expect(_selectedFlows(selection), ['Home']);
    });
  }, skip: skip);

  group('the paths a selection reports', () {
    test('are relative to the repository, wherever it was run', () async {
      // The negative control for the rule above. `tests/home.yaml` is
      // what the old code produced from the application directory: a
      // perfectly plausible path that matches nothing git ever says.
      final fromRoot = await _impact(
        ['--app', 'example/app', '--changed', 'example/app/lib/home.dart'],
        from: _repo,
      );
      final fromNested = await _impact(
        ['--changed', 'example/app/lib/home.dart'],
        from: _app,
      );

      expect(_selectedPaths(fromRoot), ['example/app/tests/home.yaml']);
      expect(_selectedPaths(fromNested), ['example/app/tests/home.yaml']);
      expect(_selectedPaths(fromNested), isNot(contains('tests/home.yaml')));
    });
  }, skip: skip);

  group('narrowing stays honest', () {
    test('an unrelated change selects only its own flow', () async {
      final selection = await _impact(
        ['--changed', 'example/app/lib/orders.dart'],
        from: _app,
      );

      expect(_selectedFlows(selection), ['Orders']);
      expect(selection['skipped'], ['Home']);
    });

    test('a file the index cannot account for still selects everything',
        () async {
      // Normalising paths must not turn "I do not know what this is" into
      // a narrowing. The fail-safe is the whole design.
      final selection = await _impact(
        ['--changed', 'example/app/lib/mystery.dart'],
        from: _app,
      );

      expect(selection['fullSuite'], isTrue);
      expect(_selectedFlows(selection), ['Home', 'Orders']);
    });

    test('documentation alone selects nothing, from either directory',
        () async {
      for (final from in [_repo, _app]) {
        final selection = await _impact(
          ['--app', _app, '--changed', 'docs/notes.md'],
          from: from,
        );

        expect(selection['selected'], isEmpty, reason: 'run from $from');
        expect(selection['fullSuite'], isFalse, reason: 'run from $from');
      }
    });
  }, skip: skip);

  group('the change set git is asked for', () {
    test('includes untracked files elsewhere in the repository', () async {
      // The silent half. From the application directory these two never
      // appeared at all - `git ls-files --others` lists only what is
      // below where it runs - so a brand new platform manifest was not
      // reported as unmatched, it was reported as nothing.
      _write('android/AndroidManifest.xml', '<manifest/>\n');
      _write('sibling_new.dart', '// new\n');

      final fromNested = await _impact(const ['--since', 'HEAD'], from: _app);
      final changed = (fromNested['changed']! as List).cast<String>();

      expect(changed, contains('android/AndroidManifest.xml'));
      expect(changed, contains('sibling_new.dart'));
      expect(changed, contains('example/app/lib/home.dart'));
    });

    test('is the same set wherever the command was run', () async {
      _write('android/AndroidManifest.xml', '<manifest/>\n');

      final fromRoot = await _impact(
        const ['--app', 'example/app', '--since', 'HEAD'],
        from: _repo,
      );
      final fromNested = await _impact(const ['--since', 'HEAD'], from: _app);

      expect(fromNested['changed'], fromRoot['changed']);
      // And a new platform directory is still a reason to run everything.
      expect(fromNested['fullSuite'], isTrue);
      expect(fromRoot['fullSuite'], isTrue);
    });
  }, skip: skip);

  // A project file that is valid text in the wrong encoding.
  //
  // `_eachFile` reads every file and hands the contents to a callback,
  // and each of those callbacks already reports what it cannot use
  // through `onProblem` and carries on indexing. The read itself sat
  // outside all of them, so `readAsStringSync` refusing to decode - a
  // `FileSystemException`, which is not a `FormatException` and so not
  // what any of those guards catches - ended the command instead of
  // being reported by the channel built for exactly this.
  //
  // Five directories go through that one line, which is why all five
  // are here. `lib` is the one worth noticing: it is not configuration
  // at all, just a source file in the application under test.
  //
  // Measured at 13da861 on each: exit 255, an unhandled exception,
  // seven frames, and a `file:///` path in the trace while the
  // project's own file was named nowhere.
  group('a project file the indexer cannot decode', () {
    for (final path in const [
      'example/app/tests/broken.yaml',
      'example/app/lib/broken.dart',
      'example/app/mappings/broken.yaml',
      'example/app/figma/broken.json',
      'example/app/visual_baselines/broken.json',
    ]) {
      test('$path is named and left out', () async {
        _writeBytes(path, _utf16leWithBom('screen: /home\n'));

        final run = await _impactRaw(
          const ['--changed', 'example/app/lib/home.dart'],
          from: _app,
        );

        expectReportedAndSkipped(run, path.split('/').last);
        // And the rest of the project was still indexed: the same change
        // still narrows to the same flow it does without this file.
        final selection = _selectionIn(run);
        expect(selection['fullSuite'], isFalse, reason: run.output);
        expect(_selectedFlows(selection), ['Home'], reason: run.output);
      });
    }
  }, skip: skip);

  group('what skipping it must not change', () {
    test('a project whose files all decode says nothing and selects',
        () async {
      // The control. Without it every assertion above would also hold
      // for an indexer that had quietly stopped reading these
      // directories.
      _write('example/app/mappings/home.yaml', 'screen: /home\n');
      _write(
        'example/app/figma/home.json',
        '{"screen":"/home","nodeId":"1:1","figmaName":"Home",'
        '"width":400.0,"height":800.0,"elements":[],"totalNodesWalked":1}',
      );
      _write(
        'example/app/visual_baselines/home.json',
        '{"screen":"/home","width":720,"height":1600}',
      );

      final run = await _impactRaw(
        const ['--changed', 'example/app/lib/home.dart'],
        from: _app,
      );

      expect(run.output, isNot(contains('ignoring')), reason: run.output);
      expect(run.code, 0, reason: run.output);
      final selection = _selectionIn(run);
      expect(selection['fullSuite'], isFalse, reason: run.output);
      expect(_selectedFlows(selection), ['Home'], reason: run.output);
    });

    test('a byte-order mark on a UTF-8 flow is still indexed', () async {
      // Dart strips this one, and must keep doing so. Asserted by the
      // flow turning up in the selection rather than merely by nothing
      // being reported: that is the difference between "read" and
      // "silently skipped".
      _writeBytes(
        'example/app/tests/bom.yaml',
        _utf8WithBom(
          'appId: com.acme.myapp\n'
          'flow: BomFlow\n'
          'steps:\n'
          '  - expectScreen:\n'
          '      id: /home\n'
          '  - expectElement:\n'
          '      id: home.title\n',
        ),
      );

      final run = await _impactRaw(
        const ['--changed', 'example/app/lib/home.dart'],
        from: _app,
      );

      expect(run.output, isNot(contains('ignoring')), reason: run.output);
      expect(_selectedFlows(_selectionIn(run)), ['BomFlow', 'Home'],
          reason: run.output);
    });

    test('a flow that decodes but will not parse still says why', () async {
      // The guard beside the new one. A file that reads perfectly well
      // and is not a flow must keep reaching `FlowFormatException` and
      // keep its own sentence: a typo and an encoding are different
      // things to go and fix.
      _write(
        'example/app/tests/bad.yaml',
        'appId: 5\nflow: Bad\nsteps:\n  - launchApp\n',
      );

      final run = await _impactRaw(
        const ['--changed', 'example/app/lib/home.dart'],
        from: _app,
      );

      expectReportedAndSkipped(run, 'bad.yaml');
      expect(run.output, contains('"appId" is required'), reason: run.output);
    });
  }, skip: skip);
}
