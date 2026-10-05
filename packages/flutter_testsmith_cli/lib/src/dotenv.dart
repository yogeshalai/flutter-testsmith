import 'dart:io';

/// Reads `KEY=VALUE` lines from a `.env` file.
///
/// Deliberately minimal - no interpolation, no exports, no multi-line
/// values. A secrets file that needs a parser with features is a
/// secrets file with somewhere for a mistake to hide.
///
/// The real environment always wins over the file, so CI (which sets
/// variables properly) is never overridden by a developer's local
/// copy that happened to get committed to a branch.
class DotEnv {
  const DotEnv(this._values);

  const DotEnv.empty() : _values = const {};

  final Map<String, String> _values;

  /// Loads the first `.env` found in [directories], in order.
  ///
  /// Every tool-side caller passes `[project, cwd]`: a project's own
  /// configuration should mean the same thing wherever the CLI was
  /// launched from, and the working directory is the accident. The three
  /// commands used to disagree about this, so one of them read a
  /// different file than the others when both directories had a `.env`.
  ///
  /// This is discovery order only. Which *value* wins is unchanged and
  /// decided elsewhere: the process environment always beats the file.
  ///
  /// A `.env` that is not there is nothing, silently: the file is
  /// optional. One that is there but cannot be decoded - UTF-16, which
  /// Notepad and PowerShell's `>` write by default - is a
  /// [FormatException] naming it. It is not skipped: the operator wrote
  /// it, usually to hold a credential, and treating it as absent would
  /// report that credential as unset, or fall through to a `.env` in the
  /// next directory that was never meant for this project.
  factory DotEnv.load(Iterable<String> directories) {
    for (final directory in directories) {
      final file = File('$directory/.env');
      if (file.existsSync()) {
        final String text;
        try {
          text = file.readAsStringSync();
        } on FileSystemException catch (error) {
          // `readAsStringSync` reports a failure to decode this way,
          // which no caller catches. Restated in the shape `generate`
          // already renders for `ai.yaml`, so the file is named once.
          // The message is dart:io's own and carries no file contents.
          throw FormatException('${file.path}: ${error.message}');
        }
        return DotEnv(parse(text));
      }
    }
    return const DotEnv.empty();
  }

  static Map<String, String> parse(String text) {
    final values = <String, String>{};

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final separator = line.indexOf('=');
      if (separator <= 0) continue;

      final key = line.substring(0, separator).trim();
      var value = line.substring(separator + 1).trim();

      // Strip one matching pair of quotes, which people add out of
      // habit and do not mean as part of the value.
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }

      if (key.isNotEmpty) values[key] = value;
    }
    return values;
  }

  /// The value of [name], preferring the real environment.
  String? operator [](String name) =>
      Platform.environment[name] ?? _values[name];

  bool get isEmpty => _values.isEmpty;

  /// Variable names only. Never the values - this exists so `doctor`
  /// can say what is configured without printing a secret.
  List<String> get names => _values.keys.toList()..sort();
}
