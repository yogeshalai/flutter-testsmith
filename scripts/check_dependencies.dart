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
// Run: dart run scripts/check_dependencies.dart
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'package_boundaries.dart';

/// package -> dependencies it must not have (directly or transitively via
/// its own pubspec).
const Map<String, List<String>> forbidden = {
  'flutter_testsmith_protocol': ['flutter', 'flutter_testsmith', 'flutter_testsmith_engine', 'flutter_testsmith_cli'],
  'flutter_testsmith': ['flutter_testsmith_engine', 'flutter_testsmith_cli'],
  'flutter_testsmith_engine': ['flutter', 'flutter_testsmith'],
};

void main() {
  var failures = 0;

  for (final entry in forbidden.entries) {
    final package = entry.key;
    final pubspec = File('packages/$package/pubspec.yaml');
    if (!pubspec.existsSync()) {
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

  if (failures > 0) {
    stderr.writeln('\n$failures dependency violation(s).');
    exit(1);
  }
  stdout.writeln('\nAll dependency rules hold.');
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
