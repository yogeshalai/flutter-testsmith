import 'dart:io';

/// Where `flutter` is, and how that was decided.
///
/// Every Flutter consumer used to pass the bare name `flutter` and let the
/// operating system search PATH. That found the right executable on most
/// machines - and could never say which one it had found. `testsmith
/// doctor` printed a version with nothing to tie it to a file, which on a
/// machine with more than one SDK is a version for an unknown Flutter.
///
/// **PATH is still the only source.** This deliberately does not read
/// `FLUTTER_ROOT`, `.fvmrc`, `.fvm/flutter_sdk` or any override, because
/// PATH is the contract the tool already documents - E-04 states the
/// failure as "`flutter` is not on PATH", and the remedies say to install
/// Flutter and add it to PATH. Whether that contract should grow is a
/// later decision; this is the existing one made explicit and reportable.
///
/// What is *not* borrowed from [resolveAdb] is the filename rule. adb
/// ships as exactly one file, so asking whether it exists is a safe test.
/// The Flutter SDK ships both `bin/flutter`, a POSIX shell script, and
/// `bin/flutter.bat`. On Windows the first of those exists and will not
/// run - measured, not assumed:
///
/// ```text
/// D:\FlutterSDK\flutter\bin\flutter      -> %1 is not a valid Win32 application
/// D:\FlutterSDK\flutter\bin\flutter.bat  -> Flutter 3.44.7 - channel stable
/// ```
///
/// So on Windows the extensionless name is not a candidate at all, however
/// plainly it is there. Existence is the right question only once the
/// filename can be trusted.

/// Which of the known places a flutter came from.
///
/// One value today, and an enum rather than a bare string so that adding a
/// source later is a change to this policy rather than to every caller
/// that reports one.
enum FlutterSource {
  /// Found on PATH. The only source there is.
  path('PATH');

  const FlutterSource(this.label);

  final String label;
}

/// A located flutter, or an explanation of why there is none.
///
/// Two states, never both: [executable] is null exactly when [problem] is
/// not. Deliberately smaller than [AdbLocation]: there is no `skipped`
/// list, because with one source there is no second place that could have
/// been configured and come up empty.
class FlutterLocation {
  const FlutterLocation._({
    this.executable,
    this.source,
    this.problem,
    this.hint = '',
  });

  const FlutterLocation.found(String executable, FlutterSource source)
      : this._(executable: executable, source: source);

  const FlutterLocation.absent(String problem, {String hint = ''})
      : this._(problem: problem, hint: hint);

  /// The absolute path to hand the process layer.
  ///
  /// Never a bare name when it is found. That is the point: a path is
  /// what lets a report name the file, and it is also what stops
  /// [executableCandidates] guessing an extension, since a path is left
  /// alone there.
  ///
  /// Absolute, so that it keeps meaning the same file. A caller may run
  /// it from a directory that is not the one it was found from -
  /// `AppSession` launches `flutter run` with the application root as
  /// the child's working directory - and a relative path read from
  /// there names a different file, or none. See [resolveFlutter].
  ///
  /// Not canonical, and deliberately so: symlinks keep the spelling PATH
  /// gave them and `..` is not collapsed. This says where flutter was
  /// found, not where the filesystem ultimately keeps it.
  final String? executable;

  final FlutterSource? source;
  final String? problem;
  final String hint;

  bool get isFound => executable != null;

  /// What to run, falling back to the bare name when nothing was located.
  ///
  /// The fallback is what the tool has always done, so a machine that
  /// works today keeps working; the difference is that the reason is now
  /// available to say out loud.
  String get executableOrBareName => executable ?? flutterBareName;
}

/// The name with no extension, and what a fallback runs.
const String flutterBareName = 'flutter';

/// The names worth trying on this platform, in the order to try them.
///
/// Windows lists only the runnable wrappers. `flutter` with no extension
/// is omitted on purpose - see the note on [FlutterLocation].
List<String> flutterFileNames({bool? windows}) =>
    (windows ?? Platform.isWindows)
        ? const ['flutter.bat', 'flutter.cmd', 'flutter.exe']
        : const [flutterBareName];

