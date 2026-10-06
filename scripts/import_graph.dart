// The import-graph form of the two layering rules, and the dependency
// policy for the one package that is published (ADR-0011).
//
// Until now the rules were package-level: flutter_testsmith may not
// *depend on* flutter_testsmith_engine, and the engine may not *depend on*
// Flutter. pub.dev forbids a published package from depending on
// anything that is not itself on pub.dev, so the five component packages
// are moving inside flutter_testsmith - and inside one package a
// dependency declaration can no longer say anything. What the rules
// always protected is what an *import* reaches, so that is what is
// checked here:
//
//   Rule A  Nothing reachable from lib/flutter_testsmith.dart imports
//           engine, CLI, Figma or AI code. The application under test
//           must not link the testing brain.
//
//   Rule B  Nothing reachable from protocol, engine, CLI, Figma or AI
//           code imports package:flutter, dart:ui, a package that depends
//           on the Flutter SDK, or the SDK component itself. That is what
//           keeps the CLI a native binary and its tests Flutter-free.
//
//   Rule C  The published package's `dependencies:` are hosted on pub.dev
//           or come from the Flutter SDK. A dependency on a workspace
//           member is *pending* rather than wrong while the migration is
//           under way: it disappears when that member moves in. A release
//           build treats anything pending as a failure.
//
// Migration-aware by construction. Every component has a legacy location
// (its own package, before ADR-0011) and a destination (a directory inside
// flutter_testsmith). A file is classified by its path against both, so
// the same rules hold before the first move, after each one, and after
// the last - and nothing about the future layout is assumed to exist
// already.
//
// Directives are read with the real Dart parser, so a conditional import,
// an export, a `part` file or a double-quoted URI is seen exactly as the
// compiler sees it. package: URIs are resolved through
// .dart_tool/package_config.json, the same file `dart` uses.
//
// Kept separate from the script that runs it, like package_boundaries.dart,
// so every rule is unit-testable against a synthetic tree.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:yaml/yaml.dart';

/// The parts of Flutter Testsmith whose boundaries the rules describe.
enum Component { sdk, protocol, engine, cli, figma, ai }

/// The components that must never reach Flutter (Rule B).
const Set<Component> flutterFreeComponents = {
  Component.protocol,
  Component.engine,
  Component.cli,
  Component.figma,
  Component.ai,
};

/// The components the application under test must never link (Rule A).
const Set<Component> testingBrain = {
  Component.engine,
  Component.cli,
  Component.figma,
  Component.ai,
};

/// Where one component's shipped source lives, before and after it moves
/// into the published package. Entries are repository-relative and use
/// forward slashes; an entry is a directory or a single file.
class ComponentLayout {
  const ComponentLayout({required this.legacy, required this.destination});

  /// Its own package, before ADR-0011.
  final List<String> legacy;

  /// Inside packages/flutter_testsmith, after the move (ADR-0011).
  final List<String> destination;
}

/// The published package, and the library an application imports.
const String publishedPackageDir = 'packages/flutter_testsmith';
const String sdkEntry = '$publishedPackageDir/lib/flutter_testsmith.dart';

