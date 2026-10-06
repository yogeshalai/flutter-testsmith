// R9: `generate` chose a mapping by directory listing order.
//
// Every other command reads `mappings/` through `loadMappings`, which
// indexes by screen and refuses a repeat - `DuplicateScreenException`,
// "neither file is the winner, because there is no winner". `generate`
// listed the directory itself and never reached that:
//
//     mappingsDirectory.listSync().whereType<File>()...
//     final chosen = wantedScreen == null
//         ? mappings.first
//         : mappings.firstWhere((m) => m.screen == wantedScreen);
//
// so it answered two questions by whichever file came back first.
// Measured on Windows against df2ab39:
//
//   two files, both `screen: /home`
//     run        Duplicate screen configuration        exit 1
//     preflight  [BLOCK] screen configuration          exit 2
//     generate   reached the AI credential gate        exit 1
//
//   one file `screen: /home` (reachable) and one `screen: /other` (not),
//   no --screen given - the same two files, renamed:
//     a_x.yaml=/home  z_x.yaml=/other   generate reached the gate
//     a_x.yaml=/other z_x.yaml=/home    No existing flow reaches "/other"
//
// Identical project content, different answer, decided by a filename.
// `Directory.listSync()` order is unspecified by dart:io and is not the
// same on every filesystem, so this is the defect
// `duplicate_screen_config_test.dart` already describes: "one project
// could validate against two different configurations on two machines".
//
// The rule this restores is the one in the invariant table: the platform
// never guesses between candidates - not devices, not duplicate test
// ids, not two configs for one screen. `selectSoleDevice` refuses to
// pick one of several handsets for exactly this reason.
//
// Offline throughout. `ai.yaml` names a variable nothing sets, so a
// project that gets as far as the credential gate has proved it got past
// the mapping selection, and stops before any request.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

/// The gate a sound project stops at, having chosen a screen.
const String _gate = 'MYTEST_FIXTURE_ABSENT_KEY';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

void _mapping(String file, String screen) => _write(
      'mappings/$file.yaml',
      'screen: $screen\n'
      'mappings:\n  - {target: t.a, source: response.a}\n',
    );

typedef Run = ({String output, int code});

Future<Run> _generate({String? screen}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'generate',
      '--app',
      _app.path,
      if (screen != null) ...['--screen', screen],
    ],
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('generate_selection');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    // One flow, reaching /home and nothing else.
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n'
      '  - launchApp\n'
      '  - expectScreen:\n      id: /home\n'
      '  - validateScreen\n',
    );
    _write('ai.yaml', 'apiKeyEnv: $_gate\n');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  test('one screen configured is chosen without being asked', () async {
    // The control. Everything below must not disturb it.
    _mapping('home', '/home');

    final run = await _generate();

    expect(run.output, contains(_gate), reason: run.output);
    expect(run.code, 1, reason: run.output);
  });

  test('two files for one screen are refused, as everywhere else', () async {
    _mapping('a_home', '/home');
    _mapping('z_home', '/home');

    final run = await _generate(screen: '/home');

    expect(run.output, contains('Duplicate screen configuration'),
        reason: run.output);
    expect(run.output, contains('a_home.yaml'), reason: run.output);
    expect(run.output, contains('z_home.yaml'), reason: run.output);
    // Refused before the model was ever consulted.
    expect(run.output, isNot(contains(_gate)), reason: run.output);
    // `generate`'s own error code, unchanged.
    expect(run.code, 1, reason: run.output);
    expect(run.output, isNot(contains('Unhandled exception')),
        reason: run.output);
  });

  test('several screens with none named is refused, and they are listed',
      () async {
    _mapping('home', '/home');
    _mapping('other', '/other');

    final run = await _generate();

    expect(run.output, contains('/home'), reason: run.output);
    expect(run.output, contains('/other'), reason: run.output);
    expect(run.output, contains('--screen'), reason: run.output);
    expect(run.output, isNot(contains(_gate)), reason: run.output);
    expect(run.code, 1, reason: run.output);
  });

  test('several screens with one named proceeds', () async {
    _mapping('home', '/home');
    _mapping('other', '/other');

    final run = await _generate(screen: '/home');

    expect(run.output, contains(_gate), reason: run.output);
    expect(run.code, 1, reason: run.output);
  });

  test('a screen nobody configured is still named as such', () async {
    // Unchanged wording: this is not an ambiguity, it is an absence.
    _mapping('home', '/home');

    final run = await _generate(screen: '/nowhere');

    expect(run.output, contains('No mappings for'), reason: run.output);
    expect(run.output, contains('/nowhere'), reason: run.output);
    expect(run.code, 1, reason: run.output);
  });

  test('the answer does not depend on what the files are called', () async {
    // The measurement that named this milestone. Same two screens, same
    // contents, the file names exchanged - and before R9 one ordering
    // reached the credential gate while the other failed on a screen no
    // flow reaches.
    //
    // Deliberately without `--screen`: naming one is what sidesteps the
    // ordering, so pinning it here would test nothing.
    _mapping('a_x', '/home');
    _mapping('z_x', '/other');
    final first = await _generate();

    File('${_app.path}/mappings/a_x.yaml').deleteSync();
    File('${_app.path}/mappings/z_x.yaml').deleteSync();
    _mapping('a_x', '/other');
    _mapping('z_x', '/home');
    final second = await _generate();

    expect(first.code, second.code, reason: '${first.output}\n${second.output}');
    // Neither ordering may reach the model, and neither may fail over a
    // screen the other never chose: both are asked to name one.
    expect(first.output, contains('--screen'), reason: first.output);
    expect(second.output, contains('--screen'), reason: second.output);
    expect(first.output, isNot(contains('No existing flow reaches')),
        reason: first.output);
    expect(second.output, isNot(contains('No existing flow reaches')),
        reason: second.output);
  });
}
