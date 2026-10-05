// A pub package repository, small enough to read, that serves this
// platform's two externally-consumable packages to an application outside
// the monorepo.
//
// It exists because of one fact about pub, measured rather than assumed:
// **a package fetched from repository X has its own dependencies resolved
// from the default repository, not from X.** So an application that names
// only `flutter_testsmith` still looks for `flutter_testsmith_protocol` on pub.dev, finds
// nothing, and fails version solving outright. That is finding E-01.
//
// The way out is to be the default repository for the duration of a
// `pub get`: serve the two packages that are not public, and redirect
// every other request to pub.dev so the application still gets the ~40
// public packages it depends on. A consumer then writes the same
// `flutter_testsmith: ^0.1.0` it would write against pub.dev, and names nothing
// internal.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:yaml/yaml.dart';

/// Where a request should be answered from.
enum RouteKind {
  /// This registry publishes the package; serve its version listing.
  listing,

  /// This registry publishes the package; serve the archive bytes.
  archive,

  /// A public package. Redirect, so the consumer keeps the real ecosystem.
  proxy,

  /// A known package at a version this registry does not have.
  notFound,
}

/// The decision for one request, with everything the server needs to act.
class Route {
  const Route._(this.kind, {this.packageName, this.version, this.location});

  const Route.listing(String name)
      : this._(RouteKind.listing, packageName: name);

  const Route.archive(String name, String version)
      : this._(RouteKind.archive, packageName: name, version: version);

  const Route.proxy(String location)
      : this._(RouteKind.proxy, location: location);

  const Route.notFound() : this._(RouteKind.notFound);

  final RouteKind kind;
  final String? packageName;
  final String? version;

  /// Absolute URL to redirect to, for [RouteKind.proxy].
  final String? location;
}

/// The upstream every non-local package is redirected to.
const String upstreamRepository = 'https://pub.dev';

final RegExp _indexPath = RegExp(r'^/api/packages/([a-z0-9_]+)$');
final RegExp _archivePath =
    RegExp(r'^/archives/([a-z0-9_]+)-([0-9][0-9a-zA-Z.\-+]*)\.tar\.gz$');

/// Decides how to answer [path], given the packages this registry publishes
/// as a map of name to the single version it holds.
Route resolveRequest(String path, Map<String, String> hosted) {
  final listing = _indexPath.firstMatch(path);
  if (listing != null) {
    final name = listing.group(1)!;
    return hosted.containsKey(name)
        ? Route.listing(name)
        : Route.proxy('$upstreamRepository$path');
  }

  final archive = _archivePath.firstMatch(path);
  if (archive != null) {
    final name = archive.group(1)!;
    final version = archive.group(2)!;
    if (!hosted.containsKey(name)) {
      return Route.proxy('$upstreamRepository$path');
    }
    // A version this registry does not hold is *not* proxied. Redirecting
    // would report a version mismatch as "could not find package
    // flutter_testsmith", which is the most confusing failure in this whole area
    // and the one E-01 was originally mistaken for.
    return hosted[name] == version
        ? Route.archive(name, version)
        : const Route.notFound();
  }

  return Route.proxy('$upstreamRepository$path');
}

/// The version listing for [name], in the shape `pub` expects from a
/// package repository (the `application/vnd.pub.v2+json` body).
Map<String, dynamic> packageIndex({
  required String name,
  required String version,
  required Map<String, dynamic> pubspec,
  required String baseUrl,
}) {
  final entry = <String, dynamic>{
    'version': version,
    'archive_url': '$baseUrl/archives/$name-$version.tar.gz',
    'pubspec': pubspec,
  };
  return <String, dynamic>{
    'name': name,
    'latest': entry,
    'versions': <dynamic>[entry],
  };
}

