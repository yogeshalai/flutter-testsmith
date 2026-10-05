// Three commands, three answers to the same question.
//
// `testsmith auth` looked for a `.env` in the project and then the working
// directory. `testsmith run` and `testsmith suite run` looked in the working
// directory and then the project. `DotEnv.load` returns the *first* file
// it finds, so a developer with a `.env` in both places had `testsmith
// auth` reading one file and `testsmith run` reading another - same
// mechanism, same variable name, different value.
//
// The audit for this milestone found two more callers nobody had counted:
// the LLM key lookups in `testsmith run`'s analysis step and in `testsmith
// generate`. Both are tool-side `.env` discovery too, and both had the
// working-directory-first order.
//
// The policy is now one order everywhere: **project, then cwd**. A
// project's configuration should mean the same thing wherever the CLI
// was launched from; the working directory is the accident.
//
// This is discovery order only. Which value wins is unchanged: the
// process environment always beats the file, in `DotEnv.operator []` and
// in `EnvSecretResolver._lookUp` alike.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/dotenv.dart';
import 'package:flutter_testsmith_cli/src/secrets/env_secret_resolver.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

late Directory _project;
late Directory _cwd;

void _writeEnv(Directory directory, String contents) =>
    File('${directory.path}/.env').writeAsStringSync(contents);

/// The order every tool-side caller now uses.
DotEnv _load() => DotEnv.load([_project.path, _cwd.path]);

String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

/// Every tool-side `.env` consumer, and the variable each names for the
/// directory holding the project.
const Map<String, String> _consumers = {
  'flutter_testsmith_cli/lib/src/commands/run_command.dart': 'projectDirectory.path',
  'flutter_testsmith_cli/lib/src/commands/suite_command.dart': 'projectDirectory.path',
  'flutter_testsmith_cli/lib/src/commands/auth_command.dart': 'project.path',
  'flutter_testsmith_cli/lib/src/commands/generate_command.dart': 'project.path',
  'flutter_testsmith_cli/lib/src/commands/figma_command.dart': 'root.directory!.path',
};

/// The two files that *are* the mechanism, and so are allowed to read the
/// process environment for a credential.
/// Paths are relative to `lib/`, which is what [_cliSources] reports.
const List<String> _mechanism = [
  'src/dotenv.dart',
  'src/secrets/env_secret_resolver.dart',
];

