// Serves this platform's externally-consumable packages to an application
// outside the monorepo.
//
// Usage:
//   dart run scripts/serve_local_registry.dart [--port 8123]
//   dart run scripts/serve_local_registry.dart --out build/local_registry
//
// The first form runs the repository. Point an application at it for the
// duration of a `pub get`:
//
//   PUB_HOSTED_URL=http://localhost:8123 flutter pub get
//
// The second form writes the archives to disk instead of serving them,
// for inspecting exactly what a consumer would download.
//
// Nothing here publishes anything publicly. Both packages keep
// `publish_to: none`, and this repository is bound to the loopback
// interface only.
import 'dart:convert';
import 'dart:io';

import 'local_registry.dart';
import 'package_boundaries.dart';

const int _defaultPort = 8123;

Future<void> main(List<String> arguments) async {
  final port = _intOption(arguments, '--port') ?? _defaultPort;
  final outputDirectory = _stringOption(arguments, '--out');

  final packages = <PublishedPackage>[];
  for (final name in externallyConsumablePackages) {
    final directory = 'packages/$name';
    if (!Directory(directory).existsSync()) {
      stderr.writeln(
        'Run this from the repository root: $directory does not exist.',
      );
      exit(2);
    }
    final package = PublishedPackage.fromDirectory(
      directory,
      gitTrackedFiles(directory),
    );
    packages.add(package);
    stdout.writeln(
      'packed  ${package.name} ${package.version}  '
      '(${archiveEntryNames(package.archive).length} files, '
      '${package.archive.length} bytes)',
    );
  }

  if (outputDirectory != null) {
    _writeTo(outputDirectory, packages);
    return;
  }

  final registry = LocalRegistry(packages);
  await registry.serve(port: port);

  stdout
    ..writeln('')
    ..writeln('Local package repository on ${registry.baseUrl}')
    ..writeln('Everything it does not publish redirects to '
        '$upstreamRepository, so a consumer still resolves the public '
        'ecosystem.')
    ..writeln('')
    ..writeln('In the consuming application:')
    ..writeln('  PUB_HOSTED_URL=${registry.baseUrl} flutter pub get')
    ..writeln('')
    ..writeln('Ctrl-C to stop.');
}

void _writeTo(String directory, List<PublishedPackage> packages) {
  final target = Directory(directory)..createSync(recursive: true);
  for (final package in packages) {
    final archive = File(
      '${target.path}/${package.name}-${package.version}.tar.gz',
    )..writeAsBytesSync(package.archive);
    File('${target.path}/${package.name}.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(
        packageIndex(
          name: package.name,
          version: package.version,
          pubspec: package.pubspec,
          baseUrl: 'http://localhost:$_defaultPort',
        ),
      ),
    );
    stdout.writeln('wrote   ${archive.path}');
  }
}

String? _stringOption(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index == -1 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}

int? _intOption(List<String> arguments, String name) {
  final value = _stringOption(arguments, name);
  if (value == null) return null;
  final parsed = int.tryParse(value);
  if (parsed == null) {
    stderr.writeln('$name expects a number, got "$value".');
    exit(2);
  }
  return parsed;
}
