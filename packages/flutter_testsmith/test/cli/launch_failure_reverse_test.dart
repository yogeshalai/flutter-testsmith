// LAUNCH-REVERSE: a `flutter run` that cannot be started, after the
// device was told to forward a port.
//
// `AppSession.launch` maps the fixture port into the device, then starts
// `flutter run`. The teardown that undoes the mapping is only assembled
// once the process exists, so a start that throws left it in place. That
// is state on the handset, not in this process: it outlives the run, and
// the next one inherits a device forwarding a port to a host that has
// stopped listening - the thing the teardown's own comment says must not
// happen. Measured at 4638c16, offline, for both callers:
//
//   run   --mock-api 0   adb: reverse tcp:N tcp:N     and nothing after
//   smoke --mock-api 0   adb: reverse tcp:N tcp:N     and nothing after
//
// The Flutter pre-checks in `run` and `smoke` (3a3dc01, 1859092) ask
// whether a flutter is *there*. One that is there and will not start -
// here a `flutter.exe` that is not a program, or a `flutter` without its
// executable bit - still reaches the start.
//
// Offline: a fake adb that records every call and lists one device.
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';

late Directory _root;
late Directory _app;
late File _calls;

/// A directory holding an adb that lists [_serial] and records each
/// call in [_calls], and a flutter the resolver finds and the operating
/// system will not run. With [refuseRemove], adb fails `reverse
/// --remove`. Portable per A-3.
String _fakeTools({bool refuseRemove = false}) {
  final directory = Directory('${_root.path}/tools')..createSync();
  if (Platform.isWindows) {
    File('${directory.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo %*>> "${_calls.path}"\r\n'
      'if "%1"=="devices" (\r\n'
      '  echo List of devices attached\r\n'
      '  echo $_serial            device product:f model:Fake device:f\r\n'
      ')\r\n'
      '${refuseRemove ? 'if "%4"=="--remove" (\r\n'
          '  echo error: refused 1>&2\r\n'
          '  exit /b 1\r\n'
          ')\r\n' : ''}'
      'exit /b 0\r\n',
    );
    File('${directory.path}/flutter.exe').writeAsStringSync('not a program');
  } else {
    final adb = File('${directory.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$*" >> "${_calls.path}"\n'
        'if [ "\$1" = "devices" ]; then\n'
        '  echo "List of devices attached"\n'
        '  echo "$_serial            device product:f model:Fake device:f"\n'
        'fi\n'
        '${refuseRemove ? 'if [ "\$4" = "--remove" ]; then '
            'echo "error: refused" >&2; exit 1; fi\n' : ''}'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', adb.path]);
    // No executable bit: found by name, refused by the kernel.
    File('${directory.path}/flutter').writeAsStringSync('#!/bin/sh\nexit 0\n');
  }
  return directory.path;
}

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _testsmith(
  List<String> arguments, {
  bool refuseRemove = false,
}) async {
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {
      // No Dart directory: on a host whose Dart sits inside a Flutter SDK
      // it would put the real flutter on PATH. The CLI is launched by
      // absolute path.
      'PATH': [_fakeTools(refuseRemove: refuseRemove), system].join(Platform.isWindows ? ';' : ':'),
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

/// The mapping was made on the bound port, and undone on it.
void _expectUndone(Run run) {
  final bound = _announced(run.stdout);
  expect(bound, isNotNull, reason: _both(run));
  expect(_reverseCalls(), [
    '-s $_serial reverse tcp:$bound tcp:$bound',
    '-s $_serial reverse --remove tcp:$bound',
  ], reason: _both(run));
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('launch_reverse');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    File('${_app.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    Directory('${_app.path}/tests').createSync();
    File('${_app.path}/tests/home.yaml').writeAsStringSync(
      'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
    );
    Directory('${_app.path}/mock_api/scenarios').createSync(recursive: true);
    File('${_app.path}/mock_api/scenarios/default.json')
        .writeAsStringSync('{"name":"default","routes":{}}');
    _calls = File('${_root.path}/adb_calls.log');
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  test('run undoes the port mapping when flutter will not start', () async {
    final run = await _testsmith([
      'run',
      '--app',
      _app.path,
      '--device',
      _serial,
      '--mock-api',
      '0',
      '${_app.path}/tests/home.yaml',
    ]);

    // Its answer is unchanged: the launch that never happened, at 2.
    expect(run.code, 2, reason: _both(run));
    expect(run.stdout, contains('Could not start the app'),
        reason: _both(run));
    _expectUndone(run);
  });

  test('smoke undoes it too', () async {
    final run = await _testsmith([
      'smoke',
      '--app',
      _app.path,
      '--app-id',
      'com.example.x',
      '--device',
      _serial,
      '--mock-api',
      '0',
    ]);

    expect(run.code, 1, reason: _both(run));
    expect(run.stdout, contains('Smoke run failed'), reason: _both(run));
    _expectUndone(run);
  });

  test('with no fixture port there is nothing to undo', () async {
    final run = await _testsmith([
      'run',
      '--app',
      _app.path,
      '--device',
      _serial,
      '${_app.path}/tests/home.yaml',
    ]);

    expect(run.code, 2, reason: _both(run));
    expect(run.stdout, contains('Could not start the app'),
        reason: _both(run));
    expect(_reverseCalls(), isEmpty, reason: _both(run));
  });

  test('and a mapping that will not come off does not hide why', () async {
    // The start's failure is the news. An adb that also refuses to undo
    // the mapping is said, and does not replace it.
    final run = await _testsmith([
      'run',
      '--app',
      _app.path,
      '--device',
      _serial,
      '--mock-api',
      '0',
      '${_app.path}/tests/home.yaml',
    ], refuseRemove: true);

    expect(run.code, 2, reason: _both(run));
    // The start's own failure - FlutterStartException since FLUTTER-START
    // - not the removal's.
    expect(run.stdout, contains('Could not start the app: '),
        reason: _both(run));
    expect(run.stdout, contains('could not be started'), reason: _both(run));
    expect(run.stdout, contains('could not remove the adb reverse'),
        reason: _both(run));
    expect(_reverseCalls(), hasLength(2), reason: _both(run));
  });
}
