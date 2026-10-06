import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith/engine.dart';

import '../output.dart';
import '../project_indexer.dart';
import '../project_root.dart';

/// Reports which flows a set of changes makes worth running.
class ImpactCommand extends Command<int> {
  ImpactCommand() {
    argParser
      ..addOption(
        'app',
        help: 'Directory of the Flutter application under test. Defaults to '
            'the nearest directory at or above this one with a pubspec.yaml.',
      )
      ..addOption(
        'since',
        help: 'Git reference to compare against.',
        defaultsTo: 'HEAD',
      )
      ..addMultiOption(
        'changed',
        help: 'Use these paths instead of asking git. Repeatable, and '
            'mainly useful for seeing what a change WOULD select.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit the selection as JSON, for a CI job to act on.',
      );
  }

  @override
  String get name => 'impact';

  @override
  String get description =>
      'Show which test flows a set of changes makes worth running.';

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    final root = resolveProjectRoot(args.option('app'));
    if (!root.isFound) {
      output
        ..line(output.red(root.problem!))
        ..line(output.dim('  ${root.hint}'));
      return 1;
    }
    final projectDirectory = root.directory!;

    // Git is asked about the *project's* repository, not this process's.
    // It used to run wherever the CLI was launched, so pointing `--app`
    // at an application in another checkout asked the wrong repository
    // what had changed - or, outside one entirely, reported "git does not
    // know HEAD" about a perfectly ordinary reference.
    final git = GitChanges(workingDirectory: projectDirectory.path);

    // The index is built in git's coordinates, because git's are the ones
    // the comparison happens in. Null when there is no repository to
    // locate, which leaves the working directory - no worse than before,
    // and `--changed` still works with no git installed at all.
    final repositoryRoot = await git.repositoryRoot();

    final index = ProjectIndexer(
      projectDirectory,
      relativeTo:
          repositoryRoot == null ? null : Directory(repositoryRoot),
    ).build(
      onProblem: (problem) => output.line('  ! $problem'),
    );

    if (index.flows.isEmpty) {
      output.line(output.red('No flows found in ${projectDirectory.path}/tests.'));
      return 1;
    }

    final List<String> changed;
    final explicit = args.multiOption('changed');
    if (explicit.isNotEmpty) {
      changed = explicit;
    } else {
      final since = args.option('since')!;

      // Two conditions, and they are not the same sentence. A git that
      // is not installed is something to install; a git that answered
      // "I do not know that reference" is something to correct. The
      // first used to arrive here as an unhandled ProcessException,
      // which said neither.
      final bool known;
      try {
        known = await git.knows(since);
      } on GitUnavailableException catch (error) {
        output.line(output.red(error.message));
        return 1;
      }

      if (!known) {
        // An unknown reference yields an empty diff, which is
        // indistinguishable from "nothing changed" - and would select
        // nothing at all.
        output.line(output.red('Git does not know the reference "$since".'));
        return 1;
      }

      try {
        changed = await git.since(since);
      } on GitUnavailableException catch (error) {
        // `message` alone when git is missing: the sentence is written
        // for a person, and prefixing it with a type name is noise.
        output.line(output.red(error.isMissing ? error.message : '$error'));
        return 1;
      }
    }

    final selection = ImpactAnalyser(index).select(changed);

    if (args.flag('json')) {
      output.line(
        const JsonEncoder.withIndent('  ').convert({
          'changed': changed,
          ...selection.toJson(),
        }),
      );
      return 0;
    }

    _render(selection, changed, output);
    return 0;
  }

  void _render(
    ImpactSelection selection,
    List<String> changed,
    Output output,
  ) {
    output
      ..line(output.bold('Changed files'))
      ..line(changed.isEmpty
          ? output.dim('  none')
          : changed.map((path) => '  $path').join('\n'))
      ..line()
      ..line(output.bold('Selection'))
      ..line('  ${selection.reason}')
      ..line();

    for (final flow in selection.selected) {
      output
        ..line('  ${output.green('RUN ')} ${flow.name}  '
            '${output.dim(flow.path)}')
        ..line('        ${output.dim(selection.reasonFor(flow.name))}');
    }

    for (final flow in selection.skipped) {
      output.line('  ${output.dim('skip')} ${flow.name}  '
          '${output.dim('no changed file touches it')}');
    }

    if (selection.isFullSuite) {
      output
        ..line()
        ..line(output.dim(
          'Narrowing needs positive evidence about every changed file. '
          'One file the index cannot account for selects everything, '
          'because a missed test is a regression nobody looked for.',
        ));
    }
  }
}