/// Locates flutter on PATH, as an absolute path.
///
/// PATH order decides. The first directory holding any candidate wins, and
/// within a directory the candidates are tried in [flutterFileNames]
/// order. Nothing is executed to decide this: the checks are file
/// existence, which costs a handful of stats and cannot hang.
///
/// A PATH entry is allowed to be relative - `tools`, `.` and `..\tools`
/// are all legal, on both platforms - and such an entry used to come back
/// spelled exactly that way. A relative executable only names a file once
/// you say which directory to read it from, and the two places that read
/// it are not the same one: this checks it against [discoveryBase], and
/// `AppSession` runs it in a child whose working directory is the
/// application root. Measured on Windows:
///
/// ```text
/// PATH=tools, discovered from A, launched with workingDirectory B
///   resolver returned  tools\flutter.bat     (A\tools\flutter.bat exists)
///   the child ran      B\tools\flutter.bat   (a different SDK)
/// ```
///
/// with no `tools` under B, the launch exits 1 saying "The system cannot
/// find the path specified" and raises nothing, so the caller waits out
/// its timeout. So a relative entry is joined onto [discoveryBase] before
/// it is probed, and what comes back is the path that was checked.
/// Absolute entries are untouched, byte for byte.
///
/// Nothing is normalised and no symlink is resolved. `..` survives, and a
/// flutter reached through a link is reported where PATH put it.
///
/// [environment], [windows], [exists] and [discoveryBase] are seams for
/// testing the policy on either platform from either platform, not
/// choices for callers: [discoveryBase] defaults to the directory the
/// default [exists] would have resolved a relative candidate against.
FlutterLocation resolveFlutter({
  Map<String, String>? environment,
  bool? windows,
  bool Function(String path)? exists,
  String? discoveryBase,
}) {
  final env = environment ?? Platform.environment;
  final isWindows = windows ?? Platform.isWindows;
  final present = exists ?? (path) => File(path).existsSync();
  final base = discoveryBase ?? Directory.current.path;
  final names = flutterFileNames(windows: isWindows);

  final raw = env['PATH'] ?? env['Path'] ?? env['path'];
  for (final entry in (raw ?? '').split(isWindows ? ';' : ':')) {
    final directory = entry.trim().replaceAll('"', '');
    if (directory.isEmpty) continue;

    final from = _fromBase(directory, base, isWindows);
    for (final name in names) {
      final candidate = _join([_trimTrailingSeparator(from), name], isWindows);
      if (present(candidate)) {
        return FlutterLocation.found(candidate, FlutterSource.path);
      }
    }
  }

  return FlutterLocation.absent(
    'flutter was not found on PATH.',
    hint: 'Install Flutter and add it to PATH: https://flutter.dev',
  );
}

/// [directory] said from the filesystem root, given that a relative one
/// is relative to [base].
///
/// An absolute entry is already the answer and is handed back unchanged,
/// so the common case is not rewritten at all.
String _fromBase(String directory, String base, bool isWindows) {
  if (_isAbsolutePath(directory, isWindows)) return directory;

  final root = _trimTrailingSeparator(base);
  // A base that is itself the filesystem root keeps its own separator,
  // because trimming leaves it there. Joining regardless writes
  // `//tools`, which reads like a bug in the diagnostic somebody is
  // being asked to act on. A drive root is not this case: `C:\` trims to
  // `C:`, and `C:tools` would be relative to wherever that drive is
  // standing rather than to its root.
  return _endsWithSeparator(root)
      ? '$root$directory'
      : _join([root, directory], isWindows);
}

/// Whether [path] names a location from the root of a filesystem.
///
/// Lexical, and told which dialect to speak rather than asking the host.
/// `File(path).absolute` answers for the process it runs in, so on
/// Windows `/opt/flutter/bin/flutter` comes back as
/// `D:\repo\/opt/flutter/bin/flutter` - which would make the `windows`
/// seam quietly test the wrong platform.
///
/// The rule is the one `isAbsolutePath` already applies in the CLI, kept
/// in step by hand: the engine does not depend on the CLI, and one
/// executable's PATH policy is not reason enough to move a path utility
/// across that line.
bool _isAbsolutePath(String path, bool isWindows) {
  if (path.startsWith('/')) return true;
  if (!isWindows) return false;
  // A leading backslash covers both a root-relative path and a UNC
  // share; neither may be joined onto anything.
  return path.startsWith(r'\') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path);
}

bool _endsWithSeparator(String path) =>
    path.endsWith('/') || path.endsWith(r'\');

/// Joins path segments with the separator the host actually writes.
String _join(List<String> segments, bool isWindows) {
  final joined = segments.join('/');
  return isWindows ? joined.replaceAll('/', r'\') : joined;
}

String _trimTrailingSeparator(String path) {
  var end = path.length;
  while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
    end--;
  }
  return path.substring(0, end);
}
