import 'dart:io';

/// Where the application under test is.
///
/// Every command needs this and, before this file existed, every command
/// answered it for itself: five of them defaulted `--app` to
/// `examples/ecommerce_app`, which is this repository's own example and
/// exists nowhere else, and `testsmith run` alone never checked that the
/// directory was there. Pointed at somebody else's Flutter project the
/// runner therefore read no mappings, no designs and no fixtures, said
/// nothing about any of it, and carried on to launch `flutter run` in a
/// directory that did not exist.
///
/// The rule is now in one place because a root that means one thing to
/// `run` and another to `suite run` is two definitions of what the
/// application is.

/// A resolved application root, or why there is not one.
///
/// Two states, never both: [directory] is null exactly when [problem] is
/// not. [hint] is the line under the headline - what to do about it -
/// which is how the rest of the CLI already reports a setup mistake.
class ProjectRoot {
  const ProjectRoot._(this.directory, this.problem, this.hint);

  const ProjectRoot.found(Directory directory) : this._(directory, null, '');

  const ProjectRoot.absent(String problem, {String hint = ''})
      : this._(null, problem, hint);

  final Directory? directory;
  final String? problem;
  final String hint;

  bool get isFound => directory != null;
}

/// The marker that says "a Dart or Flutter package starts here".
///
/// A true convention rather than an assumption about layout: `pubspec.yaml`
/// is what `flutter run` itself looks for, and a project without one is not
/// a project any Flutter tool could build. Nothing else is required - not
/// `lib/`, not `integration_test/`, not an `android/` directory - because a
/// project is free to arrange those however it likes.
const String pubspecFileName = 'pubspec.yaml';

/// Resolves the `--app` option into the application root.
///
/// [requested] is what the user typed, or null when they typed nothing.
///
/// Explicit wins, and is taken at its word: a named directory only has to
/// exist. It is deliberately **not** required to hold a `pubspec.yaml`,
/// because `generate` and `impact` only ever read a `mytest/` tree and
/// refusing them over a missing pubspec would buy a restriction and no
/// safety. The marker is for discovery, where the tool is guessing.
///
/// Nothing named means: find it. The first ancestor of [from] holding a
/// `pubspec.yaml` is the root, so the CLI works from inside a project's
/// `mytest/` directory exactly as it does from the project root. When
/// there is no such ancestor the command stops and says where it looked -
/// never a fallback to a directory the user did not name.
ProjectRoot resolveProjectRoot(String? requested, {Directory? from}) {
  if (requested != null) {
    final directory = Directory(requested);
    return directory.existsSync()
        ? ProjectRoot.found(directory)
        : ProjectRoot.absent(
            'No such app directory: $requested',
            hint: 'Named by --app, relative to ${Directory.current.path}.',
          );
  }

  final start = from ?? Directory.current;
  final found = _nearestPackageRoot(start);
  if (found != null) return ProjectRoot.found(found);

  return ProjectRoot.absent(
    'This is not inside a Flutter project.',
    hint: 'Looked for $pubspecFileName in ${start.path} and every directory '
        'above it. Run testsmith from inside your application, or name it: '
        '--app <directory>.',
  );
}

/// Resolves an `app: path:` declared by a suite or an auth file.
///
/// The declared path is relative to the declaring file, which is what a
/// suite file already promises. A person who writes an absolute one means
/// the directory they named: joining that onto the file's own directory
/// produced `mytest/suites//home/me/app`, whose only visible symptom was
/// every flow in the suite being reported missing - the suite blamed for
/// a root that was wrong.
///
/// The root's existence is checked here, and named here, for the same
/// reason: "there is no application at X" is the truth, and "the suite
/// names flows that are not there" is not.
ProjectRoot resolveDeclaredProjectRoot({
  required File declaringFile,
  required String declaredPath,
  bool? windows,
}) {
  final joined = isAbsolutePath(declaredPath, windows: windows)
      ? declaredPath
      : '${declaringFile.parent.path}/$declaredPath';

  final directory = Directory(joined);
  // A malformed absolute path - a Windows drive letter on a POSIX host -
  // makes the operating system refuse the question rather than answer it.
  // That is still "no application there", not a crash.
  bool exists;
  try {
    exists = directory.existsSync();
  } on FileSystemException {
    exists = false;
  }

  return exists
      ? ProjectRoot.found(directory)
      : ProjectRoot.absent(
          'No application at $joined',
          hint: '${declaringFile.path} declares app.path: $declaredPath, '
              'which is resolved relative to that file unless it is absolute.',
        );
}

/// Whether [path] names a location from the root of a filesystem.
///
/// Drive letters and UNC prefixes count only on Windows: on a POSIX host
/// `C:/x` is a relative directory that happens to be called `C:`, and
/// treating it as absolute would silently move somebody's project.
///
/// [windows] exists so the rule can be tested in both dialects from either
/// host, not so callers can choose one.
bool isAbsolutePath(String path, {bool? windows}) {
  if (path.startsWith('/')) return true;
  if (!(windows ?? Platform.isWindows)) return false;
  return path.startsWith(r'\') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path);
}

/// Whether [a] and [b] name the same location.
///
/// Lexical, and told which dialect to speak, for the reason
/// [isAbsolutePath] is: a comparison that asks the host answers for the
/// host, and this rule has to be testable in both dialects from either
/// one. `.`, a trailing separator and either slash all spell the same
/// directory, and somebody who typed one of them meant the directory
/// rather than the spelling. On Windows the comparison ignores case,
/// because the filesystem does.
///
/// **Not** canonicalisation. No symlink is followed and the filesystem
/// is never consulted, so two names that reach one directory through a
/// link still compare as different. That keeps the answer independent
/// of what happens to exist, which is the same trade the rest of this
/// file makes. A caller holding relative paths that may have different
/// bases should make them absolute before asking.
bool isSamePath(String a, String b, {bool? windows}) {
  final isWindows = windows ?? Platform.isWindows;
  final left = _lexical(a, isWindows);
  final right = _lexical(b, isWindows);

  return isWindows ? left.toLowerCase() == right.toLowerCase() : left == right;
}

/// Forward slashes, no empty segments, and `.`/`..` resolved in text.
String _lexical(String path, bool isWindows) {
  final forward = isWindows ? path.replaceAll(r'\', '/') : path;
  final rooted = forward.startsWith('/');

  final segments = <String>[];
  for (final segment in forward.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    // A drive letter is not something `..` can climb past.
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
  return rooted ? '/$joined' : joined;
}

/// The nearest directory at or above [start] holding a `pubspec.yaml`.
Directory? _nearestPackageRoot(Directory start) {
  var directory = start.absolute;
  while (true) {
    if (File('${directory.path}/$pubspecFileName').existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    // The filesystem root is its own parent, which is where the walk ends.
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}
