// What a package promises to an application outside this monorepo.
//
// The rules here are the mechanical form of finding E-01: a package that
// an external application depends on may not reach back into the
// repository it was built from. A `path:` or `git:` dependency does
// exactly that, and pub will not resolve it for a consumer that fetched
// the package from a repository.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../scripts/local_registry.dart';
import '../scripts/package_boundaries.dart';

void main() {
  group('externallyConsumableViolations', () {
    test('accepts a plain version constraint', () {
      final violations = externallyConsumableViolations(
        'flutter_testsmith',
        loadYaml('''
name: flutter_testsmith
dependencies:
  flutter_testsmith_protocol: ^0.1.0
''') as YamlMap,
      );
      expect(violations, isEmpty);
    });

    test('rejects a path dependency', () {
      final violations = externallyConsumableViolations(
        'flutter_testsmith',
        loadYaml('''
name: flutter_testsmith
dependencies:
  flutter_testsmith_protocol:
    path: ../flutter_testsmith_protocol
''') as YamlMap,
      );
      expect(violations, hasLength(1));
      expect(violations.single, contains('flutter_testsmith_protocol'));
      expect(violations.single, contains('path'));
    });

    test('rejects a git dependency', () {
      final violations = externallyConsumableViolations(
        'flutter_testsmith',
        loadYaml('''
name: flutter_testsmith
dependencies:
  flutter_testsmith_protocol:
    git:
      url: https://example.com/platform.git
''') as YamlMap,
      );
      expect(violations, hasLength(1));
      expect(violations.single, contains('git'));
    });

    test('allows the flutter SDK dependency', () {
      // `sdk: flutter` resolves from the consumer's own Flutter
      // installation, not from this repository, so it is not a reach-back.
      final violations = externallyConsumableViolations(
        'flutter_testsmith',
        loadYaml('''
name: flutter_testsmith
dependencies:
  flutter:
    sdk: flutter
''') as YamlMap,
      );
      expect(violations, isEmpty);
    });

    test('ignores dev_dependencies', () {
      // dev_dependencies are not resolved for a consumer at all.
      final violations = externallyConsumableViolations(
        'flutter_testsmith',
        loadYaml('''
name: flutter_testsmith
dev_dependencies:
  flutter_testsmith_engine:
    path: ../flutter_testsmith_engine
''') as YamlMap,
      );
      expect(violations, isEmpty);
    });
  });

  group('the packages an external application consumes', () {
    for (final package in externallyConsumablePackages) {
      test('$package reaches back into no repository', () {
        final pubspec = loadYaml(
          File('${packageDirectory(package)}/pubspec.yaml').readAsStringSync(),
        ) as YamlMap;
        expect(externallyConsumableViolations(package, pubspec), isEmpty);
      });
    }

    test('flutter_testsmith_protocol stays free of Flutter', () {
      // It is linked into production applications through flutter_testsmith, and it
      // is also linked into the Flutter-free engine. Both depend on this.
      final pubspec = loadYaml(
        File('packages/flutter_testsmith_protocol/pubspec.yaml').readAsStringSync(),
      ) as YamlMap;
      expect((pubspec['dependencies'] as YamlMap).keys, isNot(contains('flutter')));
    });
  });

  group('the archive a consumer actually receives', () {
    for (final package in externallyConsumablePackages) {
      test('$package ships its pubspec and its library', () {
        final published = PublishedPackage.fromDirectory(
          packageDirectory(package),
          gitTrackedFiles(packageDirectory(package)),
        );
        final entries = archiveEntryNames(published.archive);

        expect(entries, contains('pubspec.yaml'));
        expect(entries, contains('lib/$package.dart'));
        expect(published.name, package);
      });
    }

    test('flutter_testsmith ships the sources its public exports name', () {
      final published = PublishedPackage.fromDirectory(
        'packages/flutter_testsmith',
        gitTrackedFiles('packages/flutter_testsmith'),
      );
      final entries = archiveEntryNames(published.archive).toSet();

      // Only the package's own sources. `export 'package:...'` names
      // another package, which arrives as a dependency rather than a file.
      final exported = RegExp(r"export '(?!package:)([^']+)'")
          .allMatches(
              File('packages/flutter_testsmith/lib/flutter_testsmith.dart').readAsStringSync())
          .map((m) => 'lib/${m.group(1)}');

      expect(exported, isNotEmpty);
      for (final source in exported) {
        expect(entries, contains(source),
            reason: 'flutter_testsmith.dart exports $source, which the archive omits');
      }
    });

    // The same promise for every other public library of the package - the
    // component barrels ADR-0011 adds (engine.dart, figma.dart, ai.dart).
    // Found by listing lib/, so a barrel added later is covered without
    // anyone remembering to add it here.
    final componentBarrels = Directory('packages/flutter_testsmith/lib')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.dart') && name != 'flutter_testsmith.dart')
        .toList()
      ..sort();

    test('flutter_testsmith has component barrels to check', () {
      expect(componentBarrels, isNotEmpty);
    });

    for (final barrel in componentBarrels) {
      test('flutter_testsmith ships lib/$barrel and the sources it exports', () {
        final published = PublishedPackage.fromDirectory(
          'packages/flutter_testsmith',
          gitTrackedFiles('packages/flutter_testsmith'),
        );
        final entries = archiveEntryNames(published.archive).toSet();
        expect(entries, contains('lib/$barrel'));

        final exported = RegExp(r"export '(?!package:)([^']+)'")
            .allMatches(File('packages/flutter_testsmith/lib/$barrel').readAsStringSync())
            .map((m) => 'lib/${m.group(1)}')
            .toList();
        expect(exported, isNotEmpty, reason: '$barrel exports nothing');
        for (final source in exported) {
          expect(entries, contains(source),
              reason: '$barrel exports $source, which the archive omits');
        }
      });
    }
  });
}
