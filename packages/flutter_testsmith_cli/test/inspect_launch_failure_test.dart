// INSPECT-LAUNCH: `inspect` when the launch itself fails.
//
// `run`, `smoke` and `auth setup` each catch a launch that throws and say
// so - "Could not start the app", "Smoke run failed", "Could not launch
// the application" - at an exit code. `inspect` caught one exception,
// DeviceUnavailableException, and let every other launch failure reach
// `bin/testsmith.dart`, which catches UsageException and nothing else.
// Measured at 21ad7bd, offline:
//
//   --app-id not installed      StateError        exit 255, stack trace
//   flutter there, won't run    ProcessException  exit 255, stack trace
//   VM service refuses connect  SocketException   exit 255, stack trace
//
// The first is the ordinary mistake: `--app-id` is required but only
// checked for being non-empty, and the package is confirmed on the device
// after the launch. E-04 / C3 removed exit 255 for a missing tool; this
// is the same outcome for a launch that fails. Now reported at 1, the
// code `inspect` already gives an unreachable device.
//
// Offline. A fake adb and a fake flutter arrange where the launch fails.
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';
const String _appId = 'com.example.x';

late Directory _root;
late Directory _app;

enum _Failure { notInstalled, wontStart, wontConnect }

/// What `flutter run --machine` prints for an app that started, with a
/// VM service on a port nothing listens on.
const List<String> _announcement = [
  '[{"event":"app.start","params":{"appId":"x","deviceId":"$_serial"}}]',
  '[{"event":"app.debugPort","params":{"wsUri":"ws://127.0.0.1:1/ws"}}]',
  '[{"event":"app.started","params":{}}]',
];

/// A fake adb that lists [_serial], and a flutter, arranged so the launch
/// fails at [failure]. Portable per A-3.
String _fakeTools(_Failure failure) {
  final directory = Directory('${_root.path}/tools')..createSync();
  // Listed only where the launch is meant to get past the installed
  // check, to the connection.
  final listPackage = failure == _Failure.wontConnect;
  if (Platform.isWindows) {
    File('${directory.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'if "%1"=="devices" (\r\n'
      '  echo List of devices attached\r\n'
      '  echo $_serial            device product:f model:Fake device:f\r\n'
      ')\r\n'
      // `shell` takes the device command as one argument.
      '${listPackage ? 'if "%~4"=="pm list packages $_appId" (\r\n'
          '  echo package:$_appId\r\n'
          ')\r\n' : ''}'
      'exit /b 0\r\n',
    );
    if (failure == _Failure.wontStart) {
      File('${directory.path}/flutter.exe').writeAsStringSync('not a program');
    } else {
      File('${directory.path}/flutter.bat').writeAsStringSync(
        '@echo off\r\n'
        '${[for (final line in _announcement) 'echo $line\r\n'].join()}'
        'exit /b 0\r\n',
      );
    }
  } else {
    final adb = File('${directory.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'if [ "\$1" = "devices" ]; then\n'
        '  echo "List of devices attached"\n'
        '  echo "$_serial            device product:f model:Fake device:f"\n'
        'fi\n'
        '${listPackage ? 'if [ "\$4" = "pm list packages $_appId" ]; then '
            'echo "package:$_appId"; fi\n' : ''}'
        'exit 0\n',
      );
    final flutter = File('${directory.path}/flutter');
    if (failure == _Failure.wontStart) {
      // No executable bit: found by name, refused by the kernel.
      flutter.writeAsStringSync('#!/bin/sh\nexit 0\n');
      Process.runSync('chmod', ['+x', adb.path]);
    } else {
      flutter.writeAsStringSync(
        '#!/bin/sh\n'
        '${[for (final line in _announcement) "echo '$line'\n"].join()}'
        'exit 0\n',
      );
      Process.runSync('chmod', ['+x', adb.path, flutter.path]);
    }
  }
  return directory.path;
}

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _inspect(_Failure failure) async {
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'inspect',
      '--app',
      _app.path,
      '--app-id',
      _appId,
      '--device',
      _serial,
    ],
    environment: {
      // No Dart directory: on a host whose Dart sits inside a Flutter SDK
      // it would put the real flutter on PATH.
      'PATH': [_fakeTools(failure), system]
          .join(Platform.isWindows ? ';' : ':'),
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
  ).timeout(const Duration(seconds: 120));
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}';

/// Reported, not crashed: exit 1, the launch's own reason on stdout under
/// the sentence `run` uses, and nothing on stderr.
void _expectReported(Run run, String cause) {
  expect(run.code, 1, reason: _both(run));
  expect(run.stdout, contains('Could not start the app: '), reason: _both(run));
  expect(run.stdout, contains(cause), reason: _both(run));
  expect(run.stderr, isEmpty, reason: _both(run));
  for (final stream in [run.stdout, run.stderr]) {
    expect(stream, isNot(contains('Unhandled exception')), reason: _both(run));
    expect(stream, isNot(contains('#0 ')), reason: _both(run));
  }
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('inspect_launch');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    File('${_app.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('inspect reports a launch that fails, rather than crashing', () {
    test('an --app-id the device does not have', () async {
      final run = await _inspect(_Failure.notInstalled);

      _expectReported(run, 'The device has no package "$_appId"');
    });

    test('a flutter that is there and will not start', () async {
      final run = await _inspect(_Failure.wontStart);

      // FlutterStartException since FLUTTER-START: the file, not the path.
      _expectReported(run, 'could not be started');
    });

    test('a started app the session cannot connect to', () async {
      final run = await _inspect(_Failure.wontConnect);

      // Past the package check, to the handshake.
      expect(run.stdout, isNot(contains('not confirmed')), reason: _both(run));
      _expectReported(run, 'SocketException');
    });
  });

  test('a refusal before the launch still says its own sentence', () async {
    // The new guard is around the launch only: a machine with no adb is
    // still told so by the device gate, not by "Could not start the app".
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        '${Directory.current.path}/bin/testsmith.dart',
        'inspect',
        '--app',
        _app.path,
        '--app-id',
        _appId,
        '--device',
        _serial,
      ],
      environment: {
        'PATH': File(Platform.resolvedExecutable).parent.path,
        'MYTEST_ADB': '',
        'ANDROID_HOME': '',
        'ANDROID_SDK_ROOT': '',
      },
    ).timeout(const Duration(seconds: 120));
    final run = (
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
      code: result.exitCode,
    );

    expect(run.code, 1, reason: _both(run));
    expect(run.stdout, contains('adb could not be found.'), reason: _both(run));
    expect(run.stdout, isNot(contains('Could not start the app')),
        reason: _both(run));
  });
}
