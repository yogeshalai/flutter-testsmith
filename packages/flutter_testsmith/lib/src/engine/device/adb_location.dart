import 'dart:io';

import 'process_runner.dart';

/// Where `adb` is, and how that was decided.
///
/// Every adb consumer used to pass the bare name `adb` and let the
/// operating system search PATH. That is one of the places adb lives, and
/// on an ordinary Android development machine it is often not the right
/// one: Android Studio installs platform-tools inside the SDK it manages
/// and points `ANDROID_HOME` at it, while an older copy may sit on PATH
/// from some earlier install. Measured on the machine this was written
/// on: PATH held platform-tools 33.0.3 while `ANDROID_HOME` held 36.0.0,
/// and every `testsmith` command silently used the older one - including its
/// adb *server*, which the two versions fight over.
///
/// This is deliberately not a general toolchain framework. It answers one
/// question about one executable, because that executable has a location
/// convention (`<sdk>/platform-tools/adb`) that no generic PATH search
/// knows about. [executableCandidates] keeps owning the other half - what
/// filename to try once a name is chosen - and is untouched.

/// Which of the known places an adb came from.
enum AdbSource {
  /// Named outright, by `MYTEST_ADB`.
  explicit('MYTEST_ADB'),

  /// `$ANDROID_HOME/platform-tools/adb`.
  androidHome('ANDROID_HOME'),

  /// `$ANDROID_SDK_ROOT/platform-tools/adb`. Deprecated by Google, and
  /// consulted after [androidHome] for that reason - which is also the
  /// order the Flutter tool itself uses.
  androidSdkRoot('ANDROID_SDK_ROOT'),

  /// Found on PATH, with no SDK variable pointing anywhere better.
  path('PATH');

  const AdbSource(this.label);

  final String label;
}

/// A located adb, or an explanation of why there is none.
///
/// Two states, never both: [executable] is null exactly when [problem] is
/// not. [skipped] records the places that were configured but did not
/// hold an adb, so a diagnostic can say "ANDROID_HOME is set and there is
/// no platform-tools under it" rather than only "adb not found".
class AdbLocation {
  const AdbLocation._({
    this.executable,
    this.source,
    this.problem,
    this.hint = '',
    this.skipped = const [],
  });

  const AdbLocation.found(
    String executable,
    AdbSource source, {
    List<String> skipped = const [],
  }) : this._(executable: executable, source: source, skipped: skipped);

  const AdbLocation.absent(
    String problem, {
    String hint = '',
    List<String> skipped = const [],
    AdbSource? source,
  }) : this._(
          problem: problem,
          hint: hint,
          skipped: skipped,
          source: source,
        );

  /// The name or path to hand [ProcessRunner.run].
  final String? executable;

  final AdbSource? source;
  final String? problem;
  final String hint;

  /// Configured locations that were looked at and did not hold an adb.
  ///
  /// Never silent. A variable pointing at the wrong directory is a thing
  /// somebody should fix even when the run carries on without it.
  final List<String> skipped;

  bool get isFound => executable != null;

  /// An explicit `MYTEST_ADB` named something that is not there.
  ///
  /// The one absence [executableOrBareName] must not be used for.
  /// Falling back there runs a different adb than the one somebody
  /// named, which is the whole class of quiet wrongness this resolution
  /// exists to remove - and two adb versions on one machine run two
  /// servers, so the one that answers is whichever started first.
  ///
  /// Distinct from finding nothing anywhere, where the bare name stays
  /// the deliberate safety net: nobody named anything, and a machine that
  /// works today keeps working. The PATH scan now finds the `adb.bat` and
  /// `adb.cmd` a bare launch runs on Windows, so "nothing anywhere" means
  /// what it says.
  bool get namedButAbsent => !isFound && source == AdbSource.explicit;

  /// What to run, falling back to the bare name when nothing was located.
  ///
  /// The fallback is what the tool has always done, so a machine that
  /// works today keeps working; the difference is that the reason is now
  /// available to say out loud.
  String get executableOrBareName => executable ?? 'adb';
}

/// The name of the adb binary on this platform.
String adbFileName({bool? windows}) =>
    (windows ?? Platform.isWindows) ? 'adb.exe' : 'adb';

