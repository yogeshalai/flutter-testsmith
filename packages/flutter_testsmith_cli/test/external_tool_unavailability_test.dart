// What every command does when the tool it needs is not installed.
//
// `testsmith doctor` has always answered this well: it says which tool is
// missing, what to do about it, and exits 1. Five other commands did not.
// Measured on Windows against 64dbbac, with PATH holding only the Dart
// SDK so that neither git nor adb can be launched:
//
//   testsmith impact           -> exit 255, Dart stack trace, and the
//                                 absolute application path inside the
//                                 leaked `git.exe -C ...` command line
//   testsmith impact --json    -> the same, so a CI job parsing the
//                                 output gets a stack trace
//   testsmith devices          -> exit 255, stack trace
//   testsmith inspect          -> exit 255, stack trace
//   testsmith smoke            -> ProcessException text in the message
//   testsmith run              -> exit 255, stack trace
//
// A missing tool is a thing somebody has to install. It is not a crash,
// and a crash is the one shape that tells them nothing.
//
// PATH isolation rather than fakes, because the defect is in what
// escapes a real process launch. `GitChanges` and `AdbDeviceController`
// are covered by throwing fakes in the engine, where the translation
// itself lives.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _project;

/// A PATH holding the Dart SDK and nothing else.
///
/// Dart itself is launched by absolute path, so this removes every tool
/// without removing the ability to run the CLI. The two Android
/// variables are emptied rather than removed because Dart cannot unset
/// one for a child, and `resolveAdb` treats an empty value as unset.
Map<String, String> get _nothingInstalled => {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
      'MYTEST_ADB': '',
    };

typedef Run = ({String output, int code});

