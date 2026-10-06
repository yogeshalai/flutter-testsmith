// SMOKE-MOCK-PORT: what `smoke --mock-api` maps into the device.
//
// `--mock-api 0` asks the host for any free port (kept on purpose in
// 4e63448). `run` maps the port the fixture server actually bound -
// `FlowRunner` hands `mockApi?.port` to the session. `smoke` handed the
// session the port it was asked for, so measured at 4e63448:
//
//   › mock API on http://127.0.0.1:51376
//   › adb reverse tcp:0 -> host          adb -s ... reverse tcp:0 tcp:0
//
// The device was pointed at a port nothing serves, and teardown removed
// that same `tcp:0`, never the mapping a real port would have needed.
//
// Offline. A fake adb records every call; a fake flutter lets the launch
// begin. Where nothing answers as an application the run is stopped once
// the mapping is made. To see teardown, the fake flutter announces a VM
// service nobody serves, and the session's own shutdown runs to the end.
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';

late Directory _root;
late Directory _app;
late File _calls;

/// What `flutter run --machine` prints for an app that started, with a
/// VM service on a port nothing listens on.
const List<String> _announcement = [
  '[{"event":"app.start","params":{"appId":"x","deviceId":"$_serial"}}]',
  '[{"event":"app.debugPort","params":{"wsUri":"ws://127.0.0.1:1/ws"}}]',
  '[{"event":"app.started","params":{}}]',
];

/// A directory holding an adb that lists [_serial] and records each
/// call in [_calls], and a flutter that exits at once - after printing
/// [_announcement] when [announce]. Portable per A-3.
String _fakeTools({bool announce = false}) {
  final directory = Directory('${_root.path}/tools')..createSync();
  if (Platform.isWindows) {
    File('${directory.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo %*>> "${_calls.path}"\r\n'
      'if "%1"=="devices" (\r\n'
      '  echo List of devices attached\r\n'
      '  echo $_serial            device product:f model:Fake device:f\r\n'
      ')\r\n'
      'exit /b 0\r\n',
    );
    File('${directory.path}/flutter.bat').writeAsStringSync(
      '@echo off\r\n'
      '${announce ? [for (final line in _announcement) 'echo $line\r\n'].join() : ''}'
      'exit /b 0\r\n',
    );
  } else {
    final adb = File('${directory.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$*" >> "${_calls.path}"\n'
        'if [ "\$1" = "devices" ]; then\n'
        '  echo "List of devices attached"\n'
        '  echo "$_serial            device product:f model:Fake device:f"\n'
        'fi\n'
        'exit 0\n',
      );
    final flutter = File('${directory.path}/flutter')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        '${announce ? [for (final line in _announcement) "echo '$line'\n"].join() : ''}'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', adb.path, flutter.path]);
  }
  return directory.path;
}

/// `smoke --mock-api [port]`, stopped once the session has logged its
/// `adb reverse` - or, when [announce], left to finish on its own.
/// Returns everything it printed, and the exit code if it finished.
Future<({String output, int? code})> _smoke(
  String port, {
  bool announce = false,
}) async {
  final tools = _fakeTools(announce: announce);
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'smoke',
      '--app',
      _app.path,
      '--app-id',
      'com.example.x',
      '--device',
      _serial,
      '--mock-api',
      port,
    ],
    environment: {
      // No Dart directory: on a host whose Dart sits inside a Flutter
      // SDK it would put the real flutter on PATH ahead of nothing, and
      // the CLI is launched by absolute path anyway.
      'PATH': [tools, system].join(Platform.isWindows ? ';' : ':'),
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
  );

  final seen = StringBuffer();
  final reversed = Completer<void>();
  StreamSubscription<String> watch(Stream<List<int>> stream) => stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        seen.writeln(line);
        if (!announce &&
            line.contains('adb reverse') &&
            !reversed.isCompleted) {
          reversed.complete();
        }
      });
  final out = watch(process.stdout);
  final err = watch(process.stderr);

  int? code;
  await Future.any([
    reversed.future,
    process.exitCode.then((value) => code = value),
  ]).timeout(const Duration(seconds: 90), onTimeout: () => null);
  process.kill(ProcessSignal.sigkill);
  await process.exitCode;
  await out.cancel();
  await err.cancel();
  return (output: '$seen', code: code);
}

/// The port the fixture server announced it bound.
int? _announced(String output) {
  final match =
      RegExp(r'mock API on http://127\.0\.0\.1:(\d+)').firstMatch(output);
  return match == null ? null : int.parse(match.group(1)!);
}

List<String> _reverseCalls() => _calls.existsSync()
    ? [
        for (final line in _calls.readAsLinesSync())
          if (line.contains('reverse')) line.trim(),
      ]
    : const [];

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('smoke_mock_port');
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

  test('--mock-api 0 maps the port the server bound, not 0', () async {
    final (:output, code: _) = await _smoke('0');

    final bound = _announced(output);
    expect(bound, isNotNull, reason: output);
    expect(bound, isNot(0), reason: output);
    expect(output, contains('› adb reverse tcp:$bound -> host'),
        reason: output);
    expect(output, isNot(contains('tcp:0')), reason: output);
    // What the device was actually told: its port to the same host port,
    // the mapping `run` makes.
    expect(_reverseCalls(), ['-s $_serial reverse tcp:$bound tcp:$bound'],
        reason: output);
  });

  test('an explicit port is still mapped as given', () async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close();

    final (:output, code: _) = await _smoke('$port');

    expect(_announced(output), port, reason: output);
    expect(output, contains('› adb reverse tcp:$port -> host'),
        reason: output);
    expect(_reverseCalls(), ['-s $_serial reverse tcp:$port tcp:$port'],
        reason: output);
  });

  test('teardown removes the mapping it made, on the port bound', () async {
    // The session's own shutdown, reached without a device: the fake
    // flutter reports a started app whose VM service refuses the
    // connection, and the session undoes what it set up before it
    // rethrows. Removing `tcp:0` would leave the real mapping behind.
    final (:output, :code) = await _smoke('0', announce: true);

    expect(code, 1, reason: output);
    expect(output, contains('Smoke run failed'), reason: output);
    final bound = _announced(output);
    expect(bound, isNotNull, reason: output);
    expect(_reverseCalls(), [
      '-s $_serial reverse tcp:$bound tcp:$bound',
      '-s $_serial reverse --remove tcp:$bound',
    ], reason: output);
  });
}
