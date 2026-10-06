// Two files, one screen.
//
// `mappings/` and `figma/` are directories of files, each naming the
// screen it describes; a run wants one configuration per screen. The two
// loaders reconciled that with a map write and nothing else:
//
//     loaded[file.screen] = file;
//     loaded[spec.screen] = spec;
//
// so a second file for a screen replaced the first, silently, and which
// one survived was decided by `Directory.listSync()` order. Measured
// before this file existed:
//
//   mappings/ holds a_home.yaml and z_home.yaml, both `screen: /home`
//     loadMappings returned 1 entry, mapping to t.z, nothing reported
//   figma/ holds a_home.json and z_home.json, both "screen": "/home"
//     loadFigmaSpecs returned 1 entry, z_home, nothing reported
//
// Listing order is not specified by dart:io and is not the same on every
// filesystem, so one project could validate against two different
// configurations on two machines and report success on both.
//
// This repository does not guess between candidates elsewhere:
// `selectSoleDevice` refuses to pick one of several devices, and
// duplicate test ids in a snapshot are surfaced and fail `inspect`. A
// screen described twice is the same question about configuration.
//
// Fatal, not advisory - and the distinction is carried by type, because
// a malformed spec must stay the warning it already is.
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/project_config.dart';

late Directory _root;
late Directory _app;

String _spec(String screen, String name) => jsonEncode({
      'screen': screen,
      'nodeId': '1:1',
      'figmaName': name,
      'width': 400.0,
      'height': 800.0,
      'elements': const <Object>[],
      'totalNodesWalked': 1,
    });

String _mapping(String screen, String target) =>
    'screen: $screen\nmappings:\n  - {target: $target, source: response.a}\n';

