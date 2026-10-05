// FLUTTER-START: what a launch that cannot start `flutter run` records.
//
// A flutter that is on PATH and will not run - a damaged install, a file
// without its executable bit - passes every "is it there" check and
// fails when `AppSession.launch` starts it. That raised the operating
// system's ProcessException, whose text is the executable's absolute
// path, every argument, and the Dart VM's own source location. `suite
// run` records a test's error as text, so measured at 588f6c3, offline,
// suite.json and suite.html carried:
//
//   ProcessException: This version of %1 is not compatible ...
//     (at ../../runtime/bin/process_win.cc:577)
//     Command: C:\Users\<somebody>\...\flutter.exe run --machine -d ...
//       --dart-define=TEST_MODE=true --dart-define=API_BASE=...
//
// `DeviceUnavailableException` states the rule this broke: an absolute
// path in this text puts "a fact about a workstation into a committed
// artefact", and adb's own start failure has never done it. Flutter's
// now follows it - the file name and the system's reason, nothing else.
//
// Offline. A fake adb answers as the profile's device; the flutter on
// PATH is one the operating system refuses.
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';

late Directory _root;
late Directory _app;
late Directory _tools;

String get _flutterName => Platform.isWindows ? 'flutter.exe' : 'flutter';

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// An adb that is the profile's device, and a flutter the resolver finds
/// and the operating system will not run. Portable per A-3.
void _fakeTools() {
  _tools = Directory('${_root.path}/tools')..createSync();
  if (Platform.isWindows) {
    File('${_tools.path}/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'if "%1"=="devices" (\r\n'
      '  echo List of devices attached\r\n'
      '  echo $_serial            device product:f model:FakePhone device:f\r\n'
      ')\r\n'
      'if "%5"=="ro.product.model" echo FakePhone\r\n'
      'if "%5"=="ro.build.version.release" echo 13\r\n'
      'if "%4 %5"=="wm size" echo Physical size: 720x1600\r\n'
      'if "%4 %5"=="wm density" echo Physical density: 300\r\n'
      'exit /b 0\r\n',
    );
    File('${_tools.path}/flutter.exe').writeAsStringSync('not a program');
  } else {
    final adb = File('${_tools.path}/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'if [ "\$1" = "devices" ]; then\n'
        '  echo "List of devices attached"\n'
        '  echo "$_serial            device product:f model:FakePhone '
        'device:f"\n'
        'fi\n'
        'case "\$4 \$5" in\n'
        '  "getprop ro.product.model") echo FakePhone ;;\n'
        '  "getprop ro.build.version.release") echo 13 ;;\n'
        '  "wm size") echo "Physical size: 720x1600" ;;\n'
        '  "wm density") echo "Physical density: 300" ;;\n'
        'esac\n'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', adb.path]);
    // No executable bit: found by name, refused by the kernel.
    File('${_tools.path}/flutter').writeAsStringSync('#!/bin/sh\nexit 0\n');
  }
}

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {
      // No Dart directory: on a host whose Dart sits inside a Flutter SDK
      // it would put the real flutter on PATH.
      'PATH': [_tools.path, system].join(Platform.isWindows ? ';' : ':'),
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
  ).timeout(const Duration(seconds: 150));
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

String _both(Run run) => 'stdout:\n${run.stdout}\nstderr:\n${run.stderr}';

/// Nothing about this machine or this invocation: no directory the tools
/// live in, no VM source location, no command line.
void _expectNothingOfTheMachine(String text, String reason) {
  // Compared with one separator: the resolver's path is native, and the
  // test's own is built with `/`.
  expect(
    text.replaceAll(r'\', '/'),
    isNot(contains(_tools.path.replaceAll(r'\', '/'))),
    reason: reason,
  );
  expect(text, isNot(contains('runtime/bin')), reason: reason);
  expect(text, isNot(contains('Command:')), reason: reason);
  expect(text, isNot(contains('--dart-define')), reason: reason);
  expect(text, isNot(contains('staging.example.test')), reason: reason);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('flutter_start');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write('lib/main_mytest.dart', 'void main() {}\n');
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
    );
    _write(
      'suites/s.yaml',
      'suite: s\n'
      'app: {path: .., target: lib/main_mytest.dart, '
      'dartDefines: [API_BASE=https://staging.example.test]}\n'
      'device: {profile: p}\n'
      'tests:\n  - {id: home, flow: tests/home.yaml}\n',
    );
    _write(
      'device_profiles/p.yaml',
      'id: p\nmodel: FakePhone\nos: Android 13\n'
      'physical:\n  width: 720\n  height: 1600\n'
      'devicePixelRatio: 1.875\norientation: portrait\nbuildMode: debug\n',
    );
    _fakeTools();
  });

  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  test('suite.json records the tool and the reason, not the machine',
      () async {
    final run = await _testsmith([
      'suite',
      'run',
      '${_app.path}/suites/s.yaml',
      '--device',
      _serial,
    ]);

    // Unchanged: the launch never happened, so the test is an ERROR and
    // the suite answers 2.
    expect(run.code, 2, reason: _both(run));
    final file = File('${_app.path}/out/suite/suite.json');
    expect(file.existsSync(), isTrue, reason: _both(run));
    final text = file.readAsStringSync();
    final json = jsonDecode(text) as Map<String, Object?>;
    final tests = (json['tests']! as List).cast<Map<String, Object?>>();
    final reason = '${tests.single['reason']}';

    // The decoded reason, where a path is not JSON-escaped, and the file.
    _expectNothingOfTheMachine(reason, reason);
    _expectNothingOfTheMachine(text, text);
    // Still says what failed: the tool, by file name, and why.
    expect(reason, contains('$_flutterName could not be started'),
        reason: reason);
    _expectNothingOfTheMachine(
      File('${_app.path}/out/suite/suite.html').readAsStringSync(),
      'suite.html',
    );
    _expectNothingOfTheMachine(run.stdout, _both(run));
  });

  test('run says it the same way', () async {
    final run = await _testsmith([
      'run',
      '--app',
      _app.path,
      '--device',
      _serial,
      '--dart-define',
      'API_BASE=https://staging.example.test',
      '${_app.path}/tests/home.yaml',
    ]);

    // Unchanged: `run`'s sentence and code for a launch that never
    // happened.
    expect(run.code, 2, reason: _both(run));
    _expectNothingOfTheMachine(run.stdout, _both(run));
    expect(run.stdout,
        contains('Could not start the app: $_flutterName could not be started'),
        reason: _both(run));
    expect(run.stderr, isEmpty, reason: _both(run));
  });
}
