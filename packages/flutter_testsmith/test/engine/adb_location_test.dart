// Which adb the tool runs.
//
// Every consumer used to pass the bare name `adb` and let the operating
// system search PATH. Measured on the machine this was written on: PATH
// held platform-tools 33.0.3 (an old standalone install) while
// ANDROID_HOME pointed at 36.0.0 (the SDK Android Studio manages, and the
// one Flutter and Gradle use). `testsmith` silently used the older one.
//
// That is not only a version skew. adb runs a background server, the two
// versions do not share one, and whichever starts first owns port 5037 -
// so a stale adb on PATH is a live source of device trouble, not a
// cosmetic difference.
//
// The policy is tested on both platforms from either platform, through
// the seams the resolver exposes for exactly that, and nothing here
// executes adb or touches a real SDK.
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// A filesystem described as a set of paths that exist.
bool Function(String) _fs(Set<String> paths) => paths.contains;

void main() {
  group('on Windows', () {
    const sdk = r'D:\Android\Sdk';
    const sdkAdb = r'D:\Android\Sdk\platform-tools\adb.exe';
    const pathAdb = r'C:\platform-tools\adb.exe';

    AdbLocation resolve(
      Map<String, String> environment, {
      Set<String> files = const {sdkAdb, pathAdb},
    }) =>
        resolveAdb(
          environment: environment,
          windows: true,
          exists: _fs(files),
        );

    test('looks for adb.exe, not adb', () {
      expect(adbFileName(windows: true), 'adb.exe');

      final located = resolve(const {'ANDROID_HOME': sdk});

      expect(located.executable, sdkAdb);
    });

    test('splits PATH on semicolons and strips quotes', () {
      final located = resolve(const {
        'PATH': r'C:\Windows;"C:\platform-tools";C:\Other',
      });

      expect(located.executable, pathAdb);
      expect(located.source, AdbSource.path);
    });

    test('joins with backslashes, so a diagnostic is readable', () {
      final located = resolve(const {'ANDROID_HOME': sdk});

      expect(located.executable, isNot(contains('/')));
    });

    test('tolerates a trailing separator on the SDK path', () {
      final located = resolve(const {'ANDROID_HOME': '$sdk\\'});

      expect(located.executable, sdkAdb);
    });

    // AUDIT-2. `SystemProcessRunner` runs a bare `adb` on Windows as
    // `adb`, `adb.bat`, `adb.cmd`, `adb.exe` in turn, each searched along
    // the whole PATH, so a wrapper script on PATH is an adb that runs.
    // This scan looked for `adb.exe` alone. Measured at 1588d1a with only
    // an `adb.cmd` on PATH: `devices` and `run` used it, `doctor` said
    // "adb could not be found" and then listed its device, and
    // `preflight`, `suite run` and `auth setup` refused. One machine, two
    // answers to "is there an adb".
    group('finds on PATH what a bare launch would run', () {
      AdbLocation onPath(Set<String> files, String path) => resolveAdb(
            environment: {'PATH': path},
            windows: true,
            exists: _fs(files),
          );

      for (final wrapper in const ['adb.bat', 'adb.cmd']) {
        test('an $wrapper and nothing else', () {
          final file = 'C:\\tools\\$wrapper';

          final located = onPath({file}, r'C:\Windows;C:\tools');

          expect(located.isFound, isTrue, reason: located.problem);
          expect(located.executable, file);
          expect(located.source, AdbSource.path);
        });
      }

      test('adb.exe anywhere on PATH before a wrapper earlier on it', () {
        // The runner tries `adb` - which the OS resolves to `adb.exe`
        // along the whole PATH - before it tries `adb.bat`. So an
        // `adb.exe` later on PATH is what runs, and what must be named.
        final located = onPath(
          const {r'C:\early\adb.bat', r'C:\late\adb.exe'},
          r'C:\early;C:\late',
        );

        expect(located.executable, r'C:\late\adb.exe');
      });

      test('adb.bat before adb.cmd, as the runner tries them', () {
        final located = onPath(
          const {r'C:\early\adb.cmd', r'C:\late\adb.bat'},
          r'C:\early;C:\late',
        );

        expect(located.executable, r'C:\late\adb.bat');
      });

      test('the names are the runner\'s own, not a second list', () {
        // Every candidate the runner would try for a bare `adb`, with the
        // extensionless one spelled as the `.exe` the OS resolves it to.
        final runnerNames = {
          for (final name in executableCandidates('adb', isWindows: true))
            name.contains('.') ? name : '$name.exe',
        };

        for (final name in runnerNames) {
          final file = 'C:\\only\\$name';
          expect(onPath({file}, r'C:\only').executable, file, reason: name);
        }
        expect(onPath(const {r'C:\only\adb.com'}, r'C:\only').isFound,
            isFalse,
            reason: 'nothing the runner would not try');
      });

      test('the SDK is still looked in for adb.exe alone', () {
        // platform-tools ships adb.exe; nothing establishes a wrapper
        // there, so none is invented.
        final located = resolveAdb(
          environment: const {'ANDROID_HOME': sdk},
          windows: true,
          exists: _fs(const {r'D:\Android\Sdk\platform-tools\adb.bat'}),
        );

        expect(located.isFound, isFalse);
      });

      test('an explicit adb that is not there is still its own answer', () {
        final located = resolveAdb(
          environment: const {
            'MYTEST_ADB': r'C:\nowhere\adb.exe',
            'PATH': r'C:\tools',
          },
          windows: true,
          exists: _fs(const {r'C:\tools\adb.cmd'}),
        );

        expect(located.namedButAbsent, isTrue);
        expect(located.problem, contains('MYTEST_ADB'));
      });
    });
  });

  group('on POSIX', () {
    const sdkAdb = '/home/me/Android/Sdk/platform-tools/adb';
    const pathAdb = '/usr/local/bin/adb';

    AdbLocation resolve(
      Map<String, String> environment, {
      Set<String> files = const {sdkAdb, pathAdb},
    }) =>
        resolveAdb(
          environment: environment,
          windows: false,
          exists: _fs(files),
        );

    test('looks for adb, not adb.exe', () {
      expect(adbFileName(windows: false), 'adb');

      final located = resolve(const {'ANDROID_HOME': '/home/me/Android/Sdk'});

      expect(located.executable, sdkAdb);
    });

    test('splits PATH on colons', () {
      final located = resolve(const {'PATH': '/usr/bin:/usr/local/bin:/opt'});

      expect(located.executable, pathAdb);
      expect(located.source, AdbSource.path);
    });
  });

  group('precedence', () {
    const explicit = '/opt/tools/adb';
    const sdkAdb = '/sdk/platform-tools/adb';
    const rootAdb = '/sdkroot/platform-tools/adb';
    const pathAdb = '/usr/bin/adb';
    const everything = {explicit, sdkAdb, rootAdb, pathAdb};

    AdbLocation resolve(
      Map<String, String> environment, {
      Set<String> files = everything,
    }) =>
        resolveAdb(
          environment: environment,
          windows: false,
          exists: _fs(files),
        );

    test('MYTEST_ADB beats every other source', () {
      final located = resolve(const {
        'MYTEST_ADB': explicit,
        'ANDROID_HOME': '/sdk',
        'ANDROID_SDK_ROOT': '/sdkroot',
        'PATH': '/usr/bin',
      });

      expect(located.executable, explicit);
      expect(located.source, AdbSource.explicit);
    });

    test('ANDROID_HOME beats ANDROID_SDK_ROOT', () {
      // Not interchangeable, and not arbitrary: Google deprecated
      // ANDROID_SDK_ROOT, and the Flutter tool reads them in this order.
      final located = resolve(const {
        'ANDROID_HOME': '/sdk',
        'ANDROID_SDK_ROOT': '/sdkroot',
        'PATH': '/usr/bin',
      });

      expect(located.executable, sdkAdb);
      expect(located.source, AdbSource.androidHome);
    });

    test('ANDROID_SDK_ROOT is still used when it is the only one', () {
      final located = resolve(const {
        'ANDROID_SDK_ROOT': '/sdkroot',
        'PATH': '/usr/bin',
      });

      expect(located.executable, rootAdb);
      expect(located.source, AdbSource.androidSdkRoot);
    });

    test('an SDK variable beats PATH', () {
      // The defect, stated as a rule. This is the case measured on the
      // development machine: both existed and PATH was winning.
      final located = resolve(const {
        'ANDROID_HOME': '/sdk',
        'PATH': '/usr/bin',
      });

      expect(located.executable, sdkAdb);
      // The negative control: the bare name the tool used to pass would
      // have run the PATH copy, and must not be what comes back.
      expect(located.executable, isNot('adb'));
      expect(located.executable, isNot(pathAdb));
    });

    test('PATH is used when no SDK variable is set', () {
      final located = resolve(const {'PATH': '/usr/bin'});

      expect(located.executable, pathAdb);
      expect(located.source, AdbSource.path);
    });

    test('an empty variable counts as unset', () {
      final located = resolve(const {'ANDROID_HOME': '  ', 'PATH': '/usr/bin'});

      expect(located.executable, pathAdb);
      expect(located.skipped, isEmpty);
    });
  });

  group('when a configured location holds nothing', () {
    test('an explicit adb that is not there fails, and does not fall back',
        () {
      // Explicit must win even when it is wrong. Falling back would run a
      // different adb than the one somebody named, silently.
      final located = resolveAdb(
        environment: const {'MYTEST_ADB': '/opt/gone/adb', 'PATH': '/usr/bin'},
        windows: false,
        exists: _fs(const {'/usr/bin/adb'}),
      );

      expect(located.isFound, isFalse);
      expect(located.problem, contains('/opt/gone/adb'));
      expect(located.problem, contains('MYTEST_ADB'));
      // The negative control.
      expect(located.executable, isNull);
    });

    test('a stale ANDROID_HOME is recorded, and PATH still works', () {
      // Non-regression: a machine whose PATH adb works today must keep
      // working. The misconfiguration is reported, not fatal.
      final located = resolveAdb(
        environment: const {'ANDROID_HOME': '/gone', 'PATH': '/usr/bin'},
        windows: false,
        exists: _fs(const {'/usr/bin/adb'}),
      );

      expect(located.executable, '/usr/bin/adb');
      expect(located.source, AdbSource.path);
      expect(located.skipped.single, contains('ANDROID_HOME=/gone'));
      expect(located.skipped.single, contains('platform-tools'));
    });

    test('nothing anywhere names every place that was looked at', () {
      final located = resolveAdb(
        environment: const {
          'ANDROID_HOME': '/gone',
          'ANDROID_SDK_ROOT': '/also-gone',
          'PATH': '/usr/bin',
        },
        windows: false,
        exists: _fs(const {}),
      );

      expect(located.isFound, isFalse);
      expect(located.problem, contains('adb could not be found'));
      expect(located.hint, contains('/gone'));
      expect(located.hint, contains('/also-gone'));
      expect(located.skipped, hasLength(2));
    });

    test('nothing configured at all still says what to do', () {
      final located = resolveAdb(
        environment: const {},
        windows: false,
        exists: _fs(const {}),
      );

      expect(located.isFound, isFalse);
      expect(located.hint, contains('ANDROID_HOME'));
      expect(located.hint, contains('MYTEST_ADB'));
    });

    test('the bare name remains the fallback for a caller that runs anyway',
        () {
      final located = resolveAdb(
        environment: const {},
        windows: false,
        exists: _fs(const {}),
      );

      expect(located.executableOrBareName, 'adb');
    });
  });

  group('every adb consumer resolves the same way', () {
    test('the controller and the environment agree by default', () {
      // They address one handset. Two adb versions on one machine run two
      // servers, so disagreeing here is not a cosmetic inconsistency.
      expect(
        AdbDeviceController(serial: 'S').adbExecutable,
        resolveAdb().executableOrBareName,
      );
    });

    test('an explicitly passed executable still wins, as tests rely on', () {
      expect(
        AdbDeviceController(serial: 'S', adbExecutable: 'fake-adb')
            .adbExecutable,
        'fake-adb',
      );
    });

    test('a failure names the binary, never the directory it sits in',
        () async {
      // The resolved executable is an absolute path on most machines, and
      // this message reaches `result.json` and `report.html`. A committed
      // report must not carry somebody's home directory.
      final runner = _AlwaysFails();
      final device = AdbDeviceController(
        serial: 'S',
        processRunner: runner,
        adbExecutable: r'C:\Users\somebody\AppData\Local\Android\Sdk'
            r'\platform-tools\adb.exe',
      );

      await expectLater(
        device.pressBack(),
        throwsA(isA<DeviceCommandException>()
            .having((e) => e.command, 'command', startsWith('adb.exe '))
            .having((e) => e.command, 'command', isNot(contains('somebody')))
            .having((e) => e.command, 'command', isNot(contains('Users')))),
      );
    });
  });
}

/// An adb that refuses every command, so the failure message can be read.
class _AlwaysFails implements ProcessRunner {
  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) =>
      Future.value(
        const ProcessResultData(exitCode: 1, stdout: '', stderr: 'nope'),
      );
}