/// Every component's legacy and destination locations.
///
/// The SDK has always lived in the published package, so it has no legacy
/// location. Its destination is the whole of lib/: the longest matching
/// entry wins, so lib/src/engine/ is the engine, not the SDK, and the
/// public libraries lib/engine.dart, lib/figma.dart, lib/ai.dart and
/// lib/protocol.dart belong to their components rather than to the SDK.
///
/// lib/protocol.dart was added with the protocol's move (ADR-0011 step 6):
/// it is the protocol's barrel, the same file that was
/// flutter_testsmith_protocol.dart, so components that import it reach
/// protocol code - not the SDK, which a lib/ prefix match alone would say.
const Map<Component, ComponentLayout> layouts = {
  Component.sdk: ComponentLayout(
    legacy: [],
    destination: ['$publishedPackageDir/lib'],
  ),
  Component.protocol: ComponentLayout(
    legacy: ['packages/flutter_testsmith_protocol/lib'],
    destination: [
      '$publishedPackageDir/lib/src/protocol',
      '$publishedPackageDir/lib/protocol.dart',
    ],
  ),
  Component.engine: ComponentLayout(
    legacy: ['packages/flutter_testsmith_engine/lib'],
    destination: [
      '$publishedPackageDir/lib/src/engine',
      '$publishedPackageDir/lib/engine.dart',
    ],
  ),
  Component.cli: ComponentLayout(
    legacy: [
      'packages/flutter_testsmith_cli/lib',
      'packages/flutter_testsmith_cli/bin',
    ],
    destination: [
      '$publishedPackageDir/lib/src/cli',
      '$publishedPackageDir/bin',
    ],
  ),
  Component.figma: ComponentLayout(
    legacy: ['integrations/flutter_testsmith_figma/lib'],
    destination: [
      '$publishedPackageDir/lib/src/figma',
      '$publishedPackageDir/lib/figma.dart',
    ],
  ),
  Component.ai: ComponentLayout(
    legacy: ['integrations/ai_client/lib'],
    destination: [
      '$publishedPackageDir/lib/src/ai',
      '$publishedPackageDir/lib/ai.dart',
    ],
  ),
};

