import 'dart:io';

import '../device/process_runner.dart';

/// Git said no, or was never there to ask.
///
/// Two conditions, kept apart by [isMissing] rather than by two types.
/// "git is not installed" names something to go and install; "git ran and
/// returned non-zero" names something about the repository. Reporting
/// either one as the other sends somebody to the wrong place.
class GitUnavailableException implements Exception {
  /// git ran, and failed. [message] is what it said.
  const GitUnavailableException(this.message) : isMissing = false;

  /// git could not be started at all.
  ///
  /// The message deliberately carries no command line: the launch
  /// failure's own text quotes `git -C <absolute path> ...`, which puts
  /// the application's location into output that is read, logged and
  /// sometimes committed.
  const GitUnavailableException.missing()
      : message = 'git is not installed, or is not on PATH. Install it, or '
            'pass the changed files yourself with --changed.',
        isMissing = true;

  final String message;

  /// Whether git could not be launched, as opposed to having answered.
  final bool isMissing;

  @override
  String toString() => 'GitUnavailableException: $message';
}

/// Lists the files that changed since a reference.
///
/// Four questions, not one. `git diff --name-only <ref>` answers only
/// "what differs from that commit in tracked files"; a **new** file is
/// untracked and shows in none of it. A test-selection tool that
/// overlooks a newly added screen would skip the one flow most likely
/// to matter, so untracked files are gathered too.
class GitChanges {
  const GitChanges({
    this.runner = const SystemProcessRunner(),
    this.workingDirectory,
  });

  final ProcessRunner runner;
  final String? workingDirectory;

  /// Every path differing from [ref], including work not yet committed.
  ///
  /// Both queries are asked **from the repository root**, and that is the
  /// whole point rather than a tidiness. The two do not agree on a base
  /// otherwise: `git diff --name-only` always answers relative to the
  /// repository, while `git ls-files --others` answers relative to the
  /// directory it was run in *and only lists what is under it*. Asked
  /// from `<repo>/example/app`, the pair returned
  /// `example/app/lib/home.dart` and `lib/added.dart` - two coordinate
  /// systems in one list - and silently omitted every untracked file
  /// elsewhere in the repository.
  ///
  /// That omission is the dangerous half. An unmatched path still selects
  /// the whole suite, which is merely useless; a path that never appears
  /// at all is a new screen nobody is told about, which is the exact
  /// failure this class says it exists to prevent.
  Future<List<String>> since(String ref) async {
    final from = await repositoryRoot() ?? workingDirectory;

    final tracked = await _run(['diff', '--name-only', ref], from: from);
    final untracked = await _run(
      ['ls-files', '--others', '--exclude-standard'],
      from: from,
    );

    // A set: a file can be both modified and listed by another query.
    return {..._lines(tracked), ..._lines(untracked)}.toList()..sort();
  }

  /// The root of the repository containing [workingDirectory].
  ///
  /// Null when there is no repository there, or no git to ask - both of
  /// which are "this is not something I can locate", never an answer a
  /// caller should mistake for one. The path every other git query
  /// reports against, and the only base a caller may compare against
  /// those reports.
  Future<String?> repositoryRoot() async {
    final ProcessResultData result;
    try {
      result = await runner.run('git', [
        if (workingDirectory != null) ...['-C', workingDirectory!],
        'rev-parse',
        '--show-toplevel',
      ]);
    } on ProcessException {
      // git is not installed. A caller that only wants to explain a
      // hand-supplied change list should not be stopped by that.
      return null;
    }
    if (!result.succeeded) return null;

    final root = result.stdout.trim();
    return root.isEmpty ? null : root;
  }

  /// Whether [ref] is something git recognises.
  ///
  /// Checked separately so a typo'd branch name produces "unknown
  /// revision" rather than an empty change list, which would look
  /// exactly like "nothing changed" and select nothing.
  ///
  /// Throws [GitUnavailableException] when git cannot be launched. The
  /// default `--since HEAD` reaches here with no flag, so this was the
  /// one place a missing git left the tool as an unhandled exception.
  Future<bool> knows(String ref) async {
    final ProcessResultData result;
    try {
      result = await runner.run(
        'git',
        [
          if (workingDirectory != null) ...['-C', workingDirectory!],
          'rev-parse',
          '--verify',
          '--quiet',
          ref,
        ],
      );
    } on ProcessException {
      throw const GitUnavailableException.missing();
    }
    return result.succeeded;
  }

  Future<String> _run(List<String> arguments, {String? from}) async {
    final directory = from ?? workingDirectory;

    final ProcessResultData result;
    try {
      result = await runner.run(
        'git',
        [
          if (directory != null) ...['-C', directory],
          ...arguments,
        ],
      );
    } on ProcessException {
      // Not reachable through `impact`, where `knows` runs first and
      // stops there. Translated anyway: this method's contract is that a
      // git problem arrives as a GitUnavailableException, and a second
      // caller reaching it later should not have to discover that the
      // contract had a hole in it.
      throw const GitUnavailableException.missing();
    }

    if (!result.succeeded) {
      throw GitUnavailableException(
        'git ${arguments.join(' ')} failed: '
        '${result.stderr.trim().isEmpty ? 'exit ${result.exitCode}' : result.stderr.trim()}',
      );
    }
    return result.stdout;
  }

  static List<String> _lines(String output) => [
        for (final line in output.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ];
}
