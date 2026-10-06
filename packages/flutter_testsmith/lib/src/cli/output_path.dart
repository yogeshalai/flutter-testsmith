import 'dart:io';

import 'project_root.dart';

/// Where a command writes.
///
/// S3 put "where is the application?" in one place because a root that
/// means one thing to `run` and another to `suite run` is two definitions
/// of what the application is. The same was true of the other direction
/// and stayed true for longer: `--out` was resolved against the current
/// working directory by `run`, `suite run`, `auth setup` and `inspect`,
/// against the application root by `generate`, and both ways by
/// `figma pull` depending on whether it was typed or defaulted - while
/// `smoke` had no option at all and wrote `out/smoke-*.png` into whatever
/// directory the caller happened to be standing in.
///
/// The visible symptom was that `--out out/results` named a different
/// directory depending on which command you typed it after, and that the
/// same command run from the repository root and from the application
/// directory put its reports in two different trees. The project's own
/// documentation had already grown the workaround: E-05 writes
/// `--out ../flutter-ai-test-platform/out/e05-run1`, a `..` back out of
/// the application, because the artifacts would not otherwise follow it.
///
/// The rule is now one sentence:
///
/// > A relative output path is resolved against the resolved application
/// > root. An absolute one is the directory the caller named.
///
/// "The resolved application root" is whatever S3 resolved - `--app` for
/// the commands that take it, the `app: path:` a suite or auth file
/// declares for the two that do not. This file deliberately does not
/// resolve a root of its own; taking one as an argument is what keeps
/// [resolveProjectRoot] the only answer to that question.
///
/// The root is used exactly as S3 handed it over, not made absolute. A
/// relative `--app` already means "relative to where I am standing", and
/// silently absolutising it here would make the output path disagree with
/// the application path printed beside it.
String resolveOutputPath(
  Directory applicationRoot,
  String requested, {
  bool? windows,
}) {
  if (isAbsolutePath(requested, windows: windows)) return requested;

  // A root that already ends in a separator would otherwise produce
  // `/projects/app//out`. Harmless to the filesystem, and not harmless
  // in a report that names the path it wrote.
  final base = _withoutTrailingSeparator(applicationRoot.path);
  return requested.isEmpty ? base : '$base/$requested';
}

/// [resolveOutputPath], for a directory a command writes into.
Directory resolveOutputDirectory(
  Directory applicationRoot,
  String requested, {
  bool? windows,
}) =>
    Directory(resolveOutputPath(applicationRoot, requested, windows: windows));

/// [resolveOutputPath], for a single file a command writes.
File resolveOutputFile(
  Directory applicationRoot,
  String requested, {
  bool? windows,
}) =>
    File(resolveOutputPath(applicationRoot, requested, windows: windows));

/// Why [directory] can never be written into, or null when nothing rules
/// it out.
///
/// Only what the filesystem already says, and nothing is created to find
/// out: [directory], or the nearest part of it that exists, is a file.
/// `run` and `auth setup` met that at the write, with an unhandled
/// `PathExistsException` at exit 255 - for `run`, after the device run
/// whose result it was meant to hold. Asked with the other facts about
/// the invocation instead. A write that fails for a reason this cannot
/// see, a permission or a full disk, is still the writer's to report.
String? outputDirectoryProblem(Directory directory) {
  var path = directory.path;
  while (true) {
    switch (FileSystemEntity.typeSync(path)) {
      case FileSystemEntityType.directory:
        return null;
      case FileSystemEntityType.notFound:
        final parent = File(path).parent.path;
        if (parent == path) return null;
        path = parent;
      default:
        return '$path is a file, so ${directory.path} cannot be a '
            'directory to write into.';
    }
  }
}

/// A failed write into an output directory, as one line: the path and
/// what the system said, without the exception's own framing.
String describeWriteFailure(FileSystemException error) {
  final reason = (error.osError?.message ?? error.message).trim();
  return error.path == null ? reason : '${error.path}: $reason';
}

String _withoutTrailingSeparator(String path) {
  var end = path.length;
  while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
    end--;
  }
  return path.substring(0, end);
}
