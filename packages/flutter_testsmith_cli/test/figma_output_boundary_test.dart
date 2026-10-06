// Where a pulled Figma spec lands, and where its response cache lives.
//
// Two different questions that had become one. `figma pull --out` chose
// both: the spec *and* the cache followed it. But a run does not take an
// `--out` - `loadFigmaSpecs` reads `<app>/figma` and nothing else - so a
// non-default `--out` wrote a perfectly good spec into a directory
// nothing would ever look in, and put the response cache somewhere
// `.gitignore`'s `**/figma/.cache/` does not cover.
//
// Reproduced before this file existed:
//
//   testsmith figma pull --app <app> --out specs --screen /login …
//     wrote <app>/specs/login.json
//   loadFigmaSpecs(<app>) sees screens: []
//
// So: the cache is project-owned and always `<app>/figma/.cache`; the
// spec destination stays the caller's to choose, and choosing a
// non-canonical one now says out loud that a run will not find it.
//
// Entirely offline. `FigmaClient` reads its cache before it reaches the
// network, so seeding the cache is what lets the real command run with
// no token of any consequence and no request. The two caches are seeded
// with *different* frame names, which is how a test can tell which one
// the command actually read.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/figma_source_resolver.dart';
import 'package:flutter_testsmith_cli/src/project_config.dart';
import 'package:flutter_testsmith/engine.dart';

late Directory _root;
late Directory _app;

const String _fileKey = 'abc';
const String _url = 'https://figma.com/design/abc/File?node-id=909-1';

/// A frame the normaliser accepts, named so a test can tell two apart.
String _frame(String name) => jsonEncode({
      'nodes': {
        '909:1': {
          'document': {
            'id': '909:1',
            'name': name,
            'type': 'FRAME',
            'absoluteBoundingBox': {
              'x': 0,
              'y': 0,
              'width': 402,
              'height': 800,
            },
            'children': [
              {
                'id': '909:133',
                'name': 'Add Button',
                'type': 'FRAME',
                'absoluteBoundingBox': {
                  'x': 20,
                  'y': 100,
                  'width': 100,
                  'height': 40,
                },
              },
            ],
          },
        },
      },
    });

/// Puts a response where `FigmaClient` will find it instead of the network.
void _seedCache(String directory, String frameName) {
  Directory(directory).createSync(recursive: true);
  File('$directory/$_fileKey.909-1.json').writeAsStringSync(
    _frame(frameName),
  );
}

typedef Run = ({String output, int code});

Future<Run> _pull(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'figma',
      'pull',
      '--app',
      _app.path,
      '--screen',
      '/login',
      '--url',
      _url,
      ...arguments,
    ],
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

/// A transport that fails the test if anything reaches it.
class _NoHttp implements FigmaHttp {
  int calls = 0;

  @override
  Future<FigmaHttpResponse> get(String url, Map<String, String> headers) async {
    calls++;
    return const FigmaHttpResponse(status: 500, body: '{}');
  }
}

class _FixedSecrets implements SecretResolver {
  const _FixedSecrets(this._values);

  final Map<String, String> _values;

  @override
  bool isPresent(SecretRef ref) => _values.containsKey(ref.name);