Future<Run> _testsmith(
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: environment ?? _nothingInstalled,
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

/// Everything a missing tool must never produce.
///
/// [code] is the command's own: 1 for the commands that produce no
/// verdict, 2 for `run`, which since RUN-ENV-EXIT answers "could not
/// reach a device" with the code for the run being wrong.
void expectReportedNotCrashed(
  Run run, {
  required String names,
  int code = 1,
}) {
  expect(run.output, isNot(contains('Unhandled exception')), reason: run.output);
  expect(run.output, isNot(contains('ProcessException')), reason: run.output);
  expect(run.output, isNot(contains('#0 ')), reason: run.output);
  expect(run.output, isNot(contains('asynchronous suspension')),
      reason: run.output);
  expect(run.output, isNot(contains(_project.path)),
      reason: 'the leaked command line carried the application path:\n'
          '${run.output}');
  expect(run.code, code, reason: run.output);
  expect(run.output.toLowerCase(), contains(names), reason: run.output);
}

/// The resolver's sentence, and not the one for an adb that would not
/// launch.
///
/// AUDIT-2: `doctor`, `preflight`, `suite run` and `auth setup` said
/// "adb could not be found." for a machine with no adb, while `run`,
/// `devices`, `inspect` and `smoke` launched the bare name anyway and
/// reported the resulting `ProcessException` as "could not be started".
/// Two answers to one question; the resolver owns this one.
void _expectResolverSaidNotFound(Run run) {
  expect(run.output, contains('adb could not be found.'), reason: run.output);
  expect(run.output, isNot(contains('adb could not be started.')),
      reason: run.output);
}

/// The serial the fake adb below reports as attached.
const String _attached = 'FAKE_SERIAL';

/// An adb that runs, reports [serials], and refuses `-s` for anything
/// else exactly as the real one does.
///
/// The other half of the group above: there adb could not be started at
/// all, so nothing reached a device. Here it starts, answers, and simply
/// does not list the handset somebody named - which is the ordinary
/// case of a stale or mistyped `--device`.
///
/// Portable per A-3: a `.bat` on Windows, a shell script with the
/// executable bit set elsewhere.
String _fakeAdbDirectory(List<String> serials) {
  final directory = Directory('${_root.path}/onpath')
    ..createSync(recursive: true);

  if (Platform.isWindows) {
    final listed = [
      for (final serial in serials)
        'echo $serial               device product:fake model:FakePhone '
            'device:fake\r\n',
    ].join();
    final refusals = [
      for (final serial in serials) 'if "%2"=="$serial" exit /b 0\r\n',
    ].join();
    File('${directory.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'if "%1"=="devices" (\r\n'
      '  echo List of devices attached\r\n'
      '$listed'
      '  exit /b 0\r\n'
      ')\r\n'
      'if "%1"=="-s" (\r\n'
      '$refusals'
      "  echo error: device '%2' not found 1>&2\r\n"
      '  exit /b 1\r\n'
      ')\r\n'
      'exit /b 0\r\n',
    );
  } else {
    final listed = [
      for (final serial in serials)
        'echo "$serial               device product:fake model:FakePhone '
            'device:fake"\n',
    ].join();
    final refusals = [
      for (final serial in serials) '  if [ "\$2" = "$serial" ]; then exit 0; fi\n',
    ].join();
    final file = File('${directory.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'if [ "\$1" = "devices" ]; then\n'
        '  echo "List of devices attached"\n'
        '$listed'
        '  exit 0\n'
        'fi\n'
        'if [ "\$1" = "-s" ]; then\n'
        '$refusals'
        '  echo "error: device \'\$2\' not found" >&2\n'
        '  exit 1\n'
        'fi\n'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', file.path]);
  }
  return directory.path;
}

/// A PATH holding that adb and the Dart SDK, and nothing else.
Map<String, String> _adbReporting(
  List<String> serials, {
  bool withDart = true,
}) {
  final onPath = _fakeAdbDirectory(serials);
  // Left out when a case needs `flutter` to be genuinely absent. On a
  // host whose Dart lives inside a Flutter SDK the two share a
  // directory, so including it would put `flutter` back on PATH and the
  // case would quietly stop testing anything. The CLI is launched by
  // absolute path, so nothing needs Dart here to run.
  final dart = withDart ? File(Platform.resolvedExecutable).parent.path : null;
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final entries = [onPath, ?dart, system];
  return {
    // `cmd.exe` on Windows: a `.bat` still needs a shell to run it.
    'PATH': entries.join(Platform.isWindows ? ';' : ':'),
    'ANDROID_HOME': '',
    'ANDROID_SDK_ROOT': '',
    'MYTEST_ADB': '',
  };
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('tool_unavailable');
    _project = Directory('${_root.path}/app')..createSync(recursive: true);
    File('${_project.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    Directory('${_project.path}/tests').createSync();
    File('${_project.path}/tests/home.yaml').writeAsStringSync(
      'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
    );
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('git is not installed', () {
    test('impact reports it rather than crashing', () async {
      final run = await _testsmith(['impact', '--app', _project.path]);

      expectReportedNotCrashed(run, names: 'git');
    });

    test('impact --json reports it rather than crashing', () async {
      // The `--json` contract here is: JSON on success, a human error on
      // failure - which is what an unknown reference and a missing
      // project already do. What matters is that a CI job never receives
      // a stack trace where it expected a document.
      final run =
          await _testsmith(['impact', '--app', _project.path, '--json']);

      expectReportedNotCrashed(run, names: 'git');
      expect(run.output, isNot(contains('"changed"')),
          reason: 'no half-built document: ${run.output}');
    });

    test('--changed still works without git, as it always did', () async {
      final run = await _testsmith(
        ['impact', '--app', _project.path, '--changed', 'lib/main.dart'],
      );

      expect(run.code, 0, reason: run.output);
      expect(run.output, contains('lib/main.dart'));
    });
  });

  group('git is installed and the question fails', () {
    test('an unknown reference is still its own answer', () async {
      // The distinction this milestone must not collapse. git runs, and
      // says it does not know the reference; that is not "git is
      // missing" and must not start reading like it.
      final run = await _testsmith(
        ['impact', '--app', _project.path, '--since', 'no-such-ref'],
        environment: const {},
      );

      expect(run.code, 1, reason: run.output);
      expect(run.output, contains('no-such-ref'), reason: run.output);
      expect(run.output, isNot(contains('Unhandled exception')));
      expect(run.output.toLowerCase(), isNot(contains('is not installed')),
          reason: 'git ran; it must not be reported as missing:\n'
              '${run.output}');
    });
  });

  group('adb is not installed', () {
    test('devices reports it rather than crashing', () async {
      final run = await _testsmith(['devices']);

      expectReportedNotCrashed(run, names: 'adb');
      _expectResolverSaidNotFound(run);
    });

    test('inspect reports it when choosing a device', () async {
      final run = await _testsmith(
        ['inspect', '--app', _project.path, '--app-id', 'com.example.x'],
      );

      expectReportedNotCrashed(run, names: 'adb');
      _expectResolverSaidNotFound(run);
    });

    test('inspect reports it when a device was named', () async {
      // `--device` skips the selection gate entirely and the first adb
      // command is issued from inside the launch, which is a different
      // escape with the same shape.
      final run = await _testsmith([
        'inspect',
        '--app',
        _project.path,
        '--app-id',
        'com.example.x',
        '--device',
        'SERIAL1',
      ]);

      expectReportedNotCrashed(run, names: 'adb');
      _expectResolverSaidNotFound(run);
    });

    test('smoke reports it when choosing a device', () async {
      final run = await _testsmith(
        ['smoke', '--app', _project.path, '--app-id', 'com.example.x'],
      );

      expectReportedNotCrashed(run, names: 'adb');
      _expectResolverSaidNotFound(run);
    });

    test('smoke reports it when a device was named', () async {
      final run = await _testsmith([
        'smoke',
        '--app',
        _project.path,
        '--app-id',
        'com.example.x',
        '--device',
        'SERIAL1',
      ]);

      expectReportedNotCrashed(run, names: 'adb');
      // SMOKE-ADB. `smoke` used to launch on a named device without
      // verifying it, so with no adb it announced "waking device" and
      // then reported the controller's mid-run "adb could not be
      // started". It now asks `verifyDevice` first, as `run` and
      // `inspect` do, and says what they say.
      _expectResolverSaidNotFound(run);
      expect(run.output, isNot(contains('waking device')), reason: run.output);
      expect(run.output, isNot(contains('DeviceCommandException')),
          reason: run.output);
    });

    test('run reports it while verifying the named device', () async {
      final run = await _testsmith([
        'run',
        '${_project.path}/tests/home.yaml',
        '--app',
        _project.path,
        '-d',
        'SERIAL1',
      ]);

      expectReportedNotCrashed(run, names: 'adb', code: 2);
      _expectResolverSaidNotFound(run);
    });
  });

  /// An adb that was found and will not launch.
  ///
  /// The other half of AUDIT-2, and the only case "could not be started"
  /// is for. `MYTEST_ADB` names a file that exists - which is all the
  /// resolver asks of an explicit path - and is not a program: not a
  /// valid executable on Windows, not executable elsewhere.
  group('adb is found but cannot be started', () {
    Map<String, String> unlaunchable() {
      final directory = Directory('${_root.path}/broken_adb')
        ..createSync(recursive: true);
      final file = File(
        '${directory.path}/${Platform.isWindows ? 'adb.exe' : 'adb'}',
      )..writeAsStringSync('this is not a program\n');
      return {..._nothingInstalled, 'MYTEST_ADB': file.path};
    }

    void expectStartedNotFound(Run run) {
      expect(run.output, contains('adb could not be started.'),
          reason: run.output);
      expect(run.output, isNot(contains('adb could not be found.')),
          reason: run.output);
    }

    test('devices says it would not start', () async {
      final run = await _testsmith(['devices'], environment: unlaunchable());

      expectReportedNotCrashed(run, names: 'adb');
      expectStartedNotFound(run);
    });

    test('run says it would not start, still at exit 2', () async {
      final run = await _testsmith([
        'run',
        '${_project.path}/tests/home.yaml',
        '--app',
        _project.path,
      ], environment: unlaunchable());

      expectReportedNotCrashed(run, names: 'adb', code: 2);
      expectStartedNotFound(run);
    });
  });

  /// adb starts, answers, and does not list the handset that was named.
  ///
  /// The group above covers an adb that cannot be run at all, which
  /// `resolveAdb` refuses before anything reaches a device. This is the
  /// ordinary case underneath it - a stale or mistyped `--device` - and
  /// the two commands that take one answered it differently. Measured
  /// against f78092c with the fake adb below:
  ///
  ///   run     -d NOSUCHDEVICE  exit 1, `No usable device with serial ...`
  ///   inspect -d NOSUCHDEVICE  exit 255, Unhandled exception,
  ///                            DeviceCommandException, and the stack
  ///                            trace carrying an absolute source path
  ///
  /// `run` verifies the serial it was handed; `inspect` did not, so the
  /// launch issued the first adb command against a device nobody had
  /// checked. `verifyDevice` exists for exactly this and says so in its
  /// own comment.
  group('adb answers and the named device is not attached', () {
    const named = 'NOSUCHDEVICE';

    List<String> inspecting(String serial) => [
          'inspect',
          '--app',
          _project.path,
          '--app-id',
          'com.example.x',
          '--device',
          serial,
        ];

    test('inspect refuses rather than crashing inside the launch', () async {
      final run = await _testsmith(
        inspecting(named),
        environment: _adbReporting(const [_attached]),
      );

      expectReportedNotCrashed(run, names: named.toLowerCase());
      // The specific escape: the launch's first adb command raised this
      // and nothing on the way out was catching it.
      expect(run.output, isNot(contains('DeviceCommandException')),
          reason: run.output);
    });

    test('smoke refuses it too, before waking anything', () async {
      // SMOKE-ADB. Measured at 846365e: `smoke --device NOSUCHDEVICE`
      // printed "waking device NOSUCHDEVICE", sent `-s NOSUCHDEVICE shell
      // input keyevent KEYCODE_WAKEUP` to a serial nobody had checked,
      // and reported "Smoke run failed: DeviceCommandException: ..." -
      // the case `inspect` was fixed for in 47e1162.
      final run = await _testsmith(
        [
          'smoke',
          '--app',
          _project.path,
          '--app-id',
          'com.example.x',
          '--device',
          named,
        ],
        environment: _adbReporting(const [_attached]),
      );

      expectReportedNotCrashed(run, names: named.toLowerCase());
      expect(run.output, contains('No usable device with serial "$named".'),
          reason: run.output);
      // What `verifyDevice` offers instead: what is attached.
      expect(run.output, contains(_attached), reason: run.output);
      expect(run.output, isNot(contains('DeviceCommandException')),
          reason: run.output);
      // The runner never started: it is what prints this.
      expect(run.output, isNot(contains('waking device')), reason: run.output);
    });

    test('and says what run says, because both ask the same function',
        () async {
      final environment = _adbReporting(const [_attached]);
      final inspect = await _testsmith(inspecting(named),
          environment: environment);
      final run = await _testsmith([
        'run',
        '${_project.path}/tests/home.yaml',
        '--app',
        _project.path,
        '-d',
        named,
      ], environment: environment);

      const sentence = 'No usable device with serial "$named".';
      expect(inspect.output, contains(sentence), reason: inspect.output);
      expect(run.output, contains(sentence), reason: run.output);
      // The sentence is shared; the exit code no longer is. This used to
      // assert the two codes were equal. Since RUN-ENV-EXIT `run`, which
      // produces a verdict, answers 2 - the run is wrong - while
      // `inspect`, which produces none, keeps the 1 it uses for every
      // problem.
      expect(inspect.code, 1, reason: inspect.output);
      expect(run.code, 2, reason: run.output);
    });

    group('and what verifying must not change', () {
      // The two below assert only that the device gate let them past.
      // What they meet next is `flutter`, which this harness deliberately
      // keeps off PATH - a separate condition with its own escape, and
      // not what verifying a serial is responsible for.
      test('a named device that is attached is not refused', () async {
        final run = await _testsmith(
          inspecting(_attached),
          environment: _adbReporting(const [_attached]),
        );

        expect(run.output, isNot(contains('No usable device with serial')),
            reason: run.output);
      });

      test('with no --device and one attached, selection still picks it',
          () async {
        final run = await _testsmith(
          ['inspect', '--app', _project.path, '--app-id', 'com.example.x'],
          environment: _adbReporting(const [_attached]),
        );

        expect(run.output, isNot(contains('No usable device')),
            reason: run.output);
      });

      test('with no --device and nothing attached, the selection gate is '
          'unchanged', () async {
        final run = await _testsmith(
          ['inspect', '--app', _project.path, '--app-id', 'com.example.x'],
          environment: _adbReporting(const []),
        );

        expect(run.output, contains('No usable device attached'),
            reason: run.output);
        expect(run.code, 1, reason: run.output);
      });

      test('several attached and none named is still refused by selection',
          () async {
        // The platform never guesses between candidates.
        final run = await _testsmith(
          ['inspect', '--app', _project.path, '--app-id', 'com.example.x'],
          environment: _adbReporting(const [_attached, 'FAKE_SERIAL_2']),
        );

        expect(run.output, contains('Several devices attached'),
            reason: run.output);
        expect(run.code, 1, reason: run.output);
      });
    });
  });

  /// `flutter` is not installed, adb answers, and the device is there.
  ///
  /// The third external tool, and the last command that did not check for
  /// it. `preflight`, `suite run` and `auth setup` all pass
  /// `resolveFlutter().isFound` into `checkApplicationBuild`, and
  /// `doctor` has its own Flutter row. `inspect` verified the device from
  /// 47e1162 and then launched regardless of whether there was anything
  /// to launch with. Measured against 47e1162, one condition through
  /// every command that starts an application:
  ///
  ///   preflight   exit 2  [BLOCK] application build  flutter is not on PATH
  ///   suite run   exit 2  the same row, through the suite result
  ///   auth setup  exit 2  the same row, through the auth preflight
  ///   run         exit 2  Could not start the app: ProcessException ...
  ///   smoke       exit 1  Smoke run failed: ProcessException ...
  ///   doctor      exit 1  [fail] Flutter  flutter was not found on PATH.
  ///   inspect     exit 255, Unhandled exception, ProcessException, five
  ///               stack frames and an absolute source path
  ///
  /// `app_session.dart` asks for `executableOrBareName`, whose bare-name
  /// fallback is deliberate and stays; what was missing was anyone asking
  /// whether it had been found.
  group('flutter is not installed', () {
    test('inspect reports it rather than crashing', () async {
      final run = await _testsmith(
        [
          'inspect',
          '--app',
          _project.path,
          '--app-id',
          'com.example.x',
          '--device',
          _attached,
        ],
        environment: _adbReporting(const [_attached], withDart: false),
      );

      // The concept, not the executable: it is `flutter.exe` on Windows
      // and `flutter` elsewhere.
      expectReportedNotCrashed(run, names: 'flutter');
      expect(run.output, contains('PATH'), reason: run.output);
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('smoke reports it before waking the device', () async {
      // SMOKE-FLUTTER. Measured at 5edec30: `smoke` verified the device
      // and then went straight to the runner, which woke the handset,
      // tried to start Flutter, and ended with "Smoke run failed:
      // ProcessException: The system cannot find the file specified (at
      // ../../runtime/bin/process_win.cc:577)" - the case 957fcfa closed
      // for `inspect`, and left here because it did not crash.
      final run = await _testsmith(
        [
          'smoke',
          '--app',
          _project.path,
          '--app-id',
          'com.example.x',
          '--device',
          _attached,
        ],
        environment: _adbReporting(const [_attached], withDart: false),
      );

      expectReportedNotCrashed(run, names: 'flutter');
      expect(run.output, contains('flutter was not found on PATH.'),
          reason: run.output);
      expect(run.output, contains('https://flutter.dev'), reason: run.output);
      // The runner prints both of these; it must never have started.
      expect(run.output, isNot(contains('waking device')), reason: run.output);
      expect(run.output, isNot(contains('launching app')), reason: run.output);
      // Nor anything of the launch failure it used to show.
      expect(run.output, isNot(contains('ProcessException')),
          reason: run.output);
      expect(run.output, isNot(contains('runtime/bin')), reason: run.output);
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('run reports it before waking the device, at exit 2', () async {
      // RUN-FLUTTER. Measured at 1859092: `run` verified the device and
      // went on to launch, which woke the handset and ended with "Could
      // not start the app: ProcessException: The system cannot find the
      // file specified" - the last command still answering a missing
      // Flutter with the launch's own failure. The code stays 2: for
      // `run` every refusal before launch is the run being wrong.
      //
      // Launched here rather than through `_testsmith`, so that nothing
      // written to stderr can hide inside the combined output.
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          '${Directory.current.path}/bin/testsmith.dart',
          'run',
          '${_project.path}/tests/home.yaml',
          '--app',
          _project.path,
          '--device',
          _attached,
        ],
        environment: _adbReporting(const [_attached], withDart: false),
      );
      final stdout = '${result.stdout}';
      final stderr = '${result.stderr}';
      final run = (output: '$stdout$stderr', code: result.exitCode);

      // Not `expectReportedNotCrashed`: its guard against a leaked
      // command line looks for the application path, and `run` has
      // always opened with the flow it runs, whose path holds it.
      expect(run.code, 2, reason: run.output);
      for (final crash in const [
        'Unhandled exception',
        'ProcessException',
        '#0 ',
        'asynchronous suspension',
      ]) {
        expect(run.output, isNot(contains(crash)), reason: run.output);
      }
      expect(run.output, isNot(contains('Command: ')), reason: run.output);
      expect(stdout, contains('flutter was not found on PATH.'),
          reason: run.output);
      expect(stdout, contains('https://flutter.dev'), reason: run.output);
      expect(stderr, isEmpty, reason: run.output);
      // The app session prints each of these as it goes; none of it may
      // have started.
      expect(run.output, isNot(contains('waking device')), reason: run.output);
      expect(run.output, isNot(contains('adb reverse')), reason: run.output);
      expect(run.output, isNot(contains('launching app')), reason: run.output);
      expect(run.output, isNot(contains('Could not start the app')),
          reason: run.output);
      expect(run.output, isNot(contains('runtime/bin')), reason: run.output);
      expect(run.output, isNot(contains('file:///')), reason: run.output);
    });

    test('and the wording is the one the resolver already publishes',
        () async {
      // Reused rather than restated: `doctor` renders the same two
      // strings, so a person who ran `doctor` first reads the same
      // sentence twice instead of two descriptions of one machine.
      // `smoke` joined `inspect` here in SMOKE-FLUTTER.
      for (final command in const ['inspect', 'smoke']) {
        final run = await _testsmith(
          [
            command,
            '--app',
            _project.path,
            '--app-id',
            'com.example.x',
            '--device',
            _attached,
          ],
          environment: _adbReporting(const [_attached], withDart: false),
        );

        expect(run.output, contains('flutter was not found on PATH.'),
            reason: '$command:\n${run.output}');
        expect(run.output, contains('https://flutter.dev'),
            reason: '$command:\n${run.output}');
      }
    });

    group('and what checking it must not change', () {
      test('an unreachable device is still refused first', () async {
        // Order matters: the device gate answers a question about this
        // machine's handset, and reporting a missing Flutter to somebody
        // who mistyped a serial would name the wrong problem.
        final run = await _testsmith(
          [
            'inspect',
            '--app',
            _project.path,
            '--app-id',
            'com.example.x',
            '--device',
            'NOSUCHDEVICE',
          ],
          environment: _adbReporting(const [_attached], withDart: false),
        );

        expect(run.output, contains('No usable device with serial'),
            reason: run.output);
        expect(run.output, isNot(contains('flutter was not found')),
            reason: run.output);
        expect(run.code, 1, reason: run.output);
      });

      test('the selection gate still speaks when nothing is attached',
          () async {
        final run = await _testsmith(
          ['inspect', '--app', _project.path, '--app-id', 'com.example.x'],
          environment: _adbReporting(const [], withDart: false),
        );

        expect(run.output, contains('No usable device attached'),
            reason: run.output);
        expect(run.output, isNot(contains('flutter was not found')),
            reason: run.output);
      });

      test('run and smoke answer as they always have', () async {
        // The exit codes, which neither 957fcfa, SMOKE-FLUTTER nor
        // RUN-FLUTTER moved: `run` 2, `smoke` 1. The route to them
        // differs now: both refuse before launching, with the resolver's
        // sentence (above), where both used to reach the launch and
        // report its ProcessException.
        final environment = _adbReporting(const [_attached], withDart: false);
        final run = await _testsmith([
          'run',
          '${_project.path}/tests/home.yaml',
          '--app',
          _project.path,
          '-d',
          _attached,
        ], environment: environment);
        final smoke = await _testsmith([
          'smoke',
          '--app',
          _project.path,
          '--app-id',
          'com.example.x',
          '-d',
          _attached,
        ], environment: environment);

        expect(run.code, 2, reason: run.output);
        expect(smoke.code, 1, reason: smoke.output);
        expect(run.output, isNot(contains('Unhandled exception')),
            reason: run.output);
        expect(smoke.output, isNot(contains('Unhandled exception')),
            reason: smoke.output);
      });
    });
  });
}
