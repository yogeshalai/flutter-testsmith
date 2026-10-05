// A design that cannot be fetched, through the commands.
//
// Everything between deciding to ask Figma and holding a specification
// belongs to `flutter_testsmith_figma`, and everything that goes wrong in
// there is a `FigmaException` - which `resolveFigmaSources` turns into a
// failure on the screen that declared the design, and which `figma pull`
// reports and exits 1 for.
//
// Two ways past that were open. A transport failure - a DNS failure, a
// refused connection, a rejected certificate - left the client as
// itself. And a response that was valid JSON but not a design reached
// the normaliser, which raised a `FormatException`. Both walked past
// `on FigmaException`, past `bin/testsmith.dart`, and ended the process
// at 255.
//
// The second needs no network to reproduce, which is what this file
// uses: a response with no design in it is served from
// `<app>/figma/.cache` on every later run. Measured before this file
// existed, with `{"a": 1}` cached:
//
//   testsmith run        Unhandled exception: FormatException ...      255
//   testsmith suite run  "nothing blocking", then the same            255
//   testsmith figma pull › fetching ABC123#913:1, then the same   255
//
// Only `figma pull` can be driven the whole way offline - `run` and
// `suite run` reach the design after the device and go on to launch the
// application - so the other two are held by `figma_source_resolver_test`,
// which proves the function they both depend on returns rather than
// throws, and by the parity check at the end of this file.
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

/// A frame URL as Figma hands it out, and the cache entry it maps to.
const String _url =
    'https://www.figma.com/design/ABC123/App?node-id=913-1';
const String _cacheEntry = 'ABC123.913-1.json';

/// HTTP 200, valid JSON, no design in it.
///
/// What a captive portal, a corporate proxy or an API gateway answers.
const String _gatewayAnswer = '{"error":"blocked by policy"}';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// The CLI source, for the assertion that can only be made there.
String _source(String relative) {
  for (final candidate in ['packages/$relative', '../$relative']) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $relative');
}

typedef Run = ({String output, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    // Present, so the command gets past the credential check and reaches
    // the cache. It is never sent anywhere: nothing here touches a
    // network.
    environment: {'FIGMA_TOKEN': 'figd_TOPSECRET'},
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('figma_transport');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('figma/.cache/$_cacheEntry', _gatewayAnswer);
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  test('testsmith figma pull reports it rather than crashing', () async {
    final run = await _testsmith(
      ['figma', 'pull', '--app', _app.path, '--screen', '/home', '--url', _url],
    );

    expect(run.output, isNot(contains('Unhandled exception')),
        reason: run.output);
    expect(run.code, isNot(255), reason: run.output);
    expect(run.code, 1, reason: run.output);
  });

  test('and the message never repeats the token back', () async {
    final run = await _testsmith(
      ['figma', 'pull', '--app', _app.path, '--screen', '/home', '--url', _url],
    );

    expect(run.output, isNot(contains('figd_TOPSECRET')), reason: run.output);
  });

  test('and writes no spec for a design it never read', () async {
    await _testsmith(
      ['figma', 'pull', '--app', _app.path, '--screen', '/home', '--url', _url],
    );

    final written = Directory('${_app.path}/figma')
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last);

    expect(written, isEmpty, reason: 'wrote $written');
  });

  test('and says how to get out of it', () async {
    // The caches this inherits were written by a version that only asked
    // whether the body was JSON, and nothing clears them: the file
    // answers every later run, offline, and `figma/.cache` is gitignored
    // where nobody would look for it. Refusing it is only half an
    // answer; the other half is the sentence that gets somebody out.
    final run = await _testsmith(
      ['figma', 'pull', '--app', _app.path, '--screen', '/home', '--url', _url],
    );

    expect(run.output, contains('--refresh'), reason: run.output);
  });

  test('run and suite run reach Figma only through the shared resolver', () {
    // Only assertable in the source. Both commands resolve declared
    // designs after the device is chosen and then go on to launch the
    // application, so neither can be driven this far offline. What keeps
    // them safe is that `resolveFigmaSources` returns its failures
    // instead of throwing them, which `figma_source_resolver_test`
    // proves directly. This is the same instrument
    // `duplicate_screen_config_test` uses, for the same reason.
    for (final file in [
      'flutter_testsmith_cli/lib/src/commands/run_command.dart',
      'flutter_testsmith_cli/lib/src/commands/suite_command.dart',
    ]) {
      final source = _source(file);
      expect(
        source,
        contains('resolveFigmaSources('),
        reason: '$file must not reach Figma for itself',
      );
      expect(
        source,
        isNot(contains('FigmaClient(')),
        reason: '$file builds its own Figma client',
      );
    }
  });
}
