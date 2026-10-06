// Where the application under test is, and what happens when it is not
// there.
//
// Measured before any of this existed, in a temporary project that was a
// perfectly ordinary Flutter application: `testsmith run flow.yaml` accepted
// the built-in `--app examples/ecommerce_app` default - this repository's
// own example, which exists in no other repository - loaded no mappings,
// no designs and no fixtures from it, said nothing about any of that, and
// carried on to device selection. The next step would have been
// `flutter run` in a directory that did not exist.
//
// Half of these run the real executable, because a default and an exit
// code are not things a library call has.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/project_root.dart';

import 'support/no_device_adb.dart';

late Directory _root;

Directory _dir(String path) =>
    Directory('${_root.path}/$path')..createSync(recursive: true);

File _write(String path, String contents) =>
    File('${_root.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(contents);

/// An ordinary Flutter application: a pubspec, and nothing else promised.
///
/// Deliberately no `lib/`, no `android/`, no `integration_test/`. Those
/// are a project's business, and a tool that required them would refuse
/// projects Flutter itself builds.
Directory _project(String path) {
  _write('$path/pubspec.yaml', 'name: whatever\n');
  return Directory('${_root.path}/$path');
}

Future<ProcessResult> _mytest(
  List<String> arguments, {
  required String from,
}) =>
    Process.run(
      Platform.resolvedExecutable,
      ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
      workingDirectory: from,
      // Nothing plugged in, arranged rather than assumed: a command that
      // gets past the root it was given stops at the device gate.
      environment: noDeviceEnvironment(_root),
    );

/// A flow the runner will parse, so a test reaches the step it is about.
const String _flow = 'appId: com.acme.app\n'
    'flow: Home\n'
    'steps:\n'
    '  - expectScreen:\n'
    '      id: /home\n';

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('project_root');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('--app, when it was given', () {
    test('is taken at its word', () {
      final app = _project('app');

      final resolved = resolveProjectRoot(app.path);

      expect(resolved.isFound, isTrue);
      expect(resolved.directory!.path, app.path);
    });

    test('does not have to be a Flutter project', () {
      // `generate` and `impact` only ever read a `mytest/` tree. Refusing
      // them over a missing pubspec would buy a restriction and no safety,
      // so the marker is for discovery only - where the tool is guessing.
      final plain = _dir('not_a_package');

      expect(resolveProjectRoot(plain.path).isFound, isTrue);
    });

    test('is a named failure when it is not there, not a silent carry-on',
        () {
      final resolved = resolveProjectRoot('${_root.path}/nowhere');

      expect(resolved.isFound, isFalse);
      expect(resolved.directory, isNull);
      expect(resolved.problem, contains('nowhere'));
    });

    test('beats discovery, even standing inside a project', () {
      // The negative control for the rule below: discovery must never
      // override something the user actually typed.
      final outer = _project('outer');
      final elsewhere = _dir('elsewhere');

      final resolved = resolveProjectRoot(elsewhere.path, from: outer);

      expect(resolved.directory!.path, elsewhere.path);
      expect(resolved.directory!.path, isNot(outer.path));
    });
  });

  group('--app, when it was not given', () {
    test('is the project the command was run in', () {
      final app = _project('app');

      final resolved = resolveProjectRoot(null, from: app);

      expect(resolved.isFound, isTrue);
      expect(resolved.directory!.path, app.absolute.path);
    });

    test('is found from a directory nested inside the project', () {
      // Somebody standing in their own `mytest/tests` directory is running
      // the tool from a perfectly reasonable place.
      final app = _project('app');
      final nested = _dir('app/mytest/tests');

      final resolved = resolveProjectRoot(null, from: nested);

      expect(resolved.directory!.path, app.absolute.path);
    });

    test('is the nearest project, not the outermost', () {
      // A Flutter application inside a monorepo, or an `example/` app
      // inside a package. Both are ordinary, and both have a pubspec above
      // them that is not the application under test.
      _project('mono');
      final inner = _project('mono/example');

      final resolved = resolveProjectRoot(null, from: _dir('mono/example/x'));

      expect(resolved.directory!.path, inner.absolute.path);
    });

    test('is nothing at all outside a project, and says where it looked',
        () {
      final loose = _dir('loose');

      final resolved = resolveProjectRoot(null, from: loose);

      expect(resolved.isFound, isFalse);
      expect(resolved.directory, isNull);
      expect(resolved.hint, contains('pubspec.yaml'));
      expect(resolved.hint, contains('--app'));
    });
  });

  group('an app: path: declared by a suite or an auth file', () {
    test('is relative to the file that declared it', () {
      final app = _project('app');
      final suite = _write('app/mytest/suites/s.yaml', 'suite: S\n');

      final resolved = resolveDeclaredProjectRoot(
        declaringFile: suite,
        declaredPath: '../..',
      );

      expect(resolved.isFound, isTrue);
      expect(resolved.directory!.resolveSymbolicLinksSync(),
          app.resolveSymbolicLinksSync());
    });

    test('is taken as written when it is absolute', () {
      // Joined onto the suite's own directory this produced
      // `app/mytest/suites//tmp/.../other`, whose only symptom was every
      // flow in the suite being reported missing.
      final other = _project('other');
      final suite = _write('app/mytest/suites/s.yaml', 'suite: S\n');

      final resolved = resolveDeclaredProjectRoot(
        declaringFile: suite,
        declaredPath: other.absolute.path,
      );

      expect(resolved.isFound, isTrue);
      expect(resolved.directory!.resolveSymbolicLinksSync(),
          other.resolveSymbolicLinksSync());
    });

    test('names the root that is missing, not the flows that are not in it',
        () {
      final suite = _write('app/mytest/suites/s.yaml', 'suite: S\n');

      final resolved = resolveDeclaredProjectRoot(
        declaringFile: suite,
        declaredPath: '/no/such/application',
      );

      expect(resolved.isFound, isFalse);
      expect(resolved.problem, contains('/no/such/application'));
      expect(resolved.hint, contains('app.path'));
    });
  });

  group('what counts as absolute', () {
    test('a leading slash, in either dialect', () {
      expect(isAbsolutePath('/home/me/app', windows: false), isTrue);
      expect(isAbsolutePath('/home/me/app', windows: true), isTrue);
    });

    test('a drive letter or a UNC prefix, on Windows', () {
      expect(isAbsolutePath(r'D:\apps\myapp', windows: true), isTrue);
      expect(isAbsolutePath('D:/apps/myapp', windows: true), isTrue);
      expect(isAbsolutePath(r'\\server\share\app', windows: true), isTrue);
    });

    test('neither of those on POSIX, where `C:` is just a directory name',
        () {
      // The negative control. Treating `C:/x` as absolute on a POSIX host
      // would silently move somebody's project out of their repository.
      expect(isAbsolutePath('D:/apps/myapp', windows: false), isFalse);
      expect(isAbsolutePath(r'D:\apps\myapp', windows: false), isFalse);
      expect(isAbsolutePath(r'\\server\share', windows: false), isFalse);
    });

    test('a relative path, in either dialect', () {
      for (final windows in [true, false]) {
        expect(isAbsolutePath('.', windows: windows), isFalse);
        expect(isAbsolutePath('../..', windows: windows), isFalse);
        expect(isAbsolutePath('app/mytest', windows: windows), isFalse);
      }
    });
  });

  group('testsmith run, through the executable', () {
    test('works on a project that is not this repository', () async {
      // The portability case. A malformed `mappings/` file is the proof of
      // *which* directory was chosen: only the temporary project has one,
      // so the error could not have come from anywhere else. Before this,
      // the command silently used `examples/ecommerce_app` and reached
      // device selection without reading a thing.
      _project('app');
      _write('app/mappings/home.yaml', 'screen: [this is not a screen\n');
      _write('app/mytest/tests/home.yaml', _flow);

      final result = await _mytest(
        ['run', 'mytest/tests/home.yaml'],
        from: '${_root.path}/app',
      );

      expect(result.stdout, contains('MappingsFormatException'));
      expect(result.exitCode, 2);
    });

    test('is run from a directory nested inside that project', () async {
      _project('app');
      _write('app/mappings/home.yaml', 'screen: [this is not a screen\n');
      _write('app/mytest/tests/home.yaml', _flow);

      final result = await _mytest(
        ['run', 'home.yaml'],
        from: '${_root.path}/app/mytest/tests',
      );

      expect(result.stdout, contains('MappingsFormatException'));
    });

    test('says so when --app names a directory that is not there', () async {
      // `run` was the one command that never checked. Four others did, and
      // each had written the check out for itself.
      _project('app');
      _write('app/mytest/tests/home.yaml', _flow);

      final result = await _mytest(
        ['run', 'mytest/tests/home.yaml', '--app', '${_root.path}/nowhere'],
        from: '${_root.path}/app',
      );

      expect(result.exitCode, 2);
      expect(result.stdout, contains('No such app directory'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('uses --app over the project it is standing in', () async {
      // The reversed control: the malformed mappings file that proves
      // discovery must NOT be read when a root was named.
      _project('app');
      _write('app/mappings/home.yaml', 'screen: [this is not a screen\n');
      _write('app/mytest/tests/home.yaml', _flow);
      _project('other');

      final result = await _mytest(
        [
          'run',
          'mytest/tests/home.yaml',
          '--app',
          '${_root.path}/other',
        ],
        from: '${_root.path}/app',
      );

      expect(result.stdout, isNot(contains('MappingsFormatException')));
      // And reached the device gate of the root it was given - never a
      // real handset, if one is attached to the machine running this.
      expect(result.stdout, contains('No usable device attached'),
          reason: '${result.stdout}');
    });
  });

  group('testsmith preflight, through the executable', () {
    test('an absolute app: path: names the root, not the flows', () async {
      // The whole visible symptom of this was a list of flows the suite
      // had named perfectly correctly.
      _write(
        'app/mytest/suites/s.yaml',
        'suite: S\n'
        'app:\n'
        '  path: /no/such/application\n'
        'device:\n'
        '  profile: p\n'
        'tests:\n'
        '  - id: home\n'
        '    flow: mytest/tests/home.yaml\n',
      );

      final result = await _mytest(
        ['preflight', '${_root.path}/app/mytest/suites/s.yaml'],
        from: _root.path,
      );

      expect(result.exitCode, 2);
      expect(result.stdout, contains('No application at'));
      expect(result.stdout, isNot(contains('names flows that are not there')));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('a relative app: path: still resolves against the suite file',
        () async {
      // The behaviour that was already correct, and has to stay correct.
      _project('app');
      _write('app/device_profiles/p.yaml', 'id: p\n');
      _write('app/mytest/tests/home.yaml', _flow);
      _write(
        'app/mytest/suites/s.yaml',
        'suite: S\n'
        'app:\n'
        '  path: ../..\n'
        'device:\n'
        '  profile: p\n'
        'tests:\n'
        '  - id: home\n'
        '    flow: mytest/tests/home.yaml\n',
      );

      final result = await _mytest(
        ['preflight', '${_root.path}/app/mytest/suites/s.yaml'],
        from: _root.path,
      );

      expect(result.stdout, isNot(contains('No application at')));
      expect(result.stdout, isNot(contains('names flows that are not there')));
    });
  });

  // Whether two spellings name one directory.
  //
  // `figma pull --out` and the directory a run reads designs from are
  // resolved separately, so the command can only tell "the caller asked
  // for somewhere else" from "the caller spelled the default oddly" by
  // comparing them. A prefix comparison would warn about `./figma`.
  group('whether two paths name the same place', () {
    test('a spelling with . or a trailing separator is the same place', () {
      for (final spelling in ['/app/figma', '/app/./figma', '/app/figma/',
        '/app//figma', '/app/figma/.']) {
        expect(
          isSamePath(spelling, '/app/figma', windows: false),
          isTrue,
          reason: spelling,
        );
      }
    });

    test('.. is resolved in text, not on disk', () {
      expect(
        isSamePath('/app/specs/../figma', '/app/figma', windows: false),
        isTrue,
      );
    });

    test('a genuinely different directory is different', () {
      expect(isSamePath('/app/specs', '/app/figma', windows: false), isFalse);
      expect(
        isSamePath('/app/figma-old', '/app/figma', windows: false),
        isFalse,
        reason: 'a prefix is not a match',
      );
      expect(
        isSamePath('/app/figma/nested', '/app/figma', windows: false),
        isFalse,
      );
    });

    test('Windows compares either slash, and ignores case', () {
      expect(isSamePath(r'C:\app\figma', 'C:/app/figma', windows: true),
          isTrue);
      expect(isSamePath(r'C:\App\Figma', r'c:\app\figma', windows: true),
          isTrue);
    });

    test('POSIX does not ignore case, because the filesystem does not', () {
      expect(isSamePath('/app/Figma', '/app/figma', windows: false), isFalse);
    });

    test('a backslash is a separator only on Windows', () {
      // On POSIX it is an ordinary character in a file name, and
      // treating it as a separator would merge two real directories.
      expect(isSamePath(r'a\b', 'a/b', windows: false), isFalse);
      expect(isSamePath(r'a\b', 'a/b', windows: true), isTrue);
    });

    test('rooted and relative are not the same place', () {
      expect(isSamePath('/app/figma', 'app/figma', windows: false), isFalse);
    });
  });
}
