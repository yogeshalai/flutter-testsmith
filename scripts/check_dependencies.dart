// Enforces the two dependency rules that actually matter.
//
// Architectural rules that are only written down erode. These two are
// load-bearing enough to be checked mechanically:
//
//   1. flutter_testsmith must not depend on flutter_testsmith_engine.
//      The application under test must not link the testing brain.
//
//   2. flutter_testsmith_engine must not depend on Flutter.
//      This is what lets the CLI compile to a native binary and lets
//      validation logic be unit tested in milliseconds without a Flutter
//      harness. It is the single most valuable constraint in the layout.
//
//   3. The packages an external application consumes — flutter_testsmith and
//      flutter_testsmith_protocol — must not reach back into this repository through a
//      path or git dependency. An application that fetched them from a
//      package repository cannot resolve such a dependency, which is
//      finding E-01.
//
// Rules 1 and 2 are package-level, and the components are moving inside
// the one published package, flutter_testsmith (ADR-0011), where a
// package-level rule can say nothing. Their import-graph form runs here
// too, from scripts/import_graph.dart, and holds at every migration step:
//
//   A  nothing reachable from lib/flutter_testsmith.dart imports engine,
//      CLI, Figma or AI code;
//   B  nothing reachable from protocol, engine, CLI, Figma or AI code
//      reaches Flutter;
//   C  the published package depends only on pub.dev and the Flutter
//      SDK. A dependency on a workspace member is reported as pending
//      until that member moves in; `--release` makes pending a failure.
//
// Run: dart run scripts/check_dependencies.dart [--release]
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'import_graph.dart';
import 'package_boundaries.dart';

/// The legacy package each package-level rule names, mapped to the
/// component it becomes. A package that no longer exists is accepted only
/// when its component has demonstrably arrived in flutter_testsmith.
const Map<String, Component> _componentOf = {
  'flutter_testsmith_protocol': Component.protocol,
  'flutter_testsmith_engine': Component.engine,
};

/// package -> dependencies it must not have (directly or transitively via
/// its own pubspec).
const Map<String, List<String>> forbidden = {
  'flutter_testsmith_protocol': ['flutter', 'flutter_testsmith', 'flutter_testsmith_engine', 'flutter_testsmith_cli'],
  'flutter_testsmith': ['flutter_testsmith_engine', 'flutter_testsmith_cli'],
  'flutter_testsmith_engine': ['flutter', 'flutter_testsmith'],
};

void main(List<String> args) {
  final release = args.contains('--release');
  var failures = 0;
  final where = placements('.');

  for (final entry in forbidden.entries) {
    final package = entry.key;
    final pubspec = File('packages/$package/pubspec.yaml');
    if (!pubspec.existsSync()) {
      final component = _componentOf[package];
      if (component != null && where[component] == Placement.destination) {
        stdout.writeln(
          'ok  $package was merged into flutter_testsmith; '
          'its rule is enforced by rules A and B below',
        );
        continue;
      }
      stderr.writeln('MISSING  packages/$package/pubspec.yaml');
      failures++;
      continue;
    }

    final declared = _declaredDependencies(pubspec.readAsStringSync());

    for (final banned in entry.value) {
      if (declared.contains(banned)) {
        stderr.writeln(
          'VIOLATION  $package depends on $banned.\n'
          '           See ARCHITECTURE section 6 for why this is forbidden.',
        );
        failures++;
      }
    }

    final allowed = entry.value.join(', ');
    stdout.writeln(
      failures == 0
          ? 'ok  $package does not depend on: $allowed'
          : '    $package checked against: $allowed',
    );
  }

  // Rule 3: nothing an external application depends on may point back
  // into this repository.
  for (final package in externallyConsumablePackages) {
    final pubspec = File('packages/$package/pubspec.yaml');
    if (!pubspec.existsSync()) continue;

    final violations = externallyConsumableViolations(
      package,
      loadYaml(pubspec.readAsStringSync()) as YamlMap,
    );
    for (final violation in violations) {
      stderr.writeln('VIOLATION  $violation');
      failures++;
    }
    if (violations.isEmpty) {
      stdout.writeln('ok  $package is consumable outside this repository');
    }
  }

  // Also verify no Dart source in flutter_testsmith_engine imports Flutter, which a
  // pubspec check alone would miss if the dependency were transitive.
  final engineLib = Directory('packages/flutter_testsmith_engine/lib');
  if (engineLib.existsSync()) {
    for (final file in engineLib
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      if (source.contains("import 'package:flutter/") ||
          source.contains('import "package:flutter/')) {
        stderr.writeln('VIOLATION  ${file.path} imports Flutter');
        failures++;
      }
    }
    stdout.writeln('ok  no Flutter import in flutter_testsmith_engine sources');
  }

  failures += _importGraphRules(release: release, placement: where);

  if (failures > 0) {
    stderr.writeln('\n$failures dependency violation(s).');
    exit(1);
  }
  stdout.writeln('\nAll dependency rules hold.');
}

