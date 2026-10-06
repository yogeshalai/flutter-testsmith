import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Answers git commands from a script, and records what was asked.
class _FakeGit implements ProcessRunner {
  _FakeGit(this.responses);

  final Map<String, ProcessResultData> responses;
  final List<List<String>> calls = [];

  static ProcessResultData ok(String stdout) =>
      ProcessResultData(exitCode: 0, stdout: stdout, stderr: '');

  static ProcessResultData fail(String stderr) =>
      ProcessResultData(exitCode: 128, stdout: '', stderr: stderr);

  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) {
    calls.add([executable, ...arguments]);
    for (final entry in responses.entries) {
      if (arguments.join(' ').contains(entry.key)) {
        return Future.value(entry.value);
      }
    }
    return Future.value(ok(''));
  }
}

void main() {
  test('lists tracked changes since a reference', () async {
    final git = _FakeGit({
      'diff --name-only': _FakeGit.ok('lib/a.dart\nlib/b.dart\n'),
    });

    final changed = await GitChanges(runner: git).since('main');

    expect(changed, ['lib/a.dart', 'lib/b.dart']);
  });

  test('includes untracked files, which no diff reports', () async {
    // A brand new screen is untracked, so `git diff` never mentions it.
    // Missing it would skip the flow most likely to matter.
    final git = _FakeGit({
      'diff --name-only': _FakeGit.ok('lib/a.dart\n'),
      'ls-files --others': _FakeGit.ok('lib/new_screen.dart\n'),
    });

    final changed = await GitChanges(runner: git).since('main');

    expect(changed, ['lib/a.dart', 'lib/new_screen.dart']);
  });

  test('reports a file once even when two queries name it', () async {
    final git = _FakeGit({
      'diff --name-only': _FakeGit.ok('lib/a.dart\n'),
      'ls-files --others': _FakeGit.ok('lib/a.dart\n'),
    });

    expect(await GitChanges(runner: git).since('main'), ['lib/a.dart']);
  });

  test('ignores blank lines', () async {
    final git = _FakeGit({
      'diff --name-only': _FakeGit.ok('\nlib/a.dart\n\n\n'),
    });

    expect(await GitChanges(runner: git).since('main'), ['lib/a.dart']);
  });

  test('a failing git is an exception, not an empty change list', () async {
    // An empty list looks exactly like "nothing changed" and would
    // select nothing at all - silently testing none of the change.
    final git = _FakeGit({
      'diff --name-only': _FakeGit.fail('fatal: bad revision'),
    });

    await expectLater(
      GitChanges(runner: git).since('nope'),
      throwsA(
        isA<GitUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('bad revision'),
        ),
      ),
    );
  });

  test('verifies a reference before trusting an empty result', () async {
    final git = _FakeGit({'rev-parse': _FakeGit.fail('')});

    expect(await GitChanges(runner: git).knows('typo-branch'), isFalse);
    expect(
      git.calls.single,
      containsAll(['rev-parse', '--verify', 'typo-branch']),
    );
  });

  test('runs in the configured directory', () async {
    final git = _FakeGit({});

    await GitChanges(runner: git, workingDirectory: '/repo').since('main');

    expect(git.calls.first, containsAllInOrder(['-C', '/repo']));
  });

  group('the repository root', () {
    test('is what git says the top level is', () async {
      final git = _FakeGit({'--show-toplevel': _FakeGit.ok('/repo\n')});

      expect(await GitChanges(runner: git).repositoryRoot(), '/repo');
    });

    test('is null outside a repository, not an empty path', () async {
      // An empty string used as a base would relativise every path
      // against the filesystem root, which is a wrong answer wearing the
      // costume of a right one.
      final git = _FakeGit({'--show-toplevel': _FakeGit.fail('not a git repo')});

      expect(await GitChanges(runner: git).repositoryRoot(), isNull);
    });

    test('is asked about the configured directory', () async {
      final git = _FakeGit({'--show-toplevel': _FakeGit.ok('/repo\n')});

      await GitChanges(runner: git, workingDirectory: '/repo/app')
          .repositoryRoot();

      expect(git.calls.single, containsAllInOrder(['-C', '/repo/app']));
    });
  });

  group('both queries are asked from the repository root', () {
    test('even when the working directory is further in', () async {
      // The defect this closes. `git diff --name-only` answers relative
      // to the repository whatever directory it runs in, while
      // `git ls-files --others` answers relative to *its* directory and
      // lists only what is under it. Asked from different places the two
      // returned different coordinate systems, and the second quietly
      // omitted every untracked file elsewhere in the repository.
      final git = _FakeGit({'--show-toplevel': _FakeGit.ok('/repo\n')});

      await GitChanges(runner: git, workingDirectory: '/repo/example/app')
          .since('main');

      final diff = git.calls.firstWhere((call) => call.contains('diff'));
      final lsFiles = git.calls.firstWhere((call) => call.contains('ls-files'));

      expect(diff, containsAllInOrder(['-C', '/repo']));
      expect(lsFiles, containsAllInOrder(['-C', '/repo']));
      // The negative control: neither may be asked from further in.
      expect(diff, isNot(contains('/repo/example/app')));
      expect(lsFiles, isNot(contains('/repo/example/app')));
    });

    test('and falls back to the configured directory when there is no root',
        () async {
      // No repository to locate is no worse than before, never a silent
      // switch to somewhere else.
      final git = _FakeGit({'--show-toplevel': _FakeGit.fail('')});

      await GitChanges(runner: git, workingDirectory: '/elsewhere')
          .since('main');

      expect(
        git.calls.firstWhere((call) => call.contains('diff')),
        containsAllInOrder(['-C', '/elsewhere']),
      );
    });
  });

  // A missing git is a thing to install, not a crash. `knows` used to let
  // the ProcessException straight out, and `testsmith impact` - whose
  // `--since` defaults to HEAD, so no flag is needed to reach it - exited
  // 255 with a Dart stack trace carrying the absolute application path
  // inside the leaked `git.exe -C ...` command line.
  //
  // The two conditions stay different. "git is not installed" and "git ran
  // and said no" need different sentences, and only one of them names
  // something to install.
  group('git is not installed', () {
    test('knows reports it instead of letting the launch failure out',
        () async {
      final git = GitChanges(runner: _MissingGit(), workingDirectory: '/x');

      await expectLater(
        git.knows('HEAD'),
        throwsA(isA<GitUnavailableException>()
            .having((e) => e.isMissing, 'isMissing', isTrue)),
      );
    });

    test('since reports it too', () async {
      final git = GitChanges(runner: _MissingGit(), workingDirectory: '/x');

      await expectLater(
        git.since('HEAD'),
        throwsA(isA<GitUnavailableException>()
            .having((e) => e.isMissing, 'isMissing', isTrue)),
      );
    });

    test('and the message names git rather than the command line', () async {
      // The leak this closes: the ProcessException message carries
      // `git.exe -C <absolute project path> ...`.
      try {
        await GitChanges(runner: _MissingGit(), workingDirectory: '/secret')
            .knows('HEAD');
        fail('expected a GitUnavailableException');
      } on GitUnavailableException catch (error) {
        expect('$error'.toLowerCase(), contains('git'));
        expect('$error', isNot(contains('/secret')));
        expect('$error', isNot(contains('ProcessException')));
      }
    });

    test('repositoryRoot still answers null, as it always did', () async {
      // Unchanged on purpose: a caller that only wants to explain a
      // hand-supplied change list is not stopped by a missing git, and
      // `impact --changed` depends on that.
      final root = await GitChanges(runner: _MissingGit()).repositoryRoot();

      expect(root, isNull);
    });
  });

  group('git is installed and the command fails', () {
    test('a non-zero exit is still a failure, not a missing tool', () async {
      final git = _FakeGit({'diff': _FakeGit.fail('fatal: bad revision')});

      try {
        await GitChanges(runner: git).since('nope');
        fail('expected a GitUnavailableException');
      } on GitUnavailableException catch (error) {
        expect(error.isMissing, isFalse);
        expect(error.message, contains('fatal: bad revision'));
      }
    });
  });
}

/// A git that cannot be launched at all.
///
/// The shape `_NoAdb` already uses in the CLI suite: a real
/// ProcessException, which is what `Process.run` raises when the
/// executable is not on PATH.
class _MissingGit implements ProcessRunner {
  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) =>
      throw ProcessException(
        executable,
        arguments,
        'The system cannot find the file specified',
        2,
      );
}
