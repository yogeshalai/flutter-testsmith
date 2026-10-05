// S8, driven through the real executable from a cwd that is not the
// application.
//
// Every existing command test runs with `workingDirectory` set to the CLI
// package root and names its `--out` absolutely, which is precisely why a
// cwd-relative `--out` survived this long: no test ever stood anywhere
// else. These do.
//
// `suite run` is the vehicle because it is the one command that reaches a
// real write with no device attached: a blocked preflight still writes
// suite.json, deliberately, because CI wants an answer either way. The
// rule it exercises is not suite-specific - it is the shared resolver in
// output_path.dart, covered directly in output_path_test.dart and held to
// by every command in output_path_policy_test.dart.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _elsewhere;

/// The application the suite names. Not the cwd of any run below.
String get _app => '${_root.path}/proj';

Future<ProcessResult> _testsmith(
  List<String> arguments, {
  required String from,
  Map<String, String> environment = const {},
}) =>
    Process.run(
      Platform.resolvedExecutable,
      ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
      workingDirectory: from,
      environment: environment,
    );

void _write(String path, String contents) {
  File('${_root.path}/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

const String _suite = '''
suite: s
app: {path: proj}
device: {profile: p}
tests:
  - {id: a, flow: flows/a.yaml}
''';

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('s8_out');
    _elsewhere = Directory.systemTemp.createTempSync('s8_cwd');
    addTearDown(() {
      _root.deleteSync(recursive: true);
      _elsewhere.deleteSync(recursive: true);
    });

    _write('proj/pubspec.yaml', 'name: proj\n');
    _write('proj/device_profiles/p.yaml', 'id: p\n');
    _write(
      'proj/flows/a.yaml',
      'appId: com.example.app\nflow: a\nsteps:\n  - launchApp\n',
    );
    _write('s.yaml', _suite);
  });

  test('a relative --out lands under the application, not the cwd', () async {
    await _testsmith(
      ['suite', 'run', '${_root.path}/s.yaml', '-d', 'no-such-device',
        '--out', 'out/results'],
      from: _elsewhere.path,
    );

    expect(
      File('$_app/out/results/suite.json').existsSync(),
      isTrue,
      reason: 'the report belongs to the application the suite names',
    );
  });

  test('a relative --out writes nothing into the cwd', () async {
    // The other half of the same sentence, and the half that was the
    // actual bug: the artifacts used to appear wherever the caller was
    // standing.
    await _testsmith(
      ['suite', 'run', '${_root.path}/s.yaml', '-d', 'no-such-device',
        '--out', 'out/results'],
      from: _elsewhere.path,
    );

    expect(
      Directory('${_elsewhere.path}/out').existsSync(),
      isFalse,
      reason: 'nothing may be written relative to where the caller stood',
    );
  });

  test('an absolute --out is the directory that was named', () async {
    final named = '${_root.path}/somewhere/else';

    await _testsmith(
      ['suite', 'run', '${_root.path}/s.yaml', '-d', 'no-such-device',
        '--out', named],
      from: _elsewhere.path,
    );

    expect(File('$named/suite.json').existsSync(), isTrue);
    expect(Directory('$_app/somewhere').existsSync(), isFalse,
        reason: 'an absolute path must not be joined onto the app root');
  });

  test('the default --out lands under the application', () async {
    // `suite run` defaults to `out/suite`. The default is resolved the
    // same way an explicit value is - that is invariant D.
    await _testsmith(
      ['suite', 'run', '${_root.path}/s.yaml', '-d', 'no-such-device'],
      from: _elsewhere.path,
    );

    expect(File('$_app/out/suite/suite.json').existsSync(), isTrue);
    expect(Directory('${_elsewhere.path}/out').existsSync(), isFalse);
  });

  test('figma pull no longer escapes the application when --out is typed',
      () async {
    // The split S8 removed: an explicit `--out` used to skip root
    // resolution entirely and write relative to the cwd, while the
    // default resolved against the application. Typing the default out
    // by hand therefore moved the file. Now there is one base, so from
    // a directory that is not in any Flutter project the command has to
    // say so rather than quietly writing beside the caller.
    //
    // The token is a placeholder: this never reaches Figma, because the
    // root is resolved first.
    final result = await _testsmith(
      ['figma', 'pull', '--file-key', 'k', '--node-id', '1:2',
        '--screen', '/home', '--out', 'out/specs'],
      from: _elsewhere.path,
      environment: {'FIGMA_TOKEN': 'placeholder-not-used'},
    );

    expect(result.exitCode, 1);
    expect(result.stdout.toString(), contains('not inside a Flutter project'));
    expect(Directory('${_elsewhere.path}/out').existsSync(), isFalse);
  });

  test('two different cwds resolve to the same output path', () async {
    Future<void> runFrom(String cwd) => _testsmith(
          ['suite', 'run', '${_root.path}/s.yaml', '-d', 'no-such-device',
            '--out', 'out/results'],
          from: cwd,
        );

    await runFrom(_elsewhere.path);
    final first = File('$_app/out/results/suite.json');
    expect(first.existsSync(), isTrue);
    Directory('$_app/out').deleteSync(recursive: true);

    // The application directory itself - the cwd the old tests always
    // used, and the one case where cwd and app root agreed.
    await runFrom(_app);

    expect(first.existsSync(), isTrue,
        reason: 'where the caller stands may not move the report');
  });
}