void _write(String relative, String contents) {
  final file = File('${_app.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// The CLI source, for the assertions that can only be made there.
String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

typedef Run = ({String output, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('dup_screen');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('two mappings for one screen', () {
    test('is refused, naming the screen and both files', () async {
      _write('mappings/a_home.yaml', _mapping('/home', 't.a'));
      _write('mappings/z_home.yaml', _mapping('/home', 't.z'));

      await expectLater(
        loadMappings(_app),
        throwsA(isA<DuplicateScreenException>()
            .having((e) => e.screen, 'screen', '/home')
            .having((e) => '$e', 'message', contains('a_home.yaml'))
            .having((e) => '$e', 'message', contains('z_home.yaml'))),
      );
    });

    test('and neither file is chosen over the other', () async {
      // The failure this replaces picked one. Nothing in the message may
      // read as a decision about which configuration is the right one.
      _write('mappings/a_home.yaml', _mapping('/home', 't.a'));
      _write('mappings/z_home.yaml', _mapping('/home', 't.z'));

      try {
        await loadMappings(_app);
        fail('expected a DuplicateScreenException');
      } on DuplicateScreenException catch (error) {
        expect(error.paths, hasLength(2));
        expect('$error', isNot(contains('t.a')));
        expect('$error', isNot(contains('t.z')));
      }
    });

    test('one mapping per screen is untouched', () async {
      _write('mappings/home.yaml', _mapping('/home', 't.a'));
      _write('mappings/cart.yaml', _mapping('/cart', 't.b'));

      final mappings = await loadMappings(_app);

      expect(mappings.keys.toSet(), {'/home', '/cart'});
    });

    test('and a directory that is not there is still empty, not a failure',
        () async {
      expect(await loadMappings(_app), isEmpty);
    });
  });

  group('two specs for one screen', () {
    test('is refused, naming the screen and both files', () async {
      _write('figma/a_home.json', _spec('/home', 'A'));
      _write('figma/z_home.json', _spec('/home', 'Z'));

      await expectLater(
        loadFigmaSpecs(_app),
        throwsA(isA<DuplicateScreenException>()
            .having((e) => e.screen, 'screen', '/home')
            .having((e) => '$e', 'message', contains('a_home.json'))
            .having((e) => '$e', 'message', contains('z_home.json'))),
      );
    });

    test('one spec per screen is untouched', () async {
      _write('figma/home.json', _spec('/home', 'Home'));
      _write('figma/cart.json', _spec('/cart', 'Cart'));

      final specs = await loadFigmaSpecs(_app);

      expect(specs.keys.toSet(), {'/home', '/cart'});
    });

    test('a malformed spec is still a warning, not a failure', () async {
      // The severity that must not move. A spec that cannot be parsed
      // describes no screen, so it conflicts with nothing; it is
      // reported and the rest still load.
      _write('figma/home.json', _spec('/home', 'Home'));
      _write('figma/broken.json', '{ this is not json');

      final problems = <String>[];
      final specs = await loadFigmaSpecs(_app, onProblem: problems.add);

      expect(specs.keys, ['/home']);
      expect(problems, hasLength(1));
      expect(problems.single, contains('broken.json'));
      expect(problems.single, contains('ignoring'));
    });

    test('and a malformed spec never reads as a duplicate', () async {
      _write('figma/broken.json', '{ this is not json');

      final problems = <String>[];
      await loadFigmaSpecs(_app, onProblem: problems.add);

      expect(problems.single.toLowerCase(), isNot(contains('duplicate')));
    });

    test('and so is a document that is valid JSON but not a spec', () async {
      // The same severity, reached the other way. `{ this is not json`
      // fails in `jsonDecode`, which raises a FormatException and was
      // always caught. A document that parses as JSON and then turns out
      // to describe no screen reached the schema, which was read with
      // `!` and `as` - a TypeError, which is not an Exception at all, so
      // it walked past the guard above and ended the process at 255.
      _write('figma/home.json', _spec('/home', 'Home'));
      _write('figma/stray.json', '{"a": 1}');

      final problems = <String>[];
      final specs = await loadFigmaSpecs(_app, onProblem: problems.add);

      expect(specs.keys, ['/home']);
      expect(problems.single, contains('stray.json'));
      expect(problems.single, contains('ignoring'));
      expect(problems.single.toLowerCase(), isNot(contains('duplicate')));
    });

    test('and so is a spec whose fields are the wrong type', () async {
      _write('figma/home.json', _spec('/home', 'Home'));
      _write(
        'figma/wide.json',
        _spec('/cart', 'Cart').replaceFirst('"width":400.0', '"width":"400"'),
      );

      final problems = <String>[];
      final specs = await loadFigmaSpecs(_app, onProblem: problems.add);

      expect(specs.keys, ['/home']);
      expect(problems.single, contains('wide.json'));
      expect(problems.single, contains('width'));
    });

    test('and a screen is only claimed by a file that could be read',
        () async {
      // The interaction with the rule above it: an unreadable file
      // describes no screen, so it cannot make one ambiguous. Two files
      // naming /home where one of them will not read is one
      // configuration, not a duplicate.
      _write('figma/home.json', _spec('/home', 'Home'));
      _write('figma/home_old.json', '{"screen": "/home"}');

      final problems = <String>[];
      final specs = await loadFigmaSpecs(_app, onProblem: problems.add);

      expect(specs.keys, ['/home']);
      expect(specs['/home']!.figmaName, 'Home');
      expect(problems.single, contains('home_old.json'));
    });
  });

  group('the commands do not proceed with an ambiguous configuration', () {
    test('testsmith run reports the duplicate and fails', () async {
      // End to end, and offline: mappings load before any device is
      // chosen, so this reaches the real failure with no hardware.
      _write('mappings/a_home.yaml', _mapping('/home', 't.a'));
      _write('mappings/z_home.yaml', _mapping('/home', 't.z'));
      _write(
        'tests/home.yaml',
        'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
      );

      final run = await _testsmith(
        ['run', '${_app.path}/tests/home.yaml', '--app', _app.path],
      );

      expect(run.code, isNot(0), reason: run.output);
      expect(run.output, contains('/home'), reason: run.output);
      expect(run.output, contains('a_home.yaml'), reason: run.output);
      expect(run.output, contains('z_home.yaml'), reason: run.output);
      expect(run.output, isNot(contains('Unhandled exception')),
          reason: run.output);
    });

    test('and testsmith suite run is wired to do the same', () {
      // Only assertable in the source. `suite run` reaches its preflight
      // - which requires an attached device - before it loads mappings,
      // so the behaviour above cannot be driven offline for a suite.
      // This is the same instrument `suite_secret_parity_test` uses for
      // the same reason.
      final suite =
          _source('flutter_testsmith/lib/src/cli/commands/suite_command.dart');
      final run =
          _source('flutter_testsmith/lib/src/cli/commands/run_command.dart');

      for (final source in {'suite': suite, 'run': run}.entries) {
        expect(
          source.value,
          contains('on DuplicateScreenException'),
          reason: '${source.key} must not proceed on an ambiguous '
              'configuration',
        );
      }
    });

    test('and both load the specs where they can still refuse them', () {
      // The loader throws, so the call cannot stay buried in the
      // argument list of the runner it feeds: an exception from there
      // would be reported as a launch failure, or escape entirely.
      for (final file in [
        'flutter_testsmith/lib/src/cli/commands/run_command.dart',
        'flutter_testsmith/lib/src/cli/commands/suite_command.dart',
      ]) {
        expect(
          _source(file),
          isNot(contains('fromDisk: await loadFigmaSpecs(')),
          reason: '$file still loads specs inline in the runner arguments',
        );
      }
    });
  });
}