/// Which component a repository-relative path belongs to, or null when it
/// belongs to none (an example, a script, a test).
Component? classify(
  String relativePath, [
  Map<Component, ComponentLayout> layout = layouts,
]) {
  final path = relativePath.replaceAll(r'\', '/');
  Component? best;
  var bestLength = -1;
  for (final MapEntry(key: component, value: where) in layout.entries) {
    for (final prefix in [...where.legacy, ...where.destination]) {
      final matches = path == prefix || path.startsWith('$prefix/');
      if (matches && prefix.length > bestLength) {
        best = component;
        bestLength = prefix.length;
      }
    }
  }
  return best;
}

/// Where a component's source was actually found.
enum Placement { legacy, destination, split, absent }

/// Reports, for each component, whether its Dart source is in its legacy
/// package, in its destination, in both (a move in progress), or nowhere.
///
/// A component that is absent from both is reported, never assumed moved.
Map<Component, Placement> placements(
  String repoRoot, [
  Map<Component, ComponentLayout> layout = layouts,
]) {
  bool hasDart(List<String> entries) =>
      entries.any((e) => _dartFilesUnder(repoRoot, e).isNotEmpty);
  return {
    for (final MapEntry(key: component, value: where) in layout.entries)
      component: switch ((hasDart(where.legacy), hasDart(where.destination))) {
        (true, true) => Placement.split,
        (true, false) => Placement.legacy,
        (false, true) => Placement.destination,
        (false, false) => Placement.absent,
      },
  };
}

/// One link in the chain from an entry point to what it reached.
class Reached {
  const Reached(this.target, this.via);

  /// Repository-relative path, `package:<name>` or `dart:<library>`.
  final String target;

  /// The file that imported it, or null for an entry point.
  final String? via;
}

/// Everything a set of entry points can reach.
class Closure {
  /// Repository-local files, each with the file that first imported it.
  final Map<String, Reached> files = {};

  /// External packages, keyed `package:<name>`, with their first importer.
  final Map<String, Reached> packages = {};

  /// `dart:` libraries, keyed `dart:<name>`, with their first importer.
  final Map<String, Reached> dartLibraries = {};

  /// Directives that could not be resolved, as human-readable text.
  final List<String> unresolved = [];

  /// The import chain from an entry point to [target], entry first.
  List<String> chainTo(String target) {
    final chain = <String>[];
    String? current = target;
    final seen = <String>{};
    while (current != null && seen.add(current)) {
      chain.add(current);
      current = (files[current] ?? packages[current] ?? dartLibraries[current])
          ?.via;
    }
    return chain.reversed.toList();
  }
}

/// Reads directives and resolves them, for one repository.
class ImportGraph {
  ImportGraph._(this.repoRoot, this._packageRoots, this._localPackages);

  /// Builds the graph from [repoRoot]/.dart_tool/package_config.json.
  ///
  /// Throws a [StateError] naming the remedy when that file is missing:
  /// guessing a package's location instead would make every result
  /// below meaningless.
  factory ImportGraph.load(String repoRoot) {
    final config = File('$repoRoot/.dart_tool/package_config.json');
    if (!config.existsSync()) {
      throw StateError(
        '${config.path} does not exist. Run `dart pub get` at the '
        'repository root first.',
      );
    }
    // Absolute, or every relative rootUri would resolve against the
    // current directory and no workspace member would count as local.
    final base = config.absolute.parent.uri;
    final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    final roots = <String, String>{};
    final local = <String>{};
    final repo = _canonicalDirectory(repoRoot);
    for (final entry in (json['packages'] as List<Object?>)
        .cast<Map<String, Object?>>()) {
      final name = entry['name'] as String;
      final rootUri = base.resolve(_withSlash(entry['rootUri'] as String));
      final packageUri = rootUri.resolve(
        _withSlash((entry['packageUri'] as String?) ?? 'lib/'),
      );
      final root = _normalise(rootUri.toFilePath());
      roots[name] = _normalise(packageUri.toFilePath());
      if (root == repo || root.startsWith('$repo/')) local.add(name);
      // The root package's own directory is the repository itself; it is
      // not a component and nothing imports it.
    }
    return ImportGraph._(repo, roots, local);
  }

  /// Absolute, forward-slashed repository root.
  final String repoRoot;

  /// package name -> absolute directory that `package:<name>/` maps to.
  final Map<String, String> _packageRoots;

  /// Packages whose source lives in this repository. Imports into them
  /// are followed; imports into anything else stop at the package name.
  final Set<String> _localPackages;

  final Map<String, List<String>> _directiveCache = {};
  final Map<String, bool> _flutterCache = {};

  /// The URIs of every import, export and part directive in [file],
  /// including every branch of a conditional import or export.
  List<String> directiveUris(String file) => _directiveCache.putIfAbsent(file, () {
        final result = parseString(
          content: File(file).readAsStringSync(),
          path: file,
          throwIfDiagnostics: false,
        );
        final uris = <String>[];
        for (final directive in result.unit.directives) {
          if (directive is NamespaceDirective) {
            uris.add(directive.uri.stringValue ?? '');
            for (final configuration in directive.configurations) {
              uris.add(configuration.uri.stringValue ?? '');
            }
          } else if (directive is PartDirective) {
            uris.add(directive.uri.stringValue ?? '');
          }
        }
        return uris;
      });

  /// Follows every directive from [entries] through repository-local
  /// files. External packages and `dart:` libraries are recorded, not
  /// entered.
  Closure closure(Iterable<String> entries) {
    final closure = Closure();
    final queue = <String>[];
    for (final entry in entries) {
      final file = _absolute(entry);
      final key = _relative(file);
      if (!closure.files.containsKey(key)) {
        closure.files[key] = Reached(key, null);
        queue.add(file);
      }
    }
    while (queue.isNotEmpty) {
      final file = queue.removeLast();
      final from = _relative(file);
      for (final uri in directiveUris(file)) {
        final resolved = _resolve(file, uri);
        switch (resolved) {
          case _Local(:final path):
            final key = _relative(path);
            if (!File(path).existsSync()) {
              closure.unresolved.add('$from: "$uri" names $key, which does not exist');
            } else if (!closure.files.containsKey(key)) {
              closure.files[key] = Reached(key, from);
              queue.add(path);
            }
          case _External(:final name):
            closure.packages.putIfAbsent('package:$name', () => Reached('package:$name', from));
          case _Dart(:final library):
            closure.dartLibraries.putIfAbsent('dart:$library', () => Reached('dart:$library', from));
          case _Unresolved(:final reason):
            closure.unresolved.add('$from: "$uri" $reason');
        }
      }
    }
    return closure;
  }

  /// Whether external package [name] is, or transitively depends on, the
  /// Flutter SDK, judged from the `dependencies:` of each pubspec.
  bool dependsOnFlutter(String name) {
    if (name == 'flutter' || name == 'sky_engine') return true;
    final cached = _flutterCache[name];
    if (cached != null) return cached;
    _flutterCache[name] = false; // Cycle guard; overwritten below.
    final lib = _packageRoots[name];
    var result = false;
    if (lib != null) {
      final pubspec = File('${Directory(lib).parent.path}/pubspec.yaml');
      if (pubspec.existsSync()) {
        final yaml = loadYaml(pubspec.readAsStringSync());
        final dependencies = yaml is YamlMap ? yaml['dependencies'] : null;
        if (dependencies is YamlMap) {
          for (final MapEntry(key: dep, value: spec) in dependencies.entries) {
            if (spec is YamlMap && spec['sdk'] == 'flutter') result = true;
            if (!result && dependsOnFlutter(dep.toString())) result = true;
            if (result) break;
          }
        }
      }
    }
    return _flutterCache[name] = result;
  }

  _Resolution _resolve(String fromFile, String uri) {
    if (uri.isEmpty) return const _Unresolved('is not a plain string URI');
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return const _Unresolved('is not a valid URI');
    if (parsed.scheme == 'dart') return _Dart(parsed.path);
    if (parsed.scheme == 'package') {
      final slash = parsed.path.indexOf('/');
      if (slash <= 0) return const _Unresolved('is not package:<name>/<path>');
      final name = parsed.path.substring(0, slash);
      final root = _packageRoots[name];
      if (root == null) {
        return _Unresolved('names package "$name", which package_config.json does not list');
      }
      if (!_localPackages.contains(name)) return _External(name);
      return _Local(_normalise('$root/${parsed.path.substring(slash + 1)}'));
    }
    if (parsed.hasScheme) return _Unresolved('uses the unsupported "${parsed.scheme}:" scheme');
    final target = File(fromFile).parent.uri.resolveUri(parsed);
    return _Local(_normalise(target.toFilePath()));
  }

  String _absolute(String repoRelative) =>
      _normalise(File('$repoRoot/$repoRelative').absolute.path);

  String _relative(String absolute) =>
      absolute.startsWith('$repoRoot/') ? absolute.substring(repoRoot.length + 1) : absolute;
}

/// One rule broken, with the evidence.
class Violation {
  const Violation(this.rule, this.message);
  final String rule;
  final String message;
  @override
  String toString() => 'Rule $rule  $message';
}

/// Rule A: what the application under test can reach.
///
/// [entry] is repository-relative. Its closure may contain SDK and
/// protocol files; any file classified as engine, CLI, Figma or AI is a
/// violation, reported with the chain of imports that reaches it.
List<Violation> sdkIsolationViolations(
  ImportGraph graph, {
  String entry = sdkEntry,
  Map<Component, ComponentLayout> layout = layouts,
}) {
  if (!File('${graph.repoRoot}/$entry').existsSync()) {
    return [Violation('A', '$entry does not exist, so nothing it reaches can be checked')];
  }
  final closure = graph.closure([entry]);
  final violations = <Violation>[
    for (final reason in closure.unresolved)
      Violation('A', 'cannot resolve an import reachable from $entry: $reason'),
  ];
  final offending = <Component, List<String>>{};
  for (final file in closure.files.keys) {
    final component = classify(file, layout);
    if (component != null && testingBrain.contains(component)) {
      (offending[component] ??= []).add(file);
    }
  }
  for (final MapEntry(key: component, value: files) in offending.entries) {
    violations.add(Violation(
      'A',
      '$entry reaches ${files.length} ${component.name} file(s), first through: '
      '${closure.chainTo(files.first).join(' -> ')}',
    ));
  }
  return violations;
}

/// Rule B: what each Flutter-free component can reach.
///
/// Every Dart file in the component's present locations is an entry
/// point. Reaching `dart:ui`, `package:flutter`, any package that depends
/// on the Flutter SDK, or any SDK-component file is a violation.
List<Violation> flutterFreeViolations(
  ImportGraph graph, {
  Map<Component, ComponentLayout> layout = layouts,
}) {
  final violations = <Violation>[];
  for (final component in flutterFreeComponents) {
    final entries = componentFiles(graph.repoRoot, component, layout);
    if (entries.isEmpty) continue;
    final closure = graph.closure(entries);
    final name = component.name;
    for (final reason in closure.unresolved) {
      violations.add(Violation('B', 'cannot resolve an import reachable from $name: $reason'));
    }
    if (closure.dartLibraries.containsKey('dart:ui')) {
      violations.add(Violation('B', '$name reaches dart:ui: ${closure.chainTo('dart:ui').join(' -> ')}'));
    }
    for (final package in closure.packages.keys) {
      if (graph.dependsOnFlutter(package.substring('package:'.length))) {
        violations.add(Violation(
          'B',
          '$name reaches $package, which is or depends on the Flutter SDK: '
          '${closure.chainTo(package).join(' -> ')}',
        ));
      }
    }
    final sdkFiles = [
      for (final file in closure.files.keys)
        if (classify(file, layout) == Component.sdk) file,
    ];
    if (sdkFiles.isNotEmpty) {
      violations.add(Violation(
        'B',
        '$name reaches ${sdkFiles.length} file(s) of the Flutter SDK component, first through: '
        '${closure.chainTo(sdkFiles.first).join(' -> ')}',
      ));
    }
  }
  return violations;
}

/// The outcome of Rule C.
class PublishPolicy {
  PublishPolicy(this.violations, this.pending);

  /// Dependencies a consumer of the published package could never
  /// resolve. Always a failure.
  final List<Violation> violations;

  /// What still stands between the current tree and a publishable one.
  /// Expected during the migration; a failure in release mode.
  final List<String> pending;
}

/// Hosts a published package's dependencies may come from.
const Set<String> _pubDevHosts = {'https://pub.dev', 'https://pub.dartlang.org'};

/// Rule C: the published package's dependency policy.
///
/// [pubspec] is the published package's pubspec; [workspaceMembers] are
/// the names of the other packages in this workspace, none of which is
/// on pub.dev. When [componentPlacements] is given, a component still in
/// its legacy location is listed as pending too, as is `publish_to`.
PublishPolicy publishPolicy(
  YamlMap pubspec, {
  required Set<String> workspaceMembers,
  Map<Component, Placement>? componentPlacements,
}) {
  final violations = <Violation>[];
  final pending = <String>[];
  final package = pubspec['name']?.toString() ?? 'the published package';
  final dependencies = pubspec['dependencies'];
  if (dependencies is YamlMap) {
    for (final MapEntry(key: rawName, value: spec) in dependencies.entries) {
      final name = rawName.toString();
      var hosted = true;
      if (spec is YamlMap) {
        if (spec.containsKey('path') || spec.containsKey('git')) {
          final source = spec.containsKey('path') ? 'path' : 'git';
          violations.add(Violation('C', '$package depends on $name through a "$source" source; pub.dev refuses to publish it'));
          continue;
        }
        if (spec.containsKey('sdk')) {
          hosted = false;
          if (spec['sdk'] != 'flutter') {
            violations.add(Violation('C', '$package depends on $name from the "${spec['sdk']}" SDK; only the Flutter SDK is allowed'));
          }
        }
        // `hosted:` is either a URL or a map holding one. Without a URL it
        // means the default server, which is pub.dev.
        final host = spec['hosted'];
        final url = host is YamlMap
            ? host['url']?.toString()
            : (host is String && host.contains('://') ? host : null);
        if (url != null && !_pubDevHosts.contains(url.replaceAll(RegExp(r'/+$'), ''))) {
          violations.add(Violation('C', '$package depends on $name from $url; a published package may only use pub.dev'));
          continue;
        }
      }
      if (hosted && workspaceMembers.contains(name)) {
        pending.add('$package depends on workspace member $name, which is not on pub.dev; '
            'it disappears when $name moves into $package');
      }
    }
  }
  if (componentPlacements != null) {
    for (final MapEntry(key: component, value: placement) in componentPlacements.entries) {
      if (component == Component.sdk) continue;
      if (placement == Placement.legacy || placement == Placement.split) {
        pending.add('${component.name} is ${placement == Placement.split ? 'split between its own package and' : 'still outside'} $package');
      }
    }
  }
  if (pubspec['publish_to']?.toString() == 'none') {
    pending.add('$package still declares publish_to: none (removed at release, after the release-readiness audit)');
  }
  return PublishPolicy(violations, pending);
}

/// The names of every workspace member except [except], read from the
/// root pubspec's `workspace:` list.
Set<String> workspaceMemberNames(String repoRoot, {required String except}) {
  final root = loadYaml(File('$repoRoot/pubspec.yaml').readAsStringSync());
  final members = root is YamlMap ? root['workspace'] : null;
  if (members is! YamlList) return const {};
  final names = <String>{};
  for (final member in members) {
    final pubspec = File('$repoRoot/$member/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final yaml = loadYaml(pubspec.readAsStringSync());
    final name = yaml is YamlMap ? yaml['name']?.toString() : null;
    if (name != null && name != except) names.add(name);
  }
  return names;
}

/// The repository-relative Dart files of [component] that exist now, in
/// its legacy location, its destination, or both.
List<String> componentFiles(
  String repoRoot,
  Component component, [
  Map<Component, ComponentLayout> layout = layouts,
]) {
  final where = layout[component];
  if (where == null) return const [];
  return [
    for (final location in [...where.legacy, ...where.destination])
      ..._dartFilesUnder(repoRoot, location),
  ];
}

List<String> _dartFilesUnder(String repoRoot, String entry) {
  final root = _canonicalDirectory(repoRoot);
  final file = File('$root/$entry');
  if (file.existsSync()) return entry.endsWith('.dart') ? [entry] : const [];
  final dir = Directory('$root/$entry');
  if (!dir.existsSync()) return const [];
  return [
    for (final f in dir.listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart')) _normalise(f.path).substring(root.length + 1),
  ]..sort();
}

/// An absolute, forward-slashed directory path with `.` and `..` removed.
/// `Directory('.').absolute.path` keeps a trailing `/.`, which would make
/// every repository-relative comparison silently miss.
String _canonicalDirectory(String path) =>
    _normalise(Directory(path).absolute.uri.normalizePath().toFilePath());

String _normalise(String path) {
  var p = path.replaceAll(r'\', '/');
  // Windows drive letters differ in case between sources; compare one form.
  if (RegExp(r'^[A-Za-z]:/').hasMatch(p)) p = p[0].toLowerCase() + p.substring(1);
  return p.endsWith('/') ? p.substring(0, p.length - 1) : p;
}

String _withSlash(String uri) => uri.endsWith('/') ? uri : '$uri/';

sealed class _Resolution {
  const _Resolution();
}

class _Local extends _Resolution {
  const _Local(this.path);
  final String path;
}

class _External extends _Resolution {
  const _External(this.name);
  final String name;
}

class _Dart extends _Resolution {
  const _Dart(this.library);
  final String library;
}

class _Unresolved extends _Resolution {
  const _Unresolved(this.reason);
  final String reason;
}
