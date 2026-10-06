// SMOKE-SERVER-CLEANUP: the fixture server, when the smoke launch fails.
//
// `SmokeRunner` starts the fixture server, so it owns it. Its `finally`
// closed the server only around the work done after `AppSession.launch`
// returned; a launch that threw left the server listening. Measured at
// c5e27bb, offline, through `test/cli/support/smoke_launch_failure_probe`,
// which asks the bound port once `run()` has thrown:
//
//   adb refuses the wake                  ERROR  SERVING=yes
//   flutter is there and will not start   ERROR  SERVING=yes
//   the device has no such package        ERROR  SERVING=yes
//   the VM service refuses the connection ERROR  SERVING=yes
//
// The CLI then exits, which is why nothing noticed. A runner that leaves
// what it started running is wrong whoever calls it, and this asks the
// port directly rather than relying on the process ending.
//
// The session's own resources are not the runner's: `AppSession.launch`
// tears down what it set up before it throws (c5e27bb for the reverse),
// so the runner closes the server and nothing else.
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';

late Directory _root;
late Directory _app;
late File _calls;

enum _Failure { wake, start, package, connect }

/// What `flutter run --machine` prints for an app that started, with a
/// VM service on a port nothing listens on.
const List<String> _announcement = [
  '[{"event":"app.start","params":{"appId":"x","deviceId":"$_serial"}}]',
  '[{"event":"app.debugPort","params":{"wsUri":"ws://127.0.0.1:1/ws"}}]',
  '[{"event":"app.started","params":{}}]',
];

/// A fake adb that records each call, and a flutter, arranged so the
/// launch fails at [failure]. Portable per A-3.
String _fakeTools(_Failure failure) {
  final directory = Directory('${_root.path}/tools')..createSync();
  final refuseWake = failure == _Failure.wake;
  // Lists the package only where the launch is meant to get past the
  // installed check, to the connection.
  final listPackage = failure == _Failure.connect;
  if (Platform.isWindows) {
    File('${directory.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo %*>> "${_calls.path}"\r\n'
      '${refuseWake ? 'if "%4"=="input" (\r\n'
          '  echo error: device offline 1>&2\r\n'
          '  exit /b 1\r\n'
          ')\r\n' : ''}'
      // `shell` takes the device command as one argument.
      '${listPackage ? 'if "%~4"=="pm list packages com.example.x" (\r\n'
          '  echo package:com.example.x\r\n'
          '  exit /b 0\r\n'
          ')\r\n' : ''}'
      'exit /b 0\r\n',
    );
    if (failure == _Failure.start) {
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
        'echo "\$*" >> "${_calls.path}"\n'
        '${refuseWake ? 'if [ "\$4" = "input" ]; then '
            'echo "error: device offline" >&2; exit 1; fi\n' : ''}'
        '${listPackage ? 'if [ "\$4" = "pm list packages com.example.x" ]; then '
            'echo "package:com.example.x"; exit 0; fi\n' : ''}'
        'exit 0\n',
      );
    final flutter = File('${directory.path}/flutter');
    if (failure == _Failure.start) {
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

typedef Probe = ({
  List<String> log,
  String error,
  String port,
  String serving,
  String raw,
});

Future<Probe> _probe(_Failure failure) async {
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      'test/cli/support/smoke_launch_failure_probe.dart',
      _app.path,
      _serial,
    ],
    environment: {
      // No Dart directory: on a host whose Dart sits inside a Flutter SDK
      // it would put the real flutter on PATH.
      'PATH': [_fakeTools(failure), system].join(Platform.isWindows ? ';' : ':'),
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
  ).timeout(const Duration(seconds: 120));
  final raw = 'exit ${result.exitCode}\nstdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}';
  String field(String name) {
    for (final line in '${result.stdout}'.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('$name=')) return line.substring(name.length + 1);
    }
    return '(missing)';
  }

  return (
    log: [
      for (final line in '${result.stdout}'.split(RegExp(r'\r?\n')))
        if (line.startsWith('LOG=')) line.substring(4),
    ],
    error: field('ERROR'),
    port: field('PORT'),
    serving: field('SERVING'),
    raw: raw,
  );
}

List<String> _reverseCalls() => _calls.existsSync()
    ? [
        for (final line in _calls.readAsLinesSync())
          if (line.contains('reverse')) line.trim(),
      ]
    : const [];

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('smoke_server_cleanup');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    File('${_app.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    Directory('${_app.path}/mock_api/scenarios').createSync(recursive: true);
    File('${_app.path}/mock_api/scenarios/default.json')
        .writeAsStringSync('{"name":"default","routes":{}}');
    _calls = File('${_root.path}/adb_calls.log');
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('a failed smoke launch closes the fixture server', () {
    test('when adb will not wake the device', () async {
      final probe = await _probe(_Failure.wake);

      // The launch's own error, not one raised by cleaning up after it.
      expect(probe.error, 'DeviceCommandException', reason: probe.raw);
      expect(probe.port, isNot('none'), reason: probe.raw);
      expect(probe.serving, 'no', reason: probe.raw);
      // Failed before anything was mapped, so nothing to unmap.
      expect(_reverseCalls(), isEmpty, reason: probe.raw);
    });

    test('when flutter is there and will not start', () async {
      final probe = await _probe(_Failure.start);

      expect(probe.error, 'FlutterStartException', reason: probe.raw);
      expect(probe.serving, 'no', reason: probe.raw);
      // c5e27bb, on the port 4638c16 maps: the session undid its own
      // mapping before it threw.
      expect(_reverseCalls(), [
        '-s $_serial reverse tcp:${probe.port} tcp:${probe.port}',
        '-s $_serial reverse --remove tcp:${probe.port}',
      ], reason: probe.raw);
    });

    test('when the device has no such package', () async {
      final probe = await _probe(_Failure.package);

      expect(probe.error, 'StateError', reason: probe.raw);
      expect(probe.log.join('\n'), contains('not confirmed on the device'),
          reason: probe.raw);
      expect(probe.serving, 'no', reason: probe.raw);
      expect(_reverseCalls(), [
        '-s $_serial reverse tcp:${probe.port} tcp:${probe.port}',
        '-s $_serial reverse --remove tcp:${probe.port}',
      ], reason: probe.raw);
    });

    test('when the started app will not let the session connect', () async {
      final probe = await _probe(_Failure.connect);

      // Past the package check, to the handshake.
      expect(probe.log.join('\n'), isNot(contains('not confirmed')),
          reason: probe.raw);
      expect(probe.error, isNot('none'), reason: probe.raw);
      expect(probe.serving, 'no', reason: probe.raw);
      expect(_reverseCalls(), [
        '-s $_serial reverse tcp:${probe.port} tcp:${probe.port}',
        '-s $_serial reverse --remove tcp:${probe.port}',
      ], reason: probe.raw);
    });
  });
}
