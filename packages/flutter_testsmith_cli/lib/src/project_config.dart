import 'dart:convert';
import 'dart:io';

import 'package:ai_client/ai_client.dart';
import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// What a project declares about its own screens.
///
/// Shared by `testsmith run` and `testsmith suite run` so a screen's mappings
/// and its design resolve identically either way. A suite that read them
/// differently would be a second definition of what a project is.

/// Two files describe one screen, and there is no way to choose.
///
/// Both loaders below turn a directory of files into a map keyed by the
/// screen each one names. A second file for a screen used to replace the
/// first, and because the files arrive in `Directory.listSync()` order -
/// which `dart:io` does not specify and which is not the same on every
/// filesystem - *which* configuration survived was a property of the
/// machine. A project could validate against one mapping here and the
/// other in CI, and report success both times.
///
/// So it is refused. This platform does not guess between candidates
/// anywhere else either: `selectSoleDevice` will not pick one of several
/// devices, and duplicate test ids in a snapshot fail `inspect` rather
/// than resolving to the first. A screen described twice is the same
/// question asked of configuration.
///
/// Deliberately a type rather than a line through `onProblem`. A
/// malformed spec is advisory - it describes no screen, so it conflicts
/// with nothing and the rest still load - and the two severities have to
/// stay apart at the boundary rather than by reading their text.
class DuplicateScreenException implements Exception {
  DuplicateScreenException(this.screen, Iterable<String> paths)
      // Sorted for a stable message on every filesystem. Presentation
      // only: neither file is the winner, because there is no winner.
      : paths = List<String>.unmodifiable(paths.toList()..sort());

  final String screen;

  /// Every file claiming [screen], in no meaningful order.
  final List<String> paths;

  @override
  String toString() => 'Duplicate screen configuration for "$screen":\n'
      '${paths.map((path) => '  $path').join('\n')}\n'
      'One screen takes one configuration. Remove or rename one of these, '
      'or give them different screens.';
}

/// Indexes [files] by the screen each one names, refusing a repeat.
Map<String, T> _byScreen<T>(
  Iterable<({String path, String screen, T value})> files,
) {
  final loaded = <String, T>{};
  final sources = <String, String>{};

  for (final file in files) {
    final first = sources[file.screen];
    if (first != null) {
      throw DuplicateScreenException(file.screen, [first, file.path]);
    }
    sources[file.screen] = file.path;
    loaded[file.screen] = file.value;
  }
  return loaded;
}

/// Per-screen mappings in `<project>/mappings`, indexed by screen.
///
/// Throws [DuplicateScreenException] when two files name one screen.
Future<Map<String, MappingsFile>> loadMappings(Directory project) async {
  final directory = Directory('${project.path}/mappings');
  if (!directory.existsSync()) return const {};

  final files = <({String path, String screen, MappingsFile value})>[];
  for (final entry in directory.listSync().whereType<File>()) {
    if (!entry.path.endsWith('.yaml')) continue;
    final String text;
    try {
      text = await entry.readAsString();
    } on FileSystemException catch (error) {
      // `readAsString` decodes as well as reads, and reports a failure
      // to decode as a `FileSystemException` - not a `FormatException`,
      // so not what any of this loader's four callers catches, and not
      // caught over them either. A mapping saved in an encoding this
      // cannot read ended `run`, `preflight`, `suite run` and
      // `generate` at 255.
      //
      // Restated as the exception those callers already render, the way
      // `_readFigma` restates one from the tolerance parser. Each of
      // them then does what it already does with a mapping it cannot
      // use - `run` exits 1, `suite run` writes the blocked suite.json
      // row - without any of them learning a second failure to handle.
      throw MappingsFormatException(entry.path, error.message);
    }

    final file = MappingsFile.parse(text, source: entry.path);
    files.add((path: entry.path, screen: file.screen, value: file));
  }
  return _byScreen(files);
}

/// The one directory a run looks in for designs, and for their cache.
///
/// Named here, beside the function that reads it, because the command
/// that *writes* into it has an `--out` and this has none: a run takes
/// no output directory, so the two can only agree by referring to the
/// same convention.
const String figmaDirectoryName = 'figma';

