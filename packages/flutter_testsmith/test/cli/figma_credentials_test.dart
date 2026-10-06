// Where `testsmith figma pull` gets its Figma token.
//
// The rest of the CLI resolves a credential one way: the process
// environment first, then the first `.env` found in [project, cwd],
// through `DotEnv` and `EnvSecretResolver`. `figma pull` read
// `Platform.environment['FIGMA_TOKEN']` directly, so a token living only
// in `<app>/.env` - which is where ADR-0009, E-06 and the Figma source
// resolver's own error message all tell people to put it, and which
// `.gitignore` protects - worked for `testsmith run` and `testsmith
// suite run` and failed for the command that *produces* the specs those
// two consume.
//
// Driven through the real executable, because the divergence was between
// two commands rather than two functions.
//
// Nothing here reaches Figma. Each case stops at a gate that comes after
// the credential and before the request: omitting `--screen` is past the
// token and short of the network, so "it got that far" is the proof the
// token resolved. What a token resolved *to* is never asserted, because
// asserting it would mean printing it.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/commands/figma_command.dart';
import 'package:flutter_testsmith/src/cli/dotenv.dart';
import 'package:flutter_testsmith/src/cli/secrets/env_secret_resolver.dart';
import 'package:flutter_testsmith/engine.dart';

late Directory _root;

/// A frame URL that parses, so the command gets past target resolution.
const String _url = 'https://figma.com/design/abc/File?node-id=909-1';

const String _missing = 'FIGMA_TOKEN is not set.';

/// The gate immediately after the credential, and before any request.
const String _pastTheToken = '--screen is required.';

Directory _dir(String name) =>
    Directory('${_root.path}/$name')..createSync(recursive: true);

void _writeEnv(Directory directory, String contents) =>
    File('${directory.path}/.env').writeAsStringSync(contents);

/// A directory a project root can be resolved to.
Directory _app(String name) {
  final directory = _dir(name);
  File('${directory.path}/pubspec.yaml')
      .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
  return directory;
}

/// Runs the real `testsmith figma pull`.
///
/// [from] is the working directory, because the second `.env` this
/// resolves is the one beside it.
Future<String> _pull(
  List<String> arguments, {
  required String from,
  Map<String, String> environment = const {},
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'figma',
      'pull',
      ...arguments,
    ],
    workingDirectory: from,
    environment: environment,
  );
  return '${result.stdout}${result.stderr}';
}

void main() {
  setUpAll(() {
    // These cases turn on FIGMA_TOKEN being absent from the process
    // environment, and Dart cannot unset a variable for a child. Said
    // out loud rather than silently mis-measured: a credential test that
    // quietly stops testing is worse than one that is not there.
    final leaked = Platform.environment['FIGMA_TOKEN'];
    if (leaked != null) {
      fail('FIGMA_TOKEN is set in this shell, so these cases cannot '
          'measure what they claim. Unset it and re-run.');
    }
  });

  setUp(() {
    _root = Directory.systemTemp.createTempSync('figma_credentials');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('the token resolves the way every other credential does', () {
    test('a token living only in the application .env is accepted',
        () async {
      final app = _app('app');
      _writeEnv(app, 'FIGMA_TOKEN=figd_in_the_app_env\n');

      final report = await _pull(
        ['--app', app.path, '--url', _url],
        from: _dir('elsewhere').path,
      );

      expect(report, isNot(contains(_missing)), reason: report);
      expect(report, contains(_pastTheToken), reason: report);
    });

    test('a token living only in the working directory .env is accepted',
        () async {
      // The second entry of the same list, reached when the application
      // has no file of its own.
      final app = _app('app');
      final cwd = _dir('cwd');
      _writeEnv(cwd, 'FIGMA_TOKEN=figd_in_the_cwd_env\n');

      final report = await _pull(
        ['--app', app.path, '--url', _url],
        from: cwd.path,
      );

      expect(report, isNot(contains(_missing)), reason: report);
      expect(report, contains(_pastTheToken), reason: report);
    });
  });

  group('the established ordering reaches this command', () {
    test('the application .env is the one read when both exist', () async {
      // `DotEnv.load` returns the first file it finds and reads only
      // that one. So a cwd file holding nothing useful cannot mask the
      // application's token - and if the order were reversed it would.
      final app = _app('app');
      final cwd = _dir('cwd');
      _writeEnv(app, 'FIGMA_TOKEN=figd_in_the_app_env\n');
      _writeEnv(cwd, 'SOMETHING_ELSE=x\n');

      final report = await _pull(
        ['--app', app.path, '--url', _url],
        from: cwd.path,
      );

      expect(report, isNot(contains(_missing)), reason: report);
      expect(report, contains(_pastTheToken), reason: report);
    });

    test('and the working directory .env cannot be reached past it',
        () async {
      // The same pair, the other way round. The application file is
      // found first, is the only one read, and has no token in it - so
      // the cwd token is not consulted and the command says so.
      final app = _app('app');
      final cwd = _dir('cwd');
      _writeEnv(app, 'SOMETHING_ELSE=x\n');
      _writeEnv(cwd, 'FIGMA_TOKEN=figd_in_the_cwd_env\n');

      final report = await _pull(
        ['--app', app.path, '--url', _url],
        from: cwd.path,
      );

      expect(report, contains(_missing), reason: report);
    });

    test('the process environment wins, even holding nothing', () async {
      // Precedence, end to end. `EnvSecretResolver` reads the
      // environment first and an empty value is still an answer, so a
      // token sitting in .env is not consulted. If the file had won,
      // this run would have got past the gate.
      final app = _app('app');
      _writeEnv(app, 'FIGMA_TOKEN=figd_in_the_app_env\n');

      final report = await _pull(
        ['--app', app.path, '--url', _url],
        from: _dir('elsewhere').path,
        environment: const {'FIGMA_TOKEN': ''},
      );

      expect(report, contains(_missing), reason: report);
    });

    test('the resolver this command builds has that precedence', () {
      // The mechanism itself, at the boundary the command uses it
      // through. The end-to-end case above can show the environment
      // winning with nothing in it; only here can it be shown winning
      // with something.
      final app = _app('app');
      _writeEnv(app, 'FIGMA_TOKEN=from_the_file\n');

      final resolver = EnvSecretResolver(
        dotenv: DotEnv.load([app.path, _dir('cwd').path]),
        environment: const {'FIGMA_TOKEN': 'from_the_environment'},
      );

      final ref = SecretRef.parse('env:FIGMA_TOKEN', source: 'this test');

      expect(resolver.resolve(ref).expose(), 'from_the_environment');
    });
  });

  group('the error contract is unchanged', () {
    test('a token in neither place still reports the same thing', () async {
      final app = _app('app');

      final report = await _pull(
        ['--app', app.path, '--url', _url],
        from: _dir('elsewhere').path,
      );

      expect(report, contains(_missing), reason: report);
      expect(report, contains('Create a personal access token'));
      expect(report, contains('not accepted as a flag'));
    });

    test('and there is still no way to pass one as a flag', () {
      final options = FigmaPullCommand().argParser.options.keys;

      expect(
        options.where((name) => name.toLowerCase().contains('token')),
        isEmpty,
        reason: 'a token in argv lands in shell history and the process '
            'list; options are: ${options.join(', ')}',
      );
    });
  });
}
