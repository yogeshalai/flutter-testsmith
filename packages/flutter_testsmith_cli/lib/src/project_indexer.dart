import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Builds an [ImpactIndex] by reading a project from disk.
///
/// The engine's builder deliberately takes file *contents*, so the
/// analysis can be tested without a filesystem. This is the part that
/// knows where a project keeps things, and it is the only part that
/// touches the disk.
class ProjectIndexer {
  const ProjectIndexer(this.projectDirectory, {this.relativeTo});

  final Directory projectDirectory;

  /// The directory every indexed path is expressed relative to.
  ///
  /// An input rather than an assumption, because the two callers need
  /// different answers and used to get whichever one the working
  /// directory happened to supply.
  ///
  /// `testsmith impact` must pass the git repository root: its paths are
  /// compared against `git`'s, and a comparison between two coordinate
  /// systems is not a comparison. Run from `<repo>/example/app` this
  /// indexed `tests/home.yaml` while git reported
  /// `example/app/lib/home.dart`, nothing matched, and the analyser did
  /// what it must when it cannot account for a file - selected every
  /// flow, every time, for as long as anyone ran it from there.
  ///
  /// `testsmith generate` must not: it opens `File(flow.path)`, so its paths
  /// have to resolve from this process. Null keeps that - the working
  /// directory - which is what both callers silently had before.
  final Directory? relativeTo;

  ImpactIndex build({void Function(String)? onProblem}) {
    final builder =
        ImpactIndexBuilder(appDirectory: _relative(projectDirectory.path));

    _eachFile('tests', '.yaml', (file, contents) {
      try {
        final flow = TestFlow.parse(contents, source: file.path);
        // A proposed scenario is not part of the suite, so it is not
        // something test selection may offer to run.
        if (flow.isProposed) return;
        builder.addFlow(_relative(file.path), flow);
      } on FlowFormatException catch (error) {
        // A flow that cannot be parsed cannot be selected either. Say
        // so: silently omitting it would quietly shrink the suite.
        onProblem?.call('ignoring ${file.path}: $error');
      }
    }, onProblem: onProblem);

    _eachFile('lib', '.dart', (file, contents) {
      builder.addSource(_relative(file.path), contents);
    }, onProblem: onProblem);

    _eachFile('mappings', '.yaml', (file, contents) {
      try {
        final mappings = MappingsFile.parse(contents, source: file.path);
        builder.addConfig(_relative(file.path), mappings.screen);
      } on MappingsFormatException catch (error) {
        onProblem?.call('ignoring ${file.path}: $error');
      }
    }, onProblem: onProblem);

    // Both a normalised design and a screenshot baseline name their
    // screen in the file, so neither needs a naming convention.
    for (final directory in const ['figma', 'visual_baselines']) {
      _eachFile(directory, '.json', (file, contents) {
        try {
          final decoded = jsonDecode(contents);
          if (decoded is! Map) {
            // The same omission `loadFigmaSpecs` had, in the other
            // reader of these two directories and behind a guard of the
            // same shape. The cast this replaces raised a `TypeError`,
            // which that guard does not catch, so one file nobody could
            // read ended `impact` at 255 instead of being skipped.
            throw const FormatException(
              'expected a JSON object naming the screen it describes',
            );
          }
          final screen = decoded['screen']?.toString();
          if (screen != null) builder.addConfig(_relative(file.path), screen);
        } on FormatException catch (error) {
          onProblem?.call('ignoring ${file.path}: $error');
        }
      }, onProblem: onProblem);
    }

    return builder.build();
  }

  void _eachFile(
    String directory,
    String extension,
    void Function(File file, String contents) visit, {
    required void Function(String)? onProblem,
  }) {
    final root = Directory('${projectDirectory.path}/$directory');
    if (!root.existsSync()) return;

    for (final entry in root.listSync(recursive: true).whereType<File>()) {
      if (!entry.path.endsWith(extension)) continue;
      // Generated and cached trees say nothing about the application.
      final path = _relative(entry.path);
      if (path.contains('/.dart_tool/') || path.contains('/.cache/')) {
        continue;
      }
      // Read here rather than in the call below, because every one of
      // those callbacks guards its own parsing and none of them could
      // guard this: `readAsStringSync` decodes as well as reads, and
      // reports a failure to decode as a `FileSystemException` - not a
      // `FormatException`, so not what any of them catches, and not
      // caught over them either. A file saved in an encoding this
      // cannot read ended `impact` and `generate` at 255.
      //
      // Skipped the way every other unusable file here is skipped, down
      // the channel that already exists for it. Leaving it out of the
      // index is the safe direction: a change the index cannot account
      // for selects more flows, never fewer.
      final String contents;
      try {
        contents = entry.readAsStringSync();
      } on FileSystemException catch (error) {
        onProblem?.call('ignoring ${entry.path}: $error');
        continue;
      }
      visit(entry, contents);
    }
  }

  /// [path] against [relativeTo], forward slashes, no `.` or `..` left.
  ///
  /// Absolute first, then relative. `--app ../..` and `--app .` both
  /// reach here as paths carrying segments that no git output ever
  /// contains, and `./tests/home.yaml` matches `tests/home.yaml` in no
  /// comparison anyone would write.
  ///
  /// A path outside the base is returned absolute, which is the honest
  /// answer: a file that is not under the repository has no path
  /// relative to it, and inventing one would be a claim.
  String _relative(String path) {
    final normalised = _clean(File(path).absolute.path);
    final base = _clean((relativeTo ?? Directory.current).absolute.path);

    if (normalised == base) return '';
    // The separator matters: `/repo` must not swallow `/repository/a`.
    if (normalised.startsWith('$base/')) {
      return normalised.substring(base.length + 1);
    }
    return normalised;
  }

  /// Forward slashes, and `.`/`..` resolved without touching the disk.
  ///
  /// Lexical on purpose. Asking the filesystem would resolve symlinks,
  /// and git reports the path somebody committed rather than the one it
  /// points at.
  static String _clean(String path) {
    final forward = path.replaceAll('\\', '/');
    final leadingSlash = forward.startsWith('/');

    final segments = <String>[];
    for (final segment in forward.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..' &&
          segments.isNotEmpty &&
          segments.last != '..' &&
          !segments.last.endsWith(':')) {
        segments.removeLast();
        continue;
      }
      segments.add(segment);
    }

    final joined = segments.join('/');
    return leadingSlash ? '/$joined' : joined;
  }
}