/// Every `.dart` under the CLI's `lib/`, as (relative path, source).
///
/// Walked rather than listed, which is the whole point: a list is what
/// let `figma_command.dart` read a credential for four milestones
/// without anything noticing.
List<(String, String)> _cliSources() {
  for (final root in ['packages/flutter_testsmith_cli/lib', '../flutter_testsmith_cli/lib', 'lib']) {
    final directory = Directory(root);
    if (!directory.existsSync()) continue;
    return [
      for (final entity in directory.listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          (
            entity.path.replaceAll(r'\', '/').split('/lib/').last,
            entity.readAsStringSync(),
          ),
    ];
  }
  fail('cannot find the CLI lib tree');
}

void main() {
  setUp(() {
    _project = Directory.systemTemp.createTempSync('dotenv_project');
    _cwd = Directory.systemTemp.createTempSync('dotenv_cwd');
    addTearDown(() {
      _project.deleteSync(recursive: true);
      _cwd.deleteSync(recursive: true);
    });
  });

  group('discovery order', () {
    test('a project .env alone is found', () {
      _writeEnv(_project, 'API_TOKEN=from-project\n');

      expect(_load()['API_TOKEN'], 'from-project');
    });

    test('a cwd .env alone is found', () {
      _writeEnv(_cwd, 'API_TOKEN=from-cwd\n');

      expect(_load()['API_TOKEN'], 'from-cwd');
    });

    test('with both, the project wins', () {
      // The case the three commands used to disagree about.
      _writeEnv(_project, 'API_TOKEN=from-project\n');
      _writeEnv(_cwd, 'API_TOKEN=from-cwd\n');

      expect(_load()['API_TOKEN'], 'from-project');
    });

    test('the reversed order would pick the other file', () {
      // States the difference the policy decides, so the test is about a
      // choice rather than a tautology.
      _writeEnv(_project, 'API_TOKEN=from-project\n');
      _writeEnv(_cwd, 'API_TOKEN=from-cwd\n');

      expect(DotEnv.load([_cwd.path, _project.path])['API_TOKEN'], 'from-cwd');
    });

    test('the first file found is the only one read', () {
      // Not a merge. A key present only in the cwd file is not picked up
      // when the project file exists - unchanged behaviour, pinned
      // because the new order changes which file that is.
      _writeEnv(_project, 'API_TOKEN=from-project\n');
      _writeEnv(_cwd, 'OTHER=from-cwd\n');

      expect(_load()['API_TOKEN'], 'from-project');
      expect(_load()['OTHER'], isNull);
    });

    test('neither present is empty, not an error', () {
      expect(_load().isEmpty, isTrue);
      expect(_load()['API_TOKEN'], isNull);
    });
  });

  group('value precedence is untouched', () {
    test('the process environment beats both files', () {
      _writeEnv(_project, 'API_TOKEN=from-project\n');
      _writeEnv(_cwd, 'API_TOKEN=from-cwd\n');

      final resolver = EnvSecretResolver(
        dotenv: _load(),
        environment: const {'API_TOKEN': 'from-environment'},
      );

      expect(
        resolver.resolve(const SecretRef(scheme: 'env', name: 'API_TOKEN'))
            .expose(),
        'from-environment',
      );
    });

    test('the file is used when the environment has nothing', () {
      _writeEnv(_project, 'API_TOKEN=from-project\n');

      final resolver = EnvSecretResolver(dotenv: _load(), environment: const {});

      expect(
        resolver.resolve(const SecretRef(scheme: 'env', name: 'API_TOKEN'))
            .expose(),
        'from-project',
      );
    });

    test('a secret in neither place still reports missing', () {
      final resolver = EnvSecretResolver(dotenv: _load(), environment: const {});
      const ref = SecretRef(scheme: 'env', name: 'API_TOKEN');

      expect(resolver.isPresent(ref), isFalse);
      expect(() => resolver.resolve(ref), throwsA(isA<MissingSecretException>()));
    });

    test('the lookup rule itself is unchanged', () {
      final resolver = _source('flutter_testsmith_cli/lib/src/secrets/env_secret_resolver.dart');

      expect(resolver, contains('_environment[ref.name] ?? _dotenv[ref.name]'));
    });
  });

  group('every tool-side consumer agrees on the order', () {
    _consumers.forEach((file, projectVar) {
      test('$file loads [project, cwd]', () {
        final source = _source(file);

        expect(
          source,
          contains('DotEnv.load([$projectVar, Directory.current.path])'),
          reason: file,
        );
      });

      test('$file does not load [cwd, project]', () {
        // The reversal this milestone removed. Pinned per file so a
        // future accidental swap fails here rather than silently
        // changing which file a command reads.
        expect(
          _source(file),
          isNot(contains('DotEnv.load([Directory.current.path')),
          reason: file,
        );
      });
    });

    test('every consumer that is listed uses the order', () {
      // Counted across the listed files, so a second load added to one
      // of them with the wrong order fails here.
      var projectFirst = 0;
      var cwdFirst = 0;
      for (final file in _consumers.keys) {
        final source = _source(file);
        projectFirst += 'DotEnv.load(['.allMatches(source).length;
        cwdFirst +=
            'DotEnv.load([Directory.current.path'.allMatches(source).length;
      }

      // Five: `run` loaded `.env` a second time for `--ai`, after the
      // run. RUN-AI-CONFIG reads the AI configuration before the device
      // and hands the analysis the `.env` the run already loaded.
      expect(projectFirst, 5, reason: 'five tool-side .env loads');
      expect(cwdFirst, 0);
    });

    test('and no command was left off the list', () {
      // What the old version of this test claimed and could not do. It
      // counted `DotEnv.load` across a hand-written map, so a command
      // that never called `DotEnv.load` at all was invisible to it -
      // which is exactly how `figma pull` spent four milestones reading
      // `Platform.environment['FIGMA_TOKEN']` directly while a test
      // named "no tool-side caller was missed" passed.
      //
      // Walked instead. `Platform.environment[...]` - the subscript, not
      // the map - is the shape of a credential read, and the only two
      // files entitled to it are the ones that are the mechanism.
      final offenders = [
        for (final (path, source) in _cliSources())
          if (!_mechanism.contains(path) &&
              RegExp(r'Platform\.environment\s*\[').hasMatch(source))
            path,
      ];

      expect(
        offenders,
        isEmpty,
        reason: 'these read a credential straight from the process '
            'environment instead of through EnvSecretResolver, so a value '
            'in a .env would not reach them: ${offenders.join(', ')}',
      );
    });

    test('the walk actually reaches the tree it claims to', () {
      // A scan that silently found nothing would pass the test above
      // for the wrong reason.
      final paths = [for (final (path, _) in _cliSources()) path];

      expect(paths, contains('src/commands/figma_command.dart'));
      expect(paths, containsAll(_mechanism));
      expect(paths.length, greaterThan(20));
    });
  });

  group('S1 is not regressed', () {
    test('the suite still hands its resolver to the runner', () {
      final suite = _source('flutter_testsmith_cli/lib/src/commands/suite_command.dart');
      final runner = suite.substring(suite.indexOf('FlowRunner('));

      expect(
        runner.substring(0, runner.indexOf('\n      ),')),
        contains('secrets: secrets'),
      );
    });

    test('and Figma still receives that same one instance', () {
      final suite = _source('flutter_testsmith_cli/lib/src/commands/suite_command.dart');

      expect('EnvSecretResolver('.allMatches(suite).length, 1);
      expect('secrets: secrets'.allMatches(suite).length, 2);
    });

    test('a .env-only secret still resolves through that resolver', () {
      // The S1 case, now reading the project's file rather than the
      // working directory's.
      _writeEnv(_project, 'API_BASE=https://from-project.example\n');

      final resolver = EnvSecretResolver(dotenv: _load(), environment: const {});

      expect(
        resolver.resolve(const SecretRef(scheme: 'env', name: 'API_BASE'))
            .expose(),
        'https://from-project.example',
      );
    });
  });

  group('nothing about the file format changed', () {
    test('comments and blank lines are still ignored', () {
      _writeEnv(_project, '# a comment\n\nAPI_TOKEN=from-project\n');

      expect(_load()['API_TOKEN'], 'from-project');
    });

    test('a value still renders redacted through Secret', () {
      _writeEnv(_project, 'API_TOKEN=from-project\n');

      final resolver = EnvSecretResolver(dotenv: _load(), environment: const {});
      final secret =
          resolver.resolve(const SecretRef(scheme: 'env', name: 'API_TOKEN'));

      expect('$secret', redactionMarker);
      expect('$secret', isNot(contains('from-project')));
    });
  });
}
