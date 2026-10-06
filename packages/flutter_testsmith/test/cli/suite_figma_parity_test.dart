// A suite did not resolve declared Figma sources. `testsmith run` did.
//
// E-06 §4 states the contract: "**A declared `figmaSource:` wins over an
// on-disk `figma/<screen>.json`** … A stale on-disk spec silently
// shadowing a URL somebody declared is exactly the quiet wrongness this
// platform exists to avoid."
//
// `testsmith run` implemented it - resolve, merge, and carry the failures
// so an unresolvable declaration becomes a Figma-source ERROR. A suite
// passed `loadFigmaSpecs` straight through: no resolution, no merge, no
// failures. So a suite validated a declared screen against whatever was
// on disk, and a broken declaration was silently bypassed - the exact
// case the document says the design prevents.
//
// The fix is wiring, not logic: the suite now calls the same three
// functions in the same order. These tests pin the semantics both
// commands now share, and that the suite actually calls them.
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

  @override
  Future<FigmaHttpResponse> get(String url, Map<String, String> headers) async {
    calls++;
    return FigmaHttpResponse(status: status, body: body);
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

const _frame = '''
{"nodes":{"909:1":{"document":{
  "id":"909:1","name":"LoginFromFigma","type":"FRAME",
  "absoluteBoundingBox":{"x":0,"y":0,"width":402,"height":800},
  "children":[{"id":"909:133","name":"Add Button","type":"FRAME",
    "absoluteBoundingBox":{"x":20,"y":100,"width":100,"height":40}}]
}}}}''';

const _token = FixedResolver({'FIGMA_TOKEN': 'figd_stub_value'});

/// A project whose `/login` screen declares a `figmaSource:`.
Directory _declaringProject({String screen = '/login'}) {
  final dir = Directory.systemTemp.createTempSync('suitefigma');
  Directory('${dir.path}/figma').createSync(recursive: true);
  File('${dir.path}/figma/login.mapping.yaml').writeAsStringSync(
    'screen: $screen\nnodes:\n  "909:133": login.google_button\n',
  );
  return dir;
}

Map<String, MappingsFile> _declaring(String screen) => {
      screen: MappingsFile.parse(
        '''
screen: $screen
figmaSource:
  url: https://figma.com/design/abc/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/login.mapping.yaml
''',
        source: 'm.yaml',
      ),
    };

/// A spec of the shape `figma/<screen>.json` holds on disk.
FigmaScreenSpec _onDisk(String screen) => FigmaScreenSpec.fromJson({
      'screen': screen,
      'nodeId': '111:111',
      'figmaName': 'StaleSpecOnDisk',
      'width': 402.0,
      'height': 800.0,
      'totalNodesWalked': 1,
      'elements': <Object?>[],
    });

String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

void main() {
  group('A: a declared source that resolves is the one used', () {
    test('the spec comes from Figma, not from disk', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: _token,
        http: StubHttp(200, _frame),
      );

      expect(failures, isEmpty);
      expect(specs['/login']!.figmaName, 'LoginFromFigma');
    });
  });

  group('B: a declared source wins over a conflicting on-disk spec', () {
    test('the merged spec is the declared one', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, _) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: _token,
        http: StubHttp(200, _frame),
      );

      final notes = <String>[];
      final merged = mergeFigmaSpecs(
        fromDisk: {'/login': _onDisk('/login')},
        fromSource: specs,
        onNote: notes.add,
      );

      expect(merged['/login']!.figmaName, 'LoginFromFigma');
      expect(merged['/login']!.figmaName, isNot('StaleSpecOnDisk'));
      expect(notes.single, contains('uses the declared figmaSource'));
    });
  });

  group('C: a declaration that cannot resolve becomes a failure', () {
    test('a malformed URL is refused earlier, at mappings parse', () {
      // Not a resolution failure at all: `MappingsFile.parse` validates
      // the URL, so a bad one never reaches the resolver. Both commands
      // load mappings through `loadMappings` and return on
      // `MappingsFormatException`, so this branch is already shared -
      // worth pinning, because it is the one case where "declared source
      // is broken" is handled before Figma is involved.
      expect(
        () => MappingsFile.parse(
          '''
screen: /login
figmaSource:
  url: not-a-figma-url
  token: env:FIGMA_TOKEN
  mapping: figma/login.mapping.yaml
''',
          source: 'm.yaml',
        ),
        throwsA(isA<MappingsFormatException>()),
      );

      for (final command in const [
        'flutter_testsmith/lib/src/cli/commands/suite_command.dart',
        'flutter_testsmith/lib/src/cli/commands/run_command.dart',
      ]) {
        expect(_source(command), contains('MappingsFormatException'),
            reason: command);
      }
    });

    test('a declared mapping file that is missing fails, with no spec',
        () async {
      final project = Directory.systemTemp.createTempSync('suitefigma_nomap');
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: _token,
        http: StubHttp(200, _frame),
      );

      expect(specs, isEmpty);
      expect(failures['/login'], contains('node mapping'));
    });

    test('a missing token fails, and nothing is fetched', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));
      final http = StubHttp(200, _frame);

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: const FixedResolver({}),
        http: http,
      );

      expect(specs, isEmpty);
      expect(failures['/login'], contains('FIGMA_TOKEN'));
      expect(http.calls, 0);
    });

    test('a fetch failure fails rather than producing a spec', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: _token,
        http: StubHttp(403, '{"err":"forbidden"}'),
      );

      expect(specs, isEmpty);
      expect(failures.containsKey('/login'), isTrue);
    });

    test('the failure gates validation, so no on-disk fallback happens',
        () async {
      // The merged map may still hold the on-disk spec - it is what a
      // screen without a declaration would use. What stops it being used
      // is `figmaFailures`, which the executor checks first and turns
      // into a `figma-source` ERROR instead of running the validator.
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: const FixedResolver({}),
        http: StubHttp(200, _frame),
      );

      final merged = mergeFigmaSpecs(
        fromDisk: {'/login': _onDisk('/login')},
        fromSource: specs,
      );

      expect(failures.containsKey('/login'), isTrue);
      expect(merged.containsKey('/login'), isTrue);

      final executor = _source('flutter_testsmith/lib/src/cli/flow_executor.dart');
      expect(executor, contains('figmaFailures.containsKey(screenId)'));
      expect(executor, contains("validatorId: 'figma-source'"));
      expect(executor, contains('ValidationDimension.figma'));
    });
  });

  group('D/E: no declaration leaves the on-disk behaviour alone', () {
    test('a screen with no figmaSource keeps its on-disk spec', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: {
          '/cart': MappingsFile.parse('screen: /cart\n', source: 'm.yaml'),
        },
        secrets: _token,
        http: StubHttp(200, _frame),
      );

      expect(specs, isEmpty);
      expect(failures, isEmpty);

      final merged = mergeFigmaSpecs(
        fromDisk: {'/cart': _onDisk('/cart')},
        fromSource: specs,
      );

      expect(merged['/cart']!.figmaName, 'StaleSpecOnDisk');
    });

    test('no declaration and no spec leaves nothing to validate against', () {
      final merged = mergeFigmaSpecs(fromDisk: const {}, fromSource: const {});

      expect(merged, isEmpty);
      expect(merged['/anything'], isNull);
    });
  });

  group('F: a mixed suite resolves each screen on its own terms', () {
    test('declared, on-disk and absent coexist', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: {
          ..._declaring('/login'),
          '/cart': MappingsFile.parse('screen: /cart\n', source: 'm.yaml'),
        },
        secrets: _token,
        http: StubHttp(200, _frame),
      );

      final merged = mergeFigmaSpecs(
        fromDisk: {'/login': _onDisk('/login'), '/cart': _onDisk('/cart')},
        fromSource: specs,
      );

      expect(failures, isEmpty);
      // Declared wins for the screen that declared one.
      expect(merged['/login']!.figmaName, 'LoginFromFigma');
      // On-disk survives where nothing was declared.
      expect(merged['/cart']!.figmaName, 'StaleSpecOnDisk');
      // And a screen with neither has nothing.
      expect(merged['/checkout'], isNull);
    });

    test('precedence does not depend on map iteration order', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, _) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: _token,
        http: StubHttp(200, _frame),
      );

      // Same inputs, on-disk entries inserted in two different orders.
      final a = mergeFigmaSpecs(
        fromDisk: {'/a': _onDisk('/a'), '/login': _onDisk('/login')},
        fromSource: specs,
      );
      final b = mergeFigmaSpecs(
        fromDisk: {'/login': _onDisk('/login'), '/a': _onDisk('/a')},
        fromSource: specs,
      );

      expect(a['/login']!.figmaName, 'LoginFromFigma');
      expect(b['/login']!.figmaName, 'LoginFromFigma');
      expect(a['/a']!.figmaName, b['/a']!.figmaName);
    });
  });

  group('the suite command now performs the same resolution', () {
    // The defect was wiring, and wiring is what this pins. An end-to-end
    // suite run reaches Figma resolution only after selecting a device
    // and launching an application, so the command itself cannot be
    // exercised here without one; the semantics above are the shared
    // functions it calls.
    final suite = _source('flutter_testsmith/lib/src/cli/commands/suite_command.dart');
    final run = _source('flutter_testsmith/lib/src/cli/commands/run_command.dart');

    test('it resolves declared sources', () {
      expect(suite, contains('resolveFigmaSources('));
    });

    test('it merges them over the on-disk specs', () {
      expect(suite, contains('mergeFigmaSpecs('));
      expect(suite, contains('fromSource: declaredSpecs'));
    });

    test('it carries the failures, so a broken declaration is an error', () {
      expect(suite, contains('figmaFailures: figmaFailures'));
    });

    test('it no longer passes the on-disk specs straight through', () {
      expect(suite, isNot(contains('figmaSpecs: await loadFigmaSpecs(')));
    });

    test('both commands use the one resolver, not two', () {
      for (final source in [suite, run]) {
        expect(source, contains('resolveFigmaSources('));
        expect(source, contains('mergeFigmaSpecs('));
      }
      // No second implementation was written into either command.
      for (final source in [suite, run]) {
        expect(source, isNot(contains('FigmaTarget.parseUrl')));
        expect(source, isNot(contains('FigmaNormaliser')));
      }
    });

    test('testsmith run is unchanged', () {
      expect(run, contains('fromSource: declaredSpecs'));
      expect(run, contains('figmaFailures: figmaFailures'));
    });
  });

  group('nothing secret reaches the resolution output', () {
    test('the token value appears in neither specs nor failures', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (specs, failures) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: _token,
        http: StubHttp(200, _frame),
      );

      final text = '${specs.values.map((s) => s.toJson()).toList()}'
          '${failures.values.toList()}';

      expect(text, isNot(contains('figd_stub_value')));
      expect(text, isNot(contains('X-Figma-Token')));
    });

    test('a failure names the reference, never the value', () async {
      final project = _declaringProject();
      addTearDown(() => project.deleteSync(recursive: true));

      final (_, failures) = await resolveFigmaSources(
        project: project,
        mappings: _declaring('/login'),
        secrets: const FixedResolver({}),
        http: StubHttp(200, _frame),
      );

      expect(failures['/login'], contains('FIGMA_TOKEN'));
      expect(failures['/login'], isNot(contains('figd_')));
    });
  });
}
