// S8: one output-resolution rule, held to by every command.
//
// `output_path_test.dart` proves the rule is right and
// `output_path_coordinates_test.dart` proves `suite run` reaches it from
// a foreign cwd. Neither can cover `run`, `smoke`, `inspect`, `auth
// setup`, `generate` or `figma pull` end to end: every one of those needs
// a handset, an LLM endpoint or a Figma token before it writes anything,
// and a test that needs hardware is a test that does not run.
//
// So the invariant those six share is pinned where it is actually
// visible - in the source. This is the same instrument
// dotenv_precedence_test.dart uses for the same class of problem: a rule
// that has to hold identically at every call site, where the failure mode
// is a new call site quietly answering the question its own way.
//
// What it is not: a substitute for behaviour. It cannot tell you the rule
// is correct. It tells you nobody has a private one.
import 'dart:io';

import 'package:test/test.dart';

String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  throw StateError('cannot find $relative');
}

/// Every command that writes somewhere the caller can name, and the
/// resolver call each one must go through.
const Map<String, String> _consumers = {
  'commands/run_command.dart': 'resolveOutputDirectory',
  'commands/suite_command.dart': 'resolveOutputDirectory',
  'commands/auth_command.dart': 'resolveOutputDirectory',
  'commands/generate_command.dart': 'resolveOutputDirectory',
  'commands/figma_command.dart': 'resolveOutputDirectory',
  'commands/smoke_command.dart': 'resolveOutputDirectory',
  'commands/inspect_command.dart': 'resolveOutputFile',
};

String _cli(String relative) =>
    _source('flutter_testsmith_cli/lib/src/$relative');

void main() {
  group('every command resolves its output through the one rule', () {
    _consumers.forEach((file, call) {
      test('$file calls $call', () {
        expect(_cli(file), contains('$call('), reason: file);
      });

      test('$file imports the shared resolver', () {
        expect(_cli(file), contains("output_path.dart'"), reason: file);
      });
    });
  });

  group('no command keeps a private output root', () {
    _consumers.forEach((file, _) {
      test('$file does not build a path straight from the option', () {
        // The exact shape S8 removed. `Directory(args.option('out')!)`
        // is a cwd-relative path wearing no sign that it is one.
        final source = _cli(file);
        expect(source, isNot(contains("Directory(args.option('out')")),
            reason: file);
        expect(source, isNot(contains("File(args.option('json')")),
            reason: file);
        expect(source, isNot(contains('Directory(requestedOut)')),
            reason: file);
      });
    });

    test('smoke no longer writes into whatever directory it is run from',
        () {
      // `File('out/smoke-$label.png')` - the one output path that was not
      // even configurable, only cwd-relative.
      expect(_cli('smoke.dart'), isNot(contains("File('out/")));
      expect(_cli('smoke.dart'), contains('outputDirectory'));
    });

    test('no caller was missed', () {
      // Counted across the library so a seventh command cannot appear
      // with its own answer and go unnoticed.
      var direct = 0;
      for (final file in Directory(
        [
          'packages/flutter_testsmith_cli/lib/src',
          '../flutter_testsmith_cli/lib/src',
        ].firstWhere((path) => Directory(path).existsSync()),
      ).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final source = file.readAsStringSync();
        direct += "Directory(args.option('out')".allMatches(source).length;
        direct += "File(args.option('json')".allMatches(source).length;
      }

      expect(direct, 0,
          reason: 'every --out and --json goes through output_path.dart');
    });
  });

  group('the resolver stays the only definition', () {
    test('it does not resolve an application root of its own', () {
      // S3 owns that question. A second answer here would be the very
      // duplication S8 exists to remove, one level down.
      final source = _cli('output_path.dart');

      expect(source, isNot(contains('resolveProjectRoot(')));
      expect(source, isNot(contains('Directory.current')));
    });

    test('it reuses S3\'s absolute-path rule rather than restating it', () {
      expect(_cli('output_path.dart'), contains('isAbsolutePath('));
    });
  });
}