/// Locates adb, in the order a developer would expect it to be found.
///
/// 1. `MYTEST_ADB`, if set. An explicit value wins outright and is **not**
///    silently replaced when it does not exist: falling back would run a
///    different adb than the one somebody named, which is the whole class
///    of quiet wrongness this resolution exists to remove.
/// 2. `$ANDROID_HOME/platform-tools/adb`.
/// 3. `$ANDROID_SDK_ROOT/platform-tools/adb`, after ANDROID_HOME because
///    Google deprecated it and the Flutter tool orders them the same way.
/// 4. PATH.
///
/// A variable that is set but holds no adb is recorded in
/// [AdbLocation.skipped] and the search continues, so a stale
/// `ANDROID_HOME` cannot stop a machine whose PATH adb works - while
/// still being reported rather than ignored.
///
/// Nothing is executed to decide any of this. The checks are file
/// existence, which costs a handful of stats and cannot hang on a device.
///
/// [environment], [windows] and [exists] are seams for testing the policy
/// on either platform from either platform, not choices for callers.
AdbLocation resolveAdb({
  Map<String, String>? environment,
  bool? windows,
  bool Function(String path)? exists,
}) {
  final env = environment ?? Platform.environment;
  final isWindows = windows ?? Platform.isWindows;
  final present = exists ?? (path) => File(path).existsSync();
  final fileName = adbFileName(windows: isWindows);

  final explicit = _nonEmpty(env['MYTEST_ADB']);
  if (explicit != null) {
    // Checked, but never overridden. "You told me to use this and it is
    // not there" is a different sentence from "I could not find adb", and
    // only one of them names the thing to fix.
    return present(explicit)
        ? AdbLocation.found(explicit, AdbSource.explicit)
        : AdbLocation.absent(
            'MYTEST_ADB names an adb that is not there: $explicit',
            source: AdbSource.explicit,
            hint:
                'Point it at the adb executable itself, or unset it to '
                'search $_searchOrder.',
          );
  }

  final skipped = <String>[];
  for (final source in const [
    AdbSource.androidHome,
    AdbSource.androidSdkRoot,
  ]) {
    final sdk = _nonEmpty(env[source.label]);
    if (sdk == null) continue;

    final candidate = _join(
      [_trimTrailingSeparator(sdk), 'platform-tools', fileName],
      isWindows,
    );
    if (present(candidate)) {
      return AdbLocation.found(candidate, source, skipped: skipped);
    }
    skipped.add('${source.label}=$sdk has no platform-tools/$fileName');
  }

  final onPath = _firstOnPath(
    _pathNames(isWindows),
    env: env,
    isWindows: isWindows,
    present: present,
  );
  if (onPath != null) {
    return AdbLocation.found(onPath, AdbSource.path, skipped: skipped);
  }

  return AdbLocation.absent(
    'adb could not be found.',
    hint: skipped.isEmpty
        ? 'Install the Android platform-tools and set ANDROID_HOME to the '
              'SDK, put adb on PATH, or set MYTEST_ADB to the executable.'
        : '${skipped.join('; ')}. Set ANDROID_HOME to the SDK that holds '
              'platform-tools, or set MYTEST_ADB to the executable.',
    skipped: skipped,
  );
}

const String _searchOrder = 'ANDROID_HOME, then ANDROID_SDK_ROOT, then PATH';

/// The file names a bare `adb` launch would run from PATH, in the order
/// it tries them.
///
/// Taken from [executableCandidates] rather than written out again, so
/// "is there an adb on PATH" and "what does running `adb` start" cannot
/// drift into two answers. They had: this scan looked for `adb.exe`
/// alone, while the runner also starts `adb.bat` and `adb.cmd` - so a
/// wrapper on PATH was an adb for `devices` and `run` and "not found" for
/// `preflight`, `suite run` and `auth setup`. The extensionless
/// candidate is spelled as the `.exe` Windows resolves it to without a
/// shell. `PATHEXT` is still not consulted, because the runner does not.
List<String> _pathNames(bool isWindows) => <String>{
      for (final name in executableCandidates('adb', isWindows: isWindows))
        isWindows && !name.contains('.') ? '$name.exe' : name,
    }.toList();

/// The first file on PATH among [fileNames], trying each name along the
/// whole PATH before the next.
///
/// That order is the runner's: each candidate it launches is searched
/// along PATH by the operating system, so an `adb.exe` late on PATH runs
/// before an `adb.bat` early on it. Resolved to a full path rather than
/// left as a bare name, so what ran can be reported. Windows entries may
/// be quoted.
String? _firstOnPath(
  List<String> fileNames, {
  required Map<String, String> env,
  required bool isWindows,
  required bool Function(String) present,
}) {
  final raw = env['PATH'] ?? env['Path'] ?? env['path'];
  if (raw == null || raw.isEmpty) return null;

  final directories = [
    for (final entry in raw.split(isWindows ? ';' : ':'))
      if (entry.trim().replaceAll('"', '') case final directory
          when directory.isNotEmpty)
        _trimTrailingSeparator(directory),
  ];

  for (final fileName in fileNames) {
    for (final directory in directories) {
      final candidate = _join([directory, fileName], isWindows);
      if (present(candidate)) return candidate;
    }
  }
  return null;
}

/// Joins path segments with the separator the host actually writes.
///
/// `D:\Android\Sdk/platform-tools/adb.exe` runs perfectly well on
/// Windows, and reads like a bug in a diagnostic somebody is being asked
/// to act on.
String _join(List<String> segments, bool isWindows) {
  final joined = segments.join('/');
  return isWindows ? joined.replaceAll('/', r'\') : joined;
}

String? _nonEmpty(String? value) =>
    (value == null || value.trim().isEmpty) ? null : value.trim();

String _trimTrailingSeparator(String path) {
  var trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith(r'\'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}
