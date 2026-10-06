// Which flutter the tool runs.
//
// Every consumer passed the bare name `flutter` and let the operating
// system search. That worked, but it could not say *what* it had run:
// `testsmith doctor` printed a version with no way to tell which of two
// SDKs on a machine produced it.
//
// PATH remains the only source - this is not a policy change, it is the
// existing policy made explicit and reportable. What does change is the
// filename rule, and it cannot be borrowed from adb. adb ships as exactly
// one file, so existence is a safe test. The Flutter SDK ships BOTH
// `bin/flutter` (a POSIX shell script) and `bin/flutter.bat`, and on
// Windows the first of those exists and will not run:
//
//   D:\FlutterSDK\flutter\bin\flutter      -> %1 is not a valid Win32 application
//   D:\FlutterSDK\flutter\bin\flutter.bat  -> Flutter 3.44.7 - channel stable
//
// So on Windows the extensionless name is deliberately not a candidate,
// however plainly it exists.
//
// Tested on both platforms from either platform, through the seams the
// resolver exposes for exactly that. Nothing here executes flutter.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// A filesystem described as a set of paths that exist.
bool Function(String) _fs(Set<String> paths) => paths.contains;

void main() {
  group('on POSIX', () {
    const first = '/opt/flutter/bin/flutter';
    const second = '/usr/local/bin/flutter';

    FlutterLocation resolve(
      Map<String, String> environment, {
      Set<String> files = const {first, second},
    }) =>
        resolveFlutter(
          environment: environment,
          windows: false,
          exists: _fs(files),
        );

    test('the only candidate is the extensionless name', () {
      expect(flutterFileNames(windows: false), ['flutter']);
    });

    test('resolves to a full path, never the bare name', () {
      final located = resolve(const {'PATH': '/opt/flutter/bin'});

      expect(located.isFound, isTrue);
      expect(located.executable, first);
      expect(located.executable, isNot('flutter'));
    });

    test('the first matching PATH entry wins', () {
      final located = resolve(const {
        'PATH': '/opt/flutter/bin:/usr/local/bin',
      });

      expect(located.executable, first);
    });

    test('PATH order decides, not the filesystem', () {
      // The same two directories, named the other way round.
      final located = resolve(const {
        'PATH': '/usr/local/bin:/opt/flutter/bin',
      });

      expect(located.executable, second);
    });

    test('an entry with no flutter is skipped, not fatal', () {
      final located = resolve(const {
        'PATH': '/empty:/nothing/here:/opt/flutter/bin',
      });

      expect(located.executable, first);
    });

    test('splits on colons and ignores empty entries', () {
      final located = resolve(const {'PATH': ':/opt/flutter/bin:'});

      expect(located.executable, first);
    });

    test('a trailing separator on an entry does not double up', () {
      final located = resolve(const {'PATH': '/opt/flutter/bin/'});

      expect(located.executable, first);
    });
  });

  group('on Windows', () {
    const bat = r'C:\flutter\bin\flutter.bat';
    const cmd = r'C:\flutter\bin\flutter.cmd';
    const exe = r'C:\flutter\bin\flutter.exe';
    const script = r'C:\flutter\bin\flutter';

    FlutterLocation resolve(
      Map<String, String> environment, {
      Set<String> files = const {bat},
    }) =>
        resolveFlutter(
          environment: environment,
          windows: true,
          exists: _fs(files),
        );

    test('the candidates are the runnable ones, in order', () {
      expect(
        flutterFileNames(windows: true),
        ['flutter.bat', 'flutter.cmd', 'flutter.exe'],
      );
    });

    test('finds flutter.bat', () {
      final located = resolve(const {'PATH': r'C:\flutter\bin'});

      expect(located.executable, bat);
    });

    test('falls to flutter.cmd when there is no .bat', () {
      final located = resolve(
        const {'PATH': r'C:\flutter\bin'},
        files: const {cmd, exe},
      );

      expect(located.executable, cmd);
    });

    test('falls to flutter.exe when there is neither', () {
      final located = resolve(
        const {'PATH': r'C:\flutter\bin'},
        files: const {exe},
      );

      expect(located.executable, exe);
    });

    test('prefers .bat over .cmd and .exe in the same directory', () {
      final located = resolve(
        const {'PATH': r'C:\flutter\bin'},
        files: const {bat, cmd, exe},
      );

      expect(located.executable, bat);
    });

    test('never selects the extensionless script, though it is there', () {
      // The measured Windows failure: the file exists and is not a Win32
      // executable. An existence-only rule, which is what adb uses, would
      // pick exactly this.
      final located = resolve(
        const {'PATH': r'C:\flutter\bin'},
        files: const {script},
      );

      expect(located.isFound, isFalse);
      expect(located.executable, isNot(script));
    });

    test('a directory with only the script is skipped for one with a .bat',
        () {
      final located = resolve(
        const {'PATH': r'C:\script-only;C:\flutter\bin'},
        files: const {r'C:\script-only\flutter', bat},
      );

      expect(located.executable, bat);
    });

    test('splits PATH on semicolons and strips quotes', () {
      final located = resolve(const {
        'PATH': r'C:\Windows;"C:\flutter\bin";C:\Other',
      });

      expect(located.executable, bat);
    });

    test('joins with backslashes, so the path reads like a Windows path', () {
      final located = resolve(const {'PATH': r'C:\flutter\bin'});

      expect(located.executable, isNot(contains('/')));
    });
  });

  // S10-A. A PATH entry may be relative - `tools`, `.`, `..\tools` are
  // all legal - and a relative entry used to come back as a relative
  // executable. That string means one file to whoever validated it and
  // another to whoever runs it from somewhere else, and `AppSession`
  // does run it from somewhere else: it launches `flutter run` with the
  // application root as the child's working directory. Measured on
  // Windows before this group existed:
  //
  //   PATH=tools, cwd=A, workingDirectory=B
  //     -> resolver returned  tools\flutter.bat  (validated under A)
  //     -> the child ran      B\tools\flutter.bat
  //
  // A different SDK, silently; or, with no `tools` under B, exit 1 with
  // "The system cannot find the path specified." and no exception - so
  // the launch waited out its whole timeout.
  //
  // The rule is that the path handed back is the path that was checked.
  group('a found flutter is the file that was validated', () {
    group('an absolute entry is left exactly as it was', () {
      test('POSIX, whatever base is in force', () {
        final located = resolveFlutter(
          environment: const {'PATH': '/opt/flutter/bin'},
          windows: false,
          discoveryBase: '/somewhere/else/entirely',
          exists: _fs(const {'/opt/flutter/bin/flutter'}),
        );

        expect(located.executable, '/opt/flutter/bin/flutter');
      });

      test('a Windows drive letter', () {
        final located = resolveFlutter(
          environment: const {'PATH': r'C:\flutter\bin'},
          windows: true,
          discoveryBase: r'D:\somewhere\else',
          exists: _fs(const {r'C:\flutter\bin\flutter.bat'}),
        );

        expect(located.executable, r'C:\flutter\bin\flutter.bat');
      });

      test('a Windows UNC share', () {
        final located = resolveFlutter(
          environment: const {'PATH': r'\\build\sdks\flutter\bin'},
          windows: true,
          discoveryBase: r'D:\somewhere\else',
          exists: _fs(const {r'\\build\sdks\flutter\bin\flutter.bat'}),
        );

        expect(located.executable, r'\\build\sdks\flutter\bin\flutter.bat');
      });
    });

    group('a relative entry is resolved against the discovery base', () {
      test('a plain relative directory, POSIX', () {
        final located = resolveFlutter(
          environment: const {'PATH': 'tools'},
          windows: false,
          discoveryBase: '/home/me',
          exists: _fs(const {'/home/me/tools/flutter'}),
        );

        expect(located.executable, '/home/me/tools/flutter');
      });

      test('a plain relative directory, Windows', () {
        final located = resolveFlutter(
          environment: const {'PATH': 'tools'},
          windows: true,
          discoveryBase: r'D:\work',
          exists: _fs(const {r'D:\work\tools\flutter.bat'}),
        );

        expect(located.executable, r'D:\work\tools\flutter.bat');
      });

      test('the current-directory entry', () {
        final located = resolveFlutter(
          environment: const {'PATH': '.'},
          windows: false,
          discoveryBase: '/home/me',
          exists: _fs(const {'/home/me/./flutter'}),
        );

        // Spelled as it was found, not tidied: `.` is not collapsed for
        // the same reason `..` is not, below.
        expect(located.executable, '/home/me/./flutter');
      });

      test('a parent-relative entry, left uncollapsed', () {
        // Absolute, which is the whole guarantee. Not normalised: with a
        // symlink in the base, collapsing `..` lexically names a
        // different directory than walking it does.
        final located = resolveFlutter(
          environment: const {'PATH': '../tools'},
          windows: false,
          discoveryBase: '/home/me',
          exists: _fs(const {'/home/me/../tools/flutter'}),
        );

        expect(located.executable, '/home/me/../tools/flutter');
      });

      test('a base that is itself a root, POSIX', () {
        // `/` keeps its own separator, and must not gain a second one:
        // `//tools/flutter` reads like a bug in the report it appears in.
        final located = resolveFlutter(
          environment: const {'PATH': 'tools'},
          windows: false,
          discoveryBase: '/',
          exists: _fs(const {'/tools/flutter'}),
        );

        expect(located.executable, '/tools/flutter');
      });

      test('a base that is itself a drive root, Windows', () {
        // `C:\` loses its trailing separator on the way in and must get
        // one back: `C:tools\flutter.bat` is relative to whatever
        // directory the C drive happens to be sitting on.
        final located = resolveFlutter(
          environment: const {'PATH': 'tools'},
          windows: true,
          discoveryBase: r'C:\',
          exists: _fs(const {r'C:\tools\flutter.bat'}),
        );

        expect(located.executable, r'C:\tools\flutter.bat');
      });

      test('a quoted relative entry', () {
        final located = resolveFlutter(
          environment: const {'PATH': r'"tools"'},
          windows: true,
          discoveryBase: r'D:\work',
          exists: _fs(const {r'D:\work\tools\flutter.bat'}),
        );

        expect(located.executable, r'D:\work\tools\flutter.bat');
      });
    });

    test('PATH order is untouched: the relative entry still wins', () {
      // The entry that wins is decided before any of this, and is the
      // same entry it always was. Only its spelling changes.
      final located = resolveFlutter(
        environment: const {'PATH': r'tools;C:\flutter\bin'},
        windows: true,
        discoveryBase: r'D:\work',
        exists: _fs(const {
          r'D:\work\tools\flutter.bat',
          r'C:\flutter\bin\flutter.bat',
        }),
      );

      expect(located.executable, r'D:\work\tools\flutter.bat');
    });

    test('the base decides, so the same PATH can name two flutters', () {
      // The test that proves the base is honoured rather than the host's
      // own directory quietly standing in for it.
      FlutterLocation from(String base) => resolveFlutter(
            environment: const {'PATH': 'tools'},
            windows: false,
            discoveryBase: base,
            exists: _fs(const {
              '/one/tools/flutter',
              '/two/tools/flutter',
            }),
          );

      expect(from('/one').executable, '/one/tools/flutter');
      expect(from('/two').executable, '/two/tools/flutter');
    });

    test('the file it asks about is the file it returns', () {
      // The invariant itself. Validation and the answer cannot be about
      // two different files, because they are the same string.
      final asked = <String>[];
      final located = resolveFlutter(
        environment: const {'PATH': 'tools'},
        windows: false,
        discoveryBase: '/home/me',
        exists: (path) {
          asked.add(path);
          return path == '/home/me/tools/flutter';
        },
      );

      expect(asked, ['/home/me/tools/flutter']);
      expect(located.executable, '/home/me/tools/flutter');
    });

    test('the base defaults to where the process is standing', () {
      // What production gets. `exists` says yes to the first candidate,
      // so this asserts the base and nothing else.
      final located = resolveFlutter(
        environment: const {'PATH': 'tools'},
        exists: (_) => true,
      );

      expect(located.isFound, isTrue);
      expect(located.executable, startsWith(Directory.current.path));
    });
  });

  group('when it is not there', () {
    test('is absent, and says so in PATH terms', () {
      final located = resolveFlutter(
        environment: const {'PATH': '/nowhere'},
        windows: false,
        exists: _fs(const {}),
      );

      expect(located.isFound, isFalse);
      expect(located.executable, isNull);
      expect(located.problem, contains('PATH'));
      expect(located.hint, contains('flutter.dev'));
    });

    test('an unset PATH is absent rather than a crash', () {
      final located = resolveFlutter(
        environment: const {},
        windows: false,
        exists: _fs(const {}),
      );

      expect(located.isFound, isFalse);
    });

    test('falls back to the bare name for callers that must try anyway', () {
      // What the tool has always done. The difference is that the reason
      // is now available to say out loud.
      final located = resolveFlutter(
        environment: const {},
        windows: false,
        exists: _fs(const {}),
      );

      expect(located.executableOrBareName, 'flutter');
    });
  });

  group('the process layer runs exactly what was resolved', () {
    // The failure this guards against is subtle and would be silent:
    // the resolver chooses X, and executableCandidates - which exists to
    // guess extensions for bare names - quietly tries something else.
    // A resolved path has both an extension and a separator, and both of
    // those make it pass through untouched. Pinned here so the two
    // policies cannot drift into disagreeing.
    test('a resolved Windows path is not re-guessed', () {
      const resolved = r'C:lutterinlutter.bat';

      expect(executableCandidates(resolved, isWindows: true), [resolved]);
    });

    test('a resolved POSIX path is not re-guessed', () {
      const resolved = '/opt/flutter/bin/flutter';

      expect(executableCandidates(resolved, isWindows: false), [resolved]);
    });

    test('every candidate this policy can return survives the process layer',
        () {
      for (final windows in [true, false]) {
        for (final name in flutterFileNames(windows: windows)) {
          final resolved = windows ? r'C:in' + name : '/bin/$name';

          expect(
            executableCandidates(resolved, isWindows: windows),
            [resolved],
            reason: 'windows=$windows name=$name',
          );
        }
      }
    });

    test('the bare name is still expanded, for adb and anything else', () {
      // Non-regression: the generic behaviour is untouched. Only a
      // resolved path opts out of it, and it does so by being a path.
      expect(
        executableCandidates('adb', isWindows: true),
        ['adb', 'adb.bat', 'adb.cmd', 'adb.exe'],
      );
    });
  });

  group('locating never runs anything', () {
    test('only asks whether files exist', () {
      // Every question the resolver asks arrives here. If it wanted to
      // execute a candidate to identify it, it could not: there is no
      // process seam to do it through.
      final asked = <String>[];
      final located = resolveFlutter(
        environment: const {'PATH': '/a:/b'},
        windows: false,
        exists: (path) {
          asked.add(path);
          return path == '/b/flutter';
        },
      );

      expect(located.executable, '/b/flutter');
      expect(asked, ['/a/flutter', '/b/flutter']);
    });

    test('stops asking once it has an answer', () {
      final asked = <String>[];
      resolveFlutter(
        environment: const {'PATH': '/a:/b:/c'},
        windows: false,
        exists: (path) {
          asked.add(path);
          return path == '/a/flutter';
        },
      );

      expect(asked, ['/a/flutter'], reason: 'no directory after the hit');
    });
  });
}
