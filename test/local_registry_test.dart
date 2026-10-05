// Tests for the local package repository that lets an application outside
// this monorepo consume flutter_testsmith.
//
// The behaviour that matters is not "a file is served". It is that a
// consumer naming only flutter_testsmith also gets flutter_testsmith_protocol, because pub does
// not inherit a parent package's repository for transitive dependencies.
// That is finding E-01, and the end-to-end test below is its regression.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../scripts/local_registry.dart';

void main() {
  group('packageIndex', () {
    test('describes a version pub can fetch', () {
      final index = packageIndex(
        name: 'flutter_testsmith_protocol',
        version: '0.1.0',
        pubspec: {'name': 'flutter_testsmith_protocol', 'version': '0.1.0'},
        baseUrl: 'http://localhost:8123',
      );

      final latest = index['latest']! as Map<String, dynamic>;
      final pubspec = latest['pubspec']! as Map<String, dynamic>;

      expect(index['name'], 'flutter_testsmith_protocol');
      expect(latest['version'], '0.1.0');
      expect(
        latest['archive_url'],
        'http://localhost:8123/archives/flutter_testsmith_protocol-0.1.0.tar.gz',
      );
      expect(index['versions'], hasLength(1));
      expect(pubspec['name'], 'flutter_testsmith_protocol');
    });
  });

  group('resolveRequest', () {
    const hosted = {'flutter_testsmith': '0.1.0', 'flutter_testsmith_protocol': '0.1.0'};

    test('serves a package this registry publishes', () {
      final route = resolveRequest('/api/packages/flutter_testsmith', hosted);
      expect(route.kind, RouteKind.listing);
      expect(route.packageName, 'flutter_testsmith');
    });

    test('redirects a public package to pub.dev', () {
      final route = resolveRequest('/api/packages/dio', hosted);
      expect(route.kind, RouteKind.proxy);
      expect(route.location, 'https://pub.dev/api/packages/dio');
    });

    test('serves an archive this registry publishes', () {
      final route =
          resolveRequest('/archives/flutter_testsmith-0.1.0.tar.gz', hosted);
      expect(route.kind, RouteKind.archive);
      expect(route.packageName, 'flutter_testsmith');
      expect(route.version, '0.1.0');
    });

    test('reports a missing version of a known package as not found', () {
      // Not a proxy: redirecting to pub.dev would report a version
      // mismatch as "could not find package", which is the single most
      // confusing failure in this whole area.
      final route =
          resolveRequest('/archives/flutter_testsmith-9.9.9.tar.gz', hosted);
      expect(route.kind, RouteKind.notFound);
    });
  });

  _e2e();

  group('buildArchive', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('registry_test'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('packs the listed files at the archive root', () {
      File('${temp.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
      Directory('${temp.path}/lib').createSync();
      File('${temp.path}/lib/demo.dart').writeAsStringSync('// demo\n');

      final bytes = buildArchive(temp.path, const [
        'pubspec.yaml',
        'lib/demo.dart',
      ]);

      expect(archiveEntryNames(bytes), containsAll(<String>[
        'pubspec.yaml',
        'lib/demo.dart',
      ]));
    });

    test('refuses a package whose file list has no pubspec', () {
      File('${temp.path}/lib.dart').writeAsStringSync('// x\n');

      expect(
        () => buildArchive(temp.path, const ['lib.dart']),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('pubspec.yaml'),
        )),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// The E-01 regression.
//
// Before this registry existed, an application that named only `flutter_testsmith`
// failed version solving because pub looked for `flutter_testsmith_protocol` on pub.dev.
// The fix is not a flag on the consumer: it is that the registry answering
// the consumer is also the registry the transitive dependency is resolved
// from. This test asserts exactly that, end to end, through a real
// `pub get` against a real socket.
// ---------------------------------------------------------------------------

void _e2e() {
  group('transitive resolution (E-01)', () {
    late Directory temp;
    late LocalRegistry registry;
    late HttpServer server;

    PublishedPackage pkg(String name, Map<String, dynamic> pubspec) {
      final dir = Directory('${temp.path}/src/$name')
        ..createSync(recursive: true);
      File('${dir.path}/pubspec.yaml')
          .writeAsStringSync(jsonEncode(pubspec));
      Directory('${dir.path}/lib').createSync();
      File('${dir.path}/lib/$name.dart').writeAsStringSync('// $name\n');
      return PublishedPackage.fromDirectory(
        dir.path,
        const ['pubspec.yaml'],
        extraFiles: ['lib/$name.dart'],
      );
    }

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('registry_e2e');
      registry = LocalRegistry([
        pkg('probe_leaf', {
          'name': 'probe_leaf',
          'version': '0.1.0',
          'environment': {'sdk': '^3.12.0'},
        }),
        pkg('probe_facade', {
          'name': 'probe_facade',
          'version': '0.1.0',
          'environment': {'sdk': '^3.12.0'},
          // The clean constraint a published package carries. No repository
          // URL, no path: exactly what flutter_testsmith says about flutter_testsmith_protocol.
          'dependencies': {'probe_leaf': '^0.1.0'},
        }),
      ]);
      server = await registry.serve();
    });

    tearDown(() async {
      await server.close(force: true);
      temp.deleteSync(recursive: true);
    });

    test('a consumer naming only the facade also gets the leaf', () async {
      final app = Directory('${temp.path}/app')..createSync();
      File('${app.path}/pubspec.yaml').writeAsStringSync(jsonEncode({
        'name': 'probe_app',
        'publish_to': 'none',
        'environment': {'sdk': '^3.12.0'},
        // The consumer names the facade and nothing else. Naming the leaf
        // here is precisely the workaround E-01 forced on an external
        // application.
        'dependencies': {'probe_facade': '^0.1.0'},
      }));

      final result = await Process.run(
        'dart',
        ['pub', 'get'],
        workingDirectory: app.path,
        environment: {'PUB_HOSTED_URL': registry.baseUrl},
        runInShell: true,
      );

      expect(
        result.exitCode,
        0,
        reason: 'pub get failed:\n${result.stdout}\n${result.stderr}',
      );
      final lock = File('${app.path}/pubspec.lock').readAsStringSync();
      expect(lock, contains('probe_leaf'),
          reason: 'the transitive dependency was never resolved');
    });
  });
}