/// The normalised designs in `<project>/figma`, indexed by screen.
///
/// Only `*.json` written by `testsmith figma pull` is read. The `.cache`
/// directory holds raw Figma API responses and the `.mapping.yaml` files
/// are inputs to normalisation, not specs.
///
/// Throws [DuplicateScreenException] when two specs name one screen. A
/// spec that will not parse stays a report through [onProblem]: it
/// describes no screen, so it takes nothing away from another.
Future<Map<String, FigmaScreenSpec>> loadFigmaSpecs(
  Directory project, {
  void Function(String)? onProblem,
}) async {
  final directory = Directory('${project.path}/$figmaDirectoryName');
  if (!directory.existsSync()) return const {};

  final files = <({String path, String screen, FigmaScreenSpec value})>[];
  for (final entry in directory.listSync().whereType<File>()) {
    if (!entry.path.endsWith('.json')) continue;
    try {
      final decoded = jsonDecode(await entry.readAsString());
      if (decoded is! Map) {
        // The one shape the guard below did not cover. It catches what
        // `jsonDecode` raises for text that is not JSON, and what
        // `fromJson` raises for an object that is not a spec; a valid
        // JSON document whose root is a list, a string, a number, a
        // boolean or null is neither, and the cast this replaces left a
        // `TypeError` - not a `FormatException`, and not an `Exception`
        // at all - which walked past it and ended `run`, `suite run`
        // and `preflight` at 255 without naming the file.
        throw const FormatException(
          'a design must be a JSON object, the shape `testsmith figma '
          'pull` writes',
        );
      }
      final spec = FigmaScreenSpec.fromJson(decoded.cast<String, Object?>());
      files.add((path: entry.path, screen: spec.screen, value: spec));
    } on FormatException catch (error) {
      // A malformed spec must not quietly disable design checking.
      onProblem?.call('  ! ignoring ${entry.path}: $error');
    } on FileSystemException catch (error) {
      // The other way the read above fails, and the same answer: a
      // design nobody can read describes no screen, so it takes nothing
      // away from another. Advisory here where a mapping is fatal,
      // which is the whole difference between the two directories.
      //
      // The message rather than the exception, unlike the clause above:
      // a `FileSystemException` prints the path it was given, and the
      // line already opens with it. `_readFigma` says why that matters
      // - both layers name the file, and saying it twice reads like a
      // bug.
      onProblem?.call('  ! ignoring ${entry.path}: ${error.message}');
    }
  }
  return _byScreen(files);
}

/// The project's `ai.yaml`, then [provider] and [model] from the command
/// line on top of it, or [LlmConfig.defaults] when there is no file.
///
/// One reader for the two commands that use it. `generate` guarded a
/// file it could not decode and `run` did not: `readAsStringSync`
/// reports that as a `FileSystemException`, not the `FormatException`
/// `run` caught, so `run --ai` ended at 255 after the device run. Every
/// way the file cannot be used is a [FormatException] naming it - the
/// shape `LlmConfig.parse` already uses for its own complaints.
LlmConfig loadAiConfig(
  Directory project, {
  String? provider,
  String? model,
}) {
  final file = File('${project.path}/ai.yaml');
  var config = LlmConfig.defaults;
  if (file.existsSync()) {
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (error) {
      throw FormatException('${file.path}: ${error.message}');
    }
    config = LlmConfig.parse(text, source: file.path);
  }
  if (provider != null || model != null) {
    config = config.copyWith(provider: provider, model: model);
  }
  return config;
}

/// Writes a run's `result.json` and `report.html` into [directory].
///
/// Shared by `testsmith run` and the suite runner, so a test's report is
/// the same file either way - and so a suite that records an output
/// directory per test actually has one. A recorded path to a report
/// nobody wrote is worse than no path at all: it looks like evidence.
///
/// JSON first, and the HTML rendered from it, so the two cannot disagree
/// about what happened.
Future<({File json, File html})> writeRunReports(
  RunResult result,
  Directory directory,
) async {
  await directory.create(recursive: true);
  final json = result.toJson();

  final jsonFile = File('${directory.path}/result.json');
  await jsonFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(json),
  );

  final htmlFile = File('${directory.path}/report.html');
  await htmlFile.writeAsString(const HtmlReporter().render(json));

  return (json: jsonFile, html: htmlFile);
}

/// Reads the device profile named [id] from `<project>/device_profiles`.
///
/// Returns null when there is no such file, so the caller can say which
/// profiles do exist rather than throwing a path at the reader.
Future<DeviceProfile?> loadDeviceProfile(
  Directory project,
  String id,
) async {
  final file = File('${project.path}/device_profiles/$id.yaml');
  if (!file.existsSync()) return null;

  final String text;
  try {
    text = await file.readAsString();
  } on FileSystemException catch (error) {
    // The same restating as `loadMappings` above, into the exception
    // `preflight`, `suite run` and `auth setup` already render. Null is
    // deliberately not the answer: that means "no such profile", and
    // saying it about a file that is plainly there would send somebody
    // looking for a profile they had already written.
    throw ProfileFormatException(file.path, error.message);
  }

  return DeviceProfile.parse(text, source: file.path);
}

/// The profile ids a project defines, for a "did you mean" list.
List<String> availableProfiles(Directory project) {
  final directory = Directory('${project.path}/device_profiles');
  if (!directory.existsSync()) return const [];
  return [
    for (final entry in directory.listSync().whereType<File>())
      if (entry.path.endsWith('.yaml'))
        entry.uri.pathSegments.last.replaceAll('.yaml', ''),
  ]..sort();
}