/// Packs [files] — paths relative to [packageDirectory] — into the
/// `.tar.gz` a pub repository serves.
///
/// The caller supplies the file list rather than a directory walk, because
/// what belongs in a package is decided by version control, not by what
/// happens to be on disk: build output, `.dart_tool` and local scratch
/// files are all sitting next to the sources.
Uint8List buildArchive(String packageDirectory, List<String> files) {
  if (!files.contains('pubspec.yaml')) {
    throw StateError(
      'Refusing to build an archive for $packageDirectory: the file list '
      'has no pubspec.yaml. A package without one is not a package, and '
      'the usual cause is a .gitignore that swallowed it.',
    );
  }

  final archive = Archive();
  for (final relative in files) {
    final file = File('$packageDirectory/$relative');
    archive.add(ArchiveFile.bytes(relative, file.readAsBytesSync()));
  }

  return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

/// The paths inside a `.tar.gz` built by [buildArchive].
///
/// Used by the packaging tests to assert what a consumer actually
/// receives, rather than what the source tree happens to contain.
List<String> archiveEntryNames(List<int> archiveBytes) =>
    TarDecoder()
        .decodeBytes(GZipDecoder().decodeBytes(archiveBytes))
        .files
        .map((f) => f.name)
        .toList();

/// Convenience for servers and tests that want the listing as bytes.
List<int> encodeIndex(Map<String, dynamic> index) =>
    utf8.encode(jsonEncode(index));

/// One package this registry publishes: its metadata and the exact bytes a
/// consumer will receive.
class PublishedPackage {
  PublishedPackage({
    required this.name,
    required this.version,
    required this.pubspec,
    required this.archive,
  });

  /// Reads a package from disk. [files] are paths relative to [directory],
  /// normally the version-controlled file list.
  factory PublishedPackage.fromDirectory(
    String directory,
    List<String> files, {
    List<String> extraFiles = const [],
  }) {
    final all = <String>[...files, ...extraFiles];
    final pubspec = _parsePubspec(
      File('$directory/pubspec.yaml').readAsStringSync(),
    );
    return PublishedPackage(
      name: pubspec['name'] as String,
      version: pubspec['version'] as String,
      pubspec: pubspec,
      archive: buildArchive(directory, all),
    );
  }

  final String name;
  final String version;
  final Map<String, dynamic> pubspec;
  final Uint8List archive;
}

/// A pub package repository over the loopback interface.
///
/// Anything it does not publish is redirected to [upstreamRepository], so a
/// consumer can make this its default repository for one `pub get` and
/// still resolve the public packages it depends on.
class LocalRegistry {
  LocalRegistry(List<PublishedPackage> packages)
      : _packages = {for (final p in packages) p.name: p};

  final Map<String, PublishedPackage> _packages;
  HttpServer? _server;

  /// The URL to hand pub as `PUB_HOSTED_URL`. Valid once [serve] completes.
  String get baseUrl {
    final server = _server;
    if (server == null) {
      throw StateError('The registry is not serving yet; call serve() first.');
    }
    return 'http://localhost:${server.port}';
  }

  Map<String, String> get _hostedVersions =>
      {for (final e in _packages.entries) e.key: e.value.version};

  /// Binds to [port] — 0 picks a free one — and starts answering requests.
  Future<HttpServer> serve({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(_handle);
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    final route = resolveRequest(request.uri.path, _hostedVersions);
    final response = request.response;

    switch (route.kind) {
      case RouteKind.listing:
        final package = _packages[route.packageName]!;
        final body = encodeIndex(packageIndex(
          name: package.name,
          version: package.version,
          pubspec: package.pubspec,
          baseUrl: baseUrl,
        ));
        response.headers
            .set('content-type', 'application/vnd.pub.v2+json');
        response.add(body);

      case RouteKind.archive:
        response.headers.set('content-type', 'application/octet-stream');
        response.add(_packages[route.packageName]!.archive);

      case RouteKind.proxy:
        response.statusCode = HttpStatus.found;
        response.headers.set('location', route.location!);

      case RouteKind.notFound:
        response.statusCode = HttpStatus.notFound;
    }

    await response.close();
  }
}

/// Parses a pubspec into plain JSON-encodable maps.
///
/// The YAML types are deliberately not kept: this map is serialised into
/// the repository listing, and `YamlMap` does not survive `jsonEncode`.
Map<String, dynamic> _parsePubspec(String source) =>
    _plain(loadYaml(source)) as Map<String, dynamic>;

Object? _plain(Object? node) => switch (node) {
      final YamlMap map => <String, dynamic>{
          for (final e in map.entries) e.key.toString(): _plain(e.value),
        },
      final YamlList list => list.map(_plain).toList(),
      final Map<dynamic, dynamic> map => <String, dynamic>{
          for (final e in map.entries) e.key.toString(): _plain(e.value),
        },
      final List<dynamic> list => list.map(_plain).toList(),
      _ => node,
    };

/// The version-controlled files of the package at [directory], relative to
/// it.
///
/// Version control decides what is in a package, not a directory walk:
/// `build/`, `.dart_tool/` and local scratch files all sit next to the
/// sources, and none of them belong in an archive a consumer downloads.
/// This is the same rule `dart pub publish` applies to a git checkout.
List<String> gitTrackedFiles(String directory) {
  final result = Process.runSync(
    'git',
    const ['ls-files', '--cached', '--exclude-standard'],
    workingDirectory: directory,
    runInShell: true,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Could not list the tracked files of $directory: ${result.stderr}',
    );
  }
  return (result.stdout as String)
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}
