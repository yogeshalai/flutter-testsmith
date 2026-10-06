import 'dart:io';

import 'package:flutter_testsmith/figma.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/figma_source_resolver.dart';
import 'package:flutter_testsmith/engine.dart';

class StubHttp implements FigmaHttp {
  StubHttp(this.status, this.body);

  final int status;
  final String body;
  int calls = 0;
  String? sawToken;

  @override
  Future<FigmaHttpResponse> get(
    String url,
    Map<String, String> headers,
  ) async {
    calls++;
    sawToken = headers['X-Figma-Token'];
    return FigmaHttpResponse(status: status, body: body);
  }
}

/// An HTTP layer that fails the way `HttpClient` really fails.
class ThrowingHttp implements FigmaHttp {
  const ThrowingHttp(this.error);

  final Object error;

  @override
  Future<FigmaHttpResponse> get(String url, Map<String, String> headers) async {
    throw error;
  }
}

class FixedResolver implements SecretResolver {
  const FixedResolver(this._values);

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

/// A frame with one 100x40 child, enough to normalise.
const _frame = '''
{"nodes":{"909:1":{"document":{
  "id":"909:1","name":"Login","type":"FRAME",
  "absoluteBoundingBox":{"x":0,"y":0,"width":402,"height":800},
  "children":[{"id":"909:133","name":"Add Button","type":"FRAME",
    "absoluteBoundingBox":{"x":20,"y":100,"width":100,"height":40}}]
}}}}''';

const _declared = '''
screen: /login
figmaSource:
  url: https://figma.com/design/abc/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/login.mapping.yaml
''';

Directory _projectWithMapping(String mappingYaml) {
  final dir = Directory.systemTemp.createTempSync('e06figma');
  Directory('${dir.path}/figma').createSync(recursive: true);
  File('${dir.path}/figma/login.mapping.yaml').writeAsStringSync(mappingYaml);
  return dir;
}

void main() {
  test('a declared figmaSource is fetched and normalised', () async {
    final project = _projectWithMapping(
      'screen: /login\nnodes:\n  "909:133": login.google_button\n',
    );
    addTearDown(() => project.deleteSync(recursive: true));
    final http = StubHttp(200, _frame);

    final (specs, failures) = await resolveFigmaSources(
      project: project,
      mappings: {'/login': MappingsFile.parse(_declared, source: 't')},
      secrets: const FixedResolver({'FIGMA_TOKEN': 'figd_x'}),
      http: http,
    );

    expect(failures, isEmpty);
    expect(specs['/login']!.figmaName, 'Login');
    expect(specs['/login']!.bySemanticId('login.google_button'), isNotNull);
    expect(http.sawToken, 'figd_x');
  });

  group('the resolver returns rather than throws', () {
    // What `run` and `suite run` depend on. Neither guards this call -
    // they read `failures` and turn each entry into an ERROR in the
    // Figma dimension - so anything that escapes here reaches
    // `bin/testsmith.dart`, which catches `UsageException` and nothing
    // else, and ends the process at 255. Measured before this group
    // existed: every failure below escaped, and the run was over.
    for (final failure in <String, Object>{
      'a DNS failure': const SocketException('Failed host lookup'),
      'a refused connection': const SocketException('Connection refused'),
      'a rejected certificate': const HandshakeException('CERT_VERIFY_FAILED'),
      'a TLS error': const TlsException('bad record mac'),
      'a connection closed early': const HttpException('Connection closed'),
      'a body that is not UTF-8': const FormatException('bad byte'),
    }.entries) {
      test('${failure.key} becomes a failure on the screen', () async {
        final project = _projectWithMapping('screen: /login\nnodes: {}\n');
        addTearDown(() => project.deleteSync(recursive: true));

        final (specs, failures) = await resolveFigmaSources(
          project: project,
          mappings: {'/login': MappingsFile.parse(_declared, source: 't')},
          secrets: const FixedResolver({'FIGMA_TOKEN': 'figd_secret_value'}),
          http: ThrowingHttp(failure.value),
        );

        expect(specs, isEmpty);
        expect(failures['/login'], isNotNull, reason: '$failures');
        expect(failures['/login'], isNot(contains('figd_secret_value')));
      });
    }

    test('and so does an answer that is not a design', () async {
      // The cached gateway answer, which needs no network to happen
      // again: it is read straight off disk on every later run.
      final project = _projectWithMapping('screen: /login\nnodes: {}\n');
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: {'/login': MappingsFile.parse(_declared, source: 't')},
        secrets: const FixedResolver({'FIGMA_TOKEN': 'figd_x'}),
        http: StubHttp(200, '{"error":"blocked by policy"}'),
      );

      expect(specs, isEmpty);
      expect(failures['/login'], isNotNull, reason: '$failures');
    });

    test('and so does a frame the response does not contain', () async {
      final project = _projectWithMapping('screen: /login\nnodes: {}\n');
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: {'/login': MappingsFile.parse(_declared, source: 't')},
        secrets: const FixedResolver({'FIGMA_TOKEN': 'figd_x'}),
        http: StubHttp(200, '{"nodes":{}}'),
      );

      expect(specs, isEmpty);
      expect(failures['/login'], contains('909:1'));
    });

    test('and so does a mapping whose "screen" is not a name', () async {
      // The one the guard above did not cover. Every other field in the
      // mapping file raises a `FormatException`, which this call catches
      // into `failures`; `screen` was a cast, so an ordinary slip left
      // the parser as a `_TypeError` - not a `FormatException` and not
      // an `Exception` at all - and escaped the same way the six above
      // used to. No network is reached, so the stub is never asked.
      final project = _projectWithMapping('screen: 123\nnodes: {}\n');
      addTearDown(() => project.deleteSync(recursive: true));
      final http = StubHttp(200, _frame);

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: {'/login': MappingsFile.parse(_declared, source: 't')},
        secrets: const FixedResolver({'FIGMA_TOKEN': 'figd_x'}),
        http: http,
      );

      expect(specs, isEmpty);
      expect(failures['/login'], isNotNull, reason: '$failures');
      // Provenance and the field, so the entry names the file to open.
      expect(failures['/login'], contains('login.mapping.yaml'));
      expect(failures['/login'], contains('screen'));
      expect(http.calls, 0, reason: 'a file that will not parse is not fetched');
    });
  });

  test('a rejected token becomes a failure that never echoes it', () async {
    final project = _projectWithMapping('screen: /login\nnodes: {}\n');
    addTearDown(() => project.deleteSync(recursive: true));

    final (specs, failures) = await resolveFigmaSources(
      project: project,
      mappings: {'/login': MappingsFile.parse(_declared, source: 't')},
      secrets: const FixedResolver({'FIGMA_TOKEN': 'figd_secret_value'}),
      http: StubHttp(403, '{}'),
    );

    expect(specs, isEmpty);
    expect(failures['/login'], contains('403'));
    expect(failures['/login'], isNot(contains('figd_secret_value')));
  });

  test('a missing token is a failure naming only the variable', () async {
    final project = _projectWithMapping('screen: /login\nnodes: {}\n');
    addTearDown(() => project.deleteSync(recursive: true));

    final (_, failures) = await resolveFigmaSources(
      project: project,
      mappings: {'/login': MappingsFile.parse(_declared, source: 't')},
      secrets: const FixedResolver({}),
      http: StubHttp(200, _frame),
    );

    expect(failures['/login'], contains('FIGMA_TOKEN'));
  });

  test('a missing mapping file is a failure, not a silent skip', () async {
    final project = Directory.systemTemp.createTempSync('e06figma');
    addTearDown(() => project.deleteSync(recursive: true));

    final (_, failures) = await resolveFigmaSources(
      project: project,
      mappings: {'/login': MappingsFile.parse(_declared, source: 't')},
      secrets: const FixedResolver({'FIGMA_TOKEN': 'x'}),
      http: StubHttp(200, _frame),
    );

    expect(failures['/login'], contains('login.mapping.yaml'));
  });

  test('a screen with no figmaSource is not touched', () async {
    final project = Directory.systemTemp.createTempSync('e06figma');
    addTearDown(() => project.deleteSync(recursive: true));
    final http = StubHttp(200, _frame);

    final (specs, failures) = await resolveFigmaSources(
      project: project,
      mappings: {'/login': MappingsFile.parse('screen: /login', source: 't')},
      secrets: const FixedResolver({}),
      http: http,
    );

    expect(specs, isEmpty);
    expect(failures, isEmpty);
    expect(http.calls, 0);
  });

  test('a declared source wins over a spec on disk, and says so', () {
    final onDisk = FigmaScreenSpec(
      screen: '/login',
      nodeId: '1:1',
      figmaName: 'Stale',
      width: 402,
      height: 800,
      elements: const [],
    );
    final declared = FigmaScreenSpec(
      screen: '/login',
      nodeId: '909:1',
      figmaName: 'Login',
      width: 402,
      height: 800,
      elements: const [],
    );

    final notes = <String>[];
    final merged = mergeFigmaSpecs(
      fromDisk: {'/login': onDisk},
      fromSource: {'/login': declared},
      onNote: notes.add,
    );

    expect(merged['/login']!.figmaName, 'Login');
    expect(notes.single, contains('declared figmaSource'));
  });
}