  @override
  Secret resolve(SecretRef ref) {
    final value = _values[ref.name];
    if (value == null) throw MissingSecretException(ref);
    return Secret(value);
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('figma_boundary');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    File('${_app.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    // The token travels the same path every other credential does.
    File('${_app.path}/.env').writeAsStringSync('FIGMA_TOKEN=figd_offline\n');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('a run finds the specs in the canonical directory', () {
    test('loadFigmaSpecs reads <app>/figma, keyed by the screen', () async {
      // The consumer had no test of its own, which is half of why the
      // producer was free to drift away from it.
      Directory('${_app.path}/figma').createSync();
      File('${_app.path}/figma/login.json').writeAsStringSync(
        jsonEncode({
          'screen': '/login',
          'nodeId': '909:1',
          'figmaName': 'Login',
          'width': 402.0,
          'height': 800.0,
          'elements': const <Object>[],
          'totalNodesWalked': 1,
        }),
      );

      final specs = await loadFigmaSpecs(_app);

      expect(specs.keys, ['/login']);
      expect(specs['/login']!.figmaName, 'Login');
    });

    test('and ignores a spec sitting anywhere else', () async {
      Directory('${_app.path}/specs').createSync();
      File('${_app.path}/specs/login.json').writeAsStringSync(
        jsonEncode({
          'screen': '/login',
          'nodeId': '909:1',
          'figmaName': 'Login',
          'width': 402.0,
          'height': 800.0,
          'elements': const <Object>[],
          'totalNodesWalked': 1,
        }),
      );

      expect(await loadFigmaSpecs(_app), isEmpty);
    });
  });

  group('the default pull round-trips', () {
    test('the spec it writes is the spec a run reads, with no warning',
        () async {
      _seedCache('${_app.path}/figma/.cache', 'Login');

      final run = await _pull(const []);

      expect(run.code, 0, reason: run.output);
      expect(File('${_app.path}/figma/login.json').existsSync(), isTrue);

      final specs = await loadFigmaSpecs(_app);
      expect(specs.keys, ['/login'], reason: run.output);

      expect(run.output.toLowerCase(), isNot(contains('warning')),
          reason: run.output);
    });

    test('and spelling the default differently is still the default',
        () async {
      // `./figma`, a trailing separator, and the absolute form all name
      // the same directory. A prefix comparison would warn about two of
      // them.
      for (final spelling in [
        './figma',
        'figma/',
        'figma/.',
      ]) {
        _seedCache('${_app.path}/figma/.cache', 'Login');

        final run = await _pull(['--out', spelling]);

        expect(run.code, 0, reason: '$spelling: ${run.output}');
        expect(run.output.toLowerCase(), isNot(contains('warning')),
            reason: '$spelling produced a warning: ${run.output}');
      }
    });

    test('including the absolute spelling of the same directory', () async {
      _seedCache('${_app.path}/figma/.cache', 'Login');

      final run = await _pull(['--out', '${_app.path}/figma']);

      expect(run.code, 0, reason: run.output);
      expect(run.output.toLowerCase(), isNot(contains('warning')),
          reason: run.output);
    });
  });

  group('a non-canonical --out is written, and said out loud', () {
    test('the spec is written where it was asked for', () async {
      _seedCache('${_app.path}/figma/.cache', 'Login');

      final run = await _pull(['--out', 'specs']);

      expect(run.code, 0, reason: run.output);
      expect(File('${_app.path}/specs/login.json').existsSync(), isTrue,
          reason: run.output);
    });

    test('a warning says a run will not find it, and names where runs look',
        () async {
      _seedCache('${_app.path}/figma/.cache', 'Login');

      final run = await _pull(['--out', 'specs']);

      final lower = run.output.toLowerCase();
      expect(lower, contains('warning'), reason: run.output);
      expect(lower, contains('figma'), reason: run.output);
      expect(run.output, contains('specs'), reason: run.output);
      expect(lower, anyOf(contains('will not'), contains('not be')),
          reason: run.output);
    });

    test('and the spec is genuinely not discoverable, not merely warned about',
        () async {
      // The warning must describe reality rather than substitute for it:
      // nothing copies the spec into the canonical directory behind the
      // caller's back.
      _seedCache('${_app.path}/figma/.cache', 'Login');

      await _pull(['--out', 'specs']);

      expect(await loadFigmaSpecs(_app), isEmpty);
      expect(File('${_app.path}/figma/login.json').existsSync(), isFalse);
    });
  });

  group('the response cache belongs to the project', () {
    test('the default pull caches under <app>/figma/.cache', () async {
      _seedCache('${_app.path}/figma/.cache', 'Login');

      final run = await _pull(const []);

      expect(run.code, 0, reason: run.output);
      // Read from the seeded cache, so the frame name proves which file
      // answered - no request was made, and none could have been.
      expect(run.output, contains('Login'), reason: run.output);
    });

    test('and so does a pull with a non-canonical --out', () async {
      // Both caches exist and hold different frames. Whichever one the
      // command read is named in its own report.
      _seedCache('${_app.path}/figma/.cache', 'Canonical');
      _seedCache('${_app.path}/specs/.cache', 'FollowedTheOutFlag');

      final run = await _pull(['--out', 'specs']);

      expect(run.code, 0, reason: run.output);
      expect(run.output, contains('Canonical'), reason: run.output);
      expect(run.output, isNot(contains('FollowedTheOutFlag')),
          reason: run.output);
    });

    test('nothing is written into the requested output cache', () async {
      _seedCache('${_app.path}/figma/.cache', 'Login');

      await _pull(['--out', 'specs']);

      expect(Directory('${_app.path}/specs/.cache').existsSync(), isFalse);
    });
  });

  test('a declared figmaSource reads the cache the pull leaves behind',
      () async {
    // The invariant that makes the cache worth pinning: one location,
    // shared by the command that fills it and the resolver that reads
    // it. The transport counts its calls, so a cache miss is visible.
    _seedCache('${_app.path}/figma/.cache', 'Login');

    final pull = await _pull(['--out', 'specs']);
    expect(pull.code, 0, reason: pull.output);

    File('${_app.path}/figma/login.mapping.yaml').writeAsStringSync(
      'screen: /login\nnodes:\n  "909:133": login.button\n',
    );
    final http = _NoHttp();

    final (specs, failures) = await resolveFigmaSources(
      project: _app,
      mappings: {
        '/login': MappingsFile.parse(
          'screen: /login\n'
          'figmaSource:\n'
          '  url: $_url\n'
          '  token: env:FIGMA_TOKEN\n'
          '  mapping: figma/login.mapping.yaml\n',
          source: 'test',
        ),
      },
      secrets: const _FixedSecrets({'FIGMA_TOKEN': 'figd_offline'}),
      http: http,
    );

    expect(failures, isEmpty, reason: '$failures');
    expect(specs['/login']!.figmaName, 'Login');
    expect(http.calls, 0,
        reason: 'the resolver went to the network, so it was not reading '
            'the same cache the pull uses');
  });
}