/// Rules A, B and C (ADR-0011). Returns the number of failures.
int _importGraphRules({
  required bool release,
  required Map<Component, Placement> placement,
}) {
  final ImportGraph graph;
  try {
    graph = ImportGraph.load('.');
  } on StateError catch (e) {
    stderr.writeln('VIOLATION  ${e.message}');
    return 1;
  }
  var failures = 0;

  stdout.writeln('\nComponent locations (ADR-0011):');
  for (final MapEntry(key: component, value: where) in placement.entries) {
    stdout.writeln('    ${component.name.padRight(8)} ${where.name}');
    if (where == Placement.absent) {
      stderr.writeln('VIOLATION  no Dart source found for the ${component.name} component');
      failures++;
    }
  }

  final a = sdkIsolationViolations(graph);
  final b = flutterFreeViolations(graph);
  for (final violation in [...a, ...b]) {
    stderr.writeln('VIOLATION  $violation');
  }
  failures += a.length + b.length;
  // Coverage, so a pass can be told apart from a walk that reached nothing.
  final reached = <String, int>{};
  for (final file in graph.closure([sdkEntry]).files.keys) {
    final name = classify(file)?.name ?? 'other';
    reached[name] = (reached[name] ?? 0) + 1;
  }
  final coverage = reached.entries.map((e) => '${e.key} ${e.value}').join(', ');
  if (a.isEmpty) {
    stdout.writeln('ok  A: $sdkEntry reaches no engine, CLI, Figma or AI code (reaches: $coverage)');
  }
  if (b.isEmpty) {
    final scanned = [
      for (final component in flutterFreeComponents)
        '${component.name} ${componentFiles('.', component).length}',
    ].join(', ');
    stdout.writeln('ok  B: protocol, engine, CLI, Figma and AI code reaches no Flutter (entry files: $scanned)');
  }

  final policy = publishPolicy(
    loadYaml(File('$publishedPackageDir/pubspec.yaml').readAsStringSync()) as YamlMap,
    workspaceMembers: workspaceMemberNames('.', except: 'flutter_testsmith'),
    componentPlacements: placement,
  );
  for (final violation in policy.violations) {
    stderr.writeln('VIOLATION  $violation');
  }
  failures += policy.violations.length;
  if (policy.violations.isEmpty) {
    stdout.writeln('ok  C: flutter_testsmith declares no path, git or non-pub.dev dependency');
  }
  if (policy.pending.isNotEmpty) {
    final label = release ? 'VIOLATION' : 'pending';
    final sink = release ? stderr : stdout;
    sink.writeln(
      '    C: ${policy.pending.length} item(s) before flutter_testsmith is '
      'publishable${release ? '' : ' (expected during the migration; --release fails on them)'}:',
    );
    for (final item in policy.pending) {
      sink.writeln('$label  $item');
    }
    if (release) failures += policy.pending.length;
  } else {
    stdout.writeln('ok  C: nothing pending; flutter_testsmith is publishable as one package');
  }
  return failures;
}

/// Reads the `dependencies:` block only.
///
/// dev_dependencies are excluded deliberately: flutter_testsmith_engine may use
/// flutter_test-free test tooling, and the rule is about what ships.
Set<String> _declaredDependencies(String pubspec) {
  final names = <String>{};
  var inDependencies = false;

  for (final rawLine in pubspec.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    if (line.trimRight() == 'dependencies:') {
      inDependencies = true;
      continue;
    }
    // Any other top-level key ends the block.
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      inDependencies = false;
      continue;
    }
    if (!inDependencies) continue;

    final match = RegExp(r'^  ([a-z_0-9]+):').firstMatch(line);
    if (match != null) names.add(match.group(1)!);
  }

  return names;
}
