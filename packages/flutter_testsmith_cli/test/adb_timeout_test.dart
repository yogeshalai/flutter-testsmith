// ADB-TIMEOUT: an adb that never answers.
//
// Every adb call went through `SystemProcessRunner.run`, which is
// `Process.run` with no bound, so an adb that hangs hung the command
// with it. That is not hypothetical: a wedged adb server is the classic
// way `adb devices` stops answering, and a handset in a bad USB state
// does the same to `adb -s <serial> shell`. Measured at 25fdc3b,
// offline, with an adb that never exits:
//
//   testsmith devices                    never returns
//   testsmith smoke  (adb lists the      never returns, at "waking device"
//   device, then hangs on `shell`)
//
// Now each call is bounded by what it does (see
// `AdbDeviceController`), a timeout is said as one, and the adb that
// did not answer is stopped rather than left behind.
//
// Offline. The fake adb's hanging half is a Dart child that records its
// pid, so the test can see it go - on Windows behind `adb.bat`, which is
// the shape a wrapper on PATH has.
@Timeout(Duration(minutes: 8))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';

late Directory _root;
late File _pids;

String get _tools => '${_root.path}/tools';

/// An adb that hangs. With [listDevices] it first answers `devices`
/// like one handset is attached, and hangs on everything else.
void _hangingAdb({required bool listDevices}) {
  final sleeper = File('${_root.path}/sleeper.dart')
    ..writeAsStringSync(
      "import 'dart:io';\n"
      'Future<void> main(List<String> args) async {\n'
      "  File(args.single).writeAsStringSync('\$pid\\n', "
      'mode: FileMode.append);\n'
      '  await Future<void>.delayed(const Duration(minutes: 2));\n'
      '}\n',
    );
  final dart = Platform.resolvedExecutable;
  if (Platform.isWindows) {
    File('$_tools/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      '${listDevices ? 'if "%1"=="devices" (\r\n'
          '  echo List of devices attached\r\n'
          '  echo $_serial            device product:f model:Fake device:f\r\n'
          '  exit /b 0\r\n'
          ')\r\n' : ''}'
      '"$dart" "${sleeper.path}" "${_pids.path}"\r\n',
    );
  } else {
    final adb = File('$_tools/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        '${listDevices ? 'if [ "\$1" = "devices" ]; then\n'
            '  echo "List of devices attached"\n'
            '  echo "$_serial            device product:f model:Fake device:f"\n'
            '  exit 0\n'
            'fi\n' : ''}'
        'exec "$dart" "${sleeper.path}" "${_pids.path}"\n',
      );
    Process.runSync('chmod', ['+x', adb.path]);
  }
}

/// A flutter the resolver finds. Never reached: adb hangs first.
void _flutter() {
  if (Platform.isWindows) {
    File('$_tools/flutter.bat').writeAsStringSync('@echo off\r\nexit /b 1\r\n');
  } else {
    final file = File('$_tools/flutter')
      ..writeAsStringSync('#!/bin/sh\nexit 1\n');
    Process.runSync('chmod', ['+x', file.path]);
  }
}

typedef Run = ({String stdout, int code, Duration took});

/// The CLI, bounded here so a red result cannot hang the suite.
Future<Run> _testsmith(List<String> arguments) async {
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final clock = Stopwatch()..start();
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {
      'PATH': [_tools, system].join(Platform.isWindows ? ';' : ':'),
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
    workingDirectory: _root.path,
  );
  final out = process.stdout.transform(utf8.decoder).join();
  unawaited(process.stderr.drain<void>());
  final code = await process.exitCode.timeout(
    const Duration(seconds: 90),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  return (stdout: await out, code: code, took: clock.elapsed);
}

List<int> _recordedPids() => _pids.existsSync()
    ? [
        for (final line in _pids.readAsLinesSync()) ?int.tryParse(line.trim()),
      ]
    : const [];

bool _alive(int pid) {
  if (Platform.isWindows) {
    final result = Process.runSync(
      'tasklist',
      ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
    );
    return '${result.stdout}'.contains('"$pid"');
  }
  return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
}

Future<bool> _goneSoon(int pid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (!_alive(pid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return !_alive(pid);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('adb_timeout');
    Directory(_tools).createSync();
    Directory('${_root.path}/app').createSync();
    File('${_root.path}/app/pubspec.yaml').writeAsStringSync('name: app\n');
    _pids = File('${_root.path}/adb.pids');
    _flutter();
  });

  tearDown(() async {
    // Whatever was concluded, nothing the fake started stays running.
    for (final pid in _recordedPids()) {
      if (!_alive(pid)) continue;
      if (Platform.isWindows) {
        Process.runSync('taskkill', ['/F', '/T', '/PID', '$pid']);
      } else {
        Process.runSync('kill', ['-9', '$pid']);
      }
      await _goneSoon(pid);
    }
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  test('devices: an adb that never answers is a timeout, and is stopped',
      () async {
    _hangingAdb(listDevices: false);

    final run = await _testsmith(['devices']);

    expect(run.code, 1, reason: run.stdout);
    expect(run.stdout, contains('did not answer within 30 seconds'),
        reason: run.stdout);
    expect(run.stdout, contains('adb kill-server'), reason: run.stdout);
    expect(_recordedPids(), isNotEmpty, reason: run.stdout);
    for (final pid in _recordedPids()) {
      expect(await _goneSoon(pid), isTrue, reason: 'adb $pid left running');
    }
  });

  test('smoke: a device command that never finishes is a timeout',
      () async {
    _hangingAdb(listDevices: true);

    final run = await _testsmith([
      'smoke',
      '--app',
      '${_root.path}/app',
      '--app-id',
      'com.example.x',
      '--device',
      _serial,
    ]);

    // The code smoke already gives a launch that fails.
    expect(run.code, 1, reason: run.stdout);
    expect(run.stdout, contains('did not finish within 30 seconds'),
        reason: run.stdout);
    expect(run.stdout, contains('KEYCODE_WAKEUP'), reason: run.stdout);
    expect(_recordedPids(), isNotEmpty, reason: run.stdout);
    for (final pid in _recordedPids()) {
      expect(await _goneSoon(pid), isTrue, reason: 'adb $pid left running');
    }
  });
}
