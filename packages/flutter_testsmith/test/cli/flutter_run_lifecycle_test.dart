// FLUTTER-RUN-LIFECYCLE: a `flutter run` that ends, or will not end,
// before the application is ready.
//
// `AppSession.launch` started `flutter run --machine` and waited for the
// app to be ready, bounded only by `launchTimeout` - eight minutes - and
// nothing watched the process itself. Measured at 25fdc3b, offline,
// through `test/cli/support/launch_lifecycle_probe`:
//
//   flutter exits 1 at once     launch waits the full timeout, then says
//                               "did not start within N minutes"
//
// A Gradle failure, a flavour that does not exist, an entry point that
// does not compile: each ends `flutter run` in seconds, and was met with
// an eight-minute wait and a sentence about time instead of the exit.
//
// And on Windows, teardown killed only the process it had started. That
// is `cmd.exe` running `flutter.bat`, whose own child - `dart.exe`
// running flutter_tools, the actual `flutter run` - has no `exec` to
// replace it, so it outlived the kill holding the device. Measured with
// a `flutter.bat` that starts a Dart child in the same way:
//
//   timeout, then teardown      the child is still running afterwards
//
// On other systems `bin/flutter` ends in `exec "$DART"`, so the process
// started is flutter_tools itself and the kill already reaches it.
//
// Offline: a fake adb that records every call and lists one device.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

const String _serial = 'FAKE_SERIAL';
const int _reversePort = 5599;

late Directory _root;
late File _calls;
late File _pidFile;

String get _tools => '${_root.path}/tools';

/// An adb that lists [_serial] and records each call. Portable per A-3.
void _fakeAdb() {
  if (Platform.isWindows) {
    File('$_tools/adb.bat').writeAsStringSync(
      '@echo off\r\n'
      'echo %*>> "${_calls.path}"\r\n'
      'if "%1"=="devices" (\r\n'
      '  echo List of devices attached\r\n'
      '  echo $_serial            device product:f model:Fake device:f\r\n'
      ')\r\n'
      'exit /b 0\r\n',
    );
  } else {
    final adb = File('$_tools/adb')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$*" >> "${_calls.path}"\n'
        'if [ "\$1" = "devices" ]; then\n'
        '  echo "List of devices attached"\n'
        '  echo "$_serial            device product:f model:Fake device:f"\n'
        'fi\n'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', adb.path]);
  }
}

/// A flutter that fails the way a broken build does: a reason on
/// stderr, then exit 1, without ever reporting an app.
String _exitingFlutter() {
  if (Platform.isWindows) {
    return (File('$_tools/flutter.bat')
          ..writeAsStringSync(
            '@echo off\r\n'
            'echo FAKE: Gradle task assembleDebug failed 1>&2\r\n'
            'exit /b 1\r\n',
          ))
        .path;
  }
  final file = File('$_tools/flutter')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'echo "FAKE: Gradle task assembleDebug failed" >&2\n'
      'exit 1\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// A flutter that keeps running and never reports an app, shaped as the
/// real launcher is: on Windows a `.bat` whose work happens in a Dart
/// child, elsewhere a script that `exec`s Dart. The child writes its pid
/// to [_pidFile] and stays up for two minutes at most.
String _hangingFlutter() {
  final sleeper = File('${_root.path}/sleeper.dart')
    ..writeAsStringSync(
      "import 'dart:io';\n"
      'Future<void> main(List<String> args) async {\n'
      "  File(args.single).writeAsStringSync('\$pid');\n"
      '  await Future<void>.delayed(const Duration(minutes: 2));\n'
      '}\n',
    );
  final dart = Platform.resolvedExecutable;
  if (Platform.isWindows) {
    return (File('$_tools/flutter.bat')
          ..writeAsStringSync(
            '@echo off\r\n'
            '"$dart" "${sleeper.path}" "${_pidFile.path}"\r\n',
          ))
        .path;
  }
  final file = File('$_tools/flutter')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'exec "$dart" "${sleeper.path}" "${_pidFile.path}"\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// A flutter that prints [stdoutLines] - machine-protocol events, or
/// anything else - then [stderrLine] if given, then exits 1.
String _scriptedFlutter(List<String> stdoutLines, {String? stderrLine}) {
  final lines = File('${_root.path}/stdout.txt')
    ..writeAsStringSync('${stdoutLines.join('\n')}\n');
  if (Platform.isWindows) {
    return (File('$_tools/flutter.bat')
          ..writeAsStringSync(
            '@echo off\r\n'
            // `type` takes no forward slashes.
            'type "${lines.path.replaceAll('/', r'\')}"\r\n'
            '${stderrLine == null ? '' : 'echo $stderrLine 1>&2\r\n'}'
            'exit /b 1\r\n',
          ))
        .path;
  }
  final file = File('$_tools/flutter')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'cat "${lines.path}"\n'
      '${stderrLine == null ? '' : 'echo "$stderrLine" >&2\n'}'
      'exit 1\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

String _log(String level, String message) =>
    '[{"event":"daemon.logMessage","params":'
    '{"level":"$level","message":"$message"}}]';

typedef Probe = ({int elapsedMs, String error, String message, String raw});

Future<Probe> _probe(
  String flutter, {
  required int timeoutSeconds,
  List<String> defines = const [],
}) async {
  final system = Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32'
      : '/usr/bin:/bin';
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      'test/cli/support/launch_lifecycle_probe.dart',
      '${_root.path}/app',
      _serial,
      flutter,
      '$timeoutSeconds',
      '$_reversePort',
      ...defines,
    ],
    environment: {
      'PATH': [_tools, system].join(Platform.isWindows ? ';' : ':'),
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
  );
  final out = process.stdout.transform(const SystemEncoding().decoder).join();
  final err = process.stderr.transform(const SystemEncoding().decoder).join();
  final code = await process.exitCode.timeout(
    Duration(seconds: timeoutSeconds + 90),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );

  final raw = 'exit $code\nstdout:\n${await out}\nstderr:\n${await err}';
  String field(String name) => RegExp('^$name=(.*)\$', multiLine: true)
          .firstMatch(raw)
          ?.group(1)
          ?.trim() ??
      '';
  return (
    elapsedMs: int.tryParse(field('ELAPSED_MS')) ?? -1,
    error: field('ERROR'),
    message: field('MESSAGE'),
    raw: raw,
  );
}

List<String> _reverseCalls() => _calls.existsSync()
    ? [
        for (final line in _calls.readAsLinesSync())
          if (line.contains('reverse')) line.trim(),
      ]
    : const [];

bool _alive(int pid) {
  if (Platform.isWindows) {
    final result =
        Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']);
    return '${result.stdout}'.contains('"$pid"');
  }
  return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
}

void _kill(int pid) {
  if (Platform.isWindows) {
    Process.runSync('taskkill', ['/F', '/PID', '$pid']);
  } else {
    Process.runSync('kill', ['-9', '$pid']);
  }
}

/// Whether [pid] is gone within a few seconds. Polled, not slept: a kill
/// is asynchronous on every system.
Future<bool> _endsSoon(int pid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (!_alive(pid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return !_alive(pid);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('flutter_lifecycle');
    Directory(_tools).createSync();
    Directory('${_root.path}/app').createSync();
    File('${_root.path}/app/pubspec.yaml').writeAsStringSync('name: app\n');
    _calls = File('${_root.path}/adb_calls.log');
    _pidFile = File('${_root.path}/child.pid');
    _fakeAdb();
  });

  tearDown(() async {
    // Never leave the stand-in running, whatever the test concluded - and
    // wait for it to go, since on Windows a process still exiting holds
    // the directory it was started from.
    if (_pidFile.existsSync()) {
      final pid = int.tryParse(_pidFile.readAsStringSync().trim());
      if (pid != null && _alive(pid)) {
        _kill(pid);
        await _endsSoon(pid);
      }
    }
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  test('a flutter run that exits is reported at once, with its reason',
      () async {
    final probe = await _probe(_exitingFlutter(), timeoutSeconds: 60);

    expect(probe.error, isNot('none'), reason: probe.raw);
    expect(probe.elapsedMs, inInclusiveRange(0, 30000), reason: probe.raw);
    expect(probe.message, contains('exited with code 1'), reason: probe.raw);
    expect(
      probe.message,
      contains('Gradle task assembleDebug failed'),
      reason: probe.raw,
    );
    expect(probe.message, isNot(contains('did not start within')),
        reason: probe.raw);

    // The mapping made before the start is undone on this path too.
    expect(_reverseCalls(), [
      '-s $_serial reverse tcp:$_reversePort tcp:$_reversePort',
      '-s $_serial reverse --remove tcp:$_reversePort',
    ], reason: probe.raw);
  });

  group('the reason flutter gave on stdout', () {
    // `flutter run --machine` reports most failures as protocol events
    // on stdout - `daemon.logMessage` at level "error", and an `app.stop`
    // carrying `error` - not on stderr. Measured at 25fdc3b, with
    // FlutterRunSession reading only app.start, app.debugPort,
    // app.started and app.stop's arrival: the launch said "exited with
    // code 1" and nothing about why.

    test('an error event and app.stop are the reason, nothing else is',
        () async {
      final probe = await _probe(
        _scriptedFlutter([
          _log('status', 'Running Gradle task assembleDebug...'),
          _log('error', 'FAILURE: Build failed with an exception. '
              'Could not resolve s3cr3t-value-123'),
          '[{"event":"app.stop","params":{"appId":"a",'
              '"error":"Gradle task assembleDebug failed with exit code 1",'
              '"trace":"#0 Frame (package:flutter_tools/src/x.dart:1)"}}]',
        ]),
        timeoutSeconds: 60,
        defines: ['API_KEY=s3cr3t-value-123'],
      );

      expect(probe.message, contains('exited with code 1'), reason: probe.raw);
      expect(probe.message, contains('Build failed with an exception'),
          reason: probe.raw);
      expect(probe.message,
          contains('Gradle task assembleDebug failed with exit code 1'),
          reason: probe.raw);
      // Progress is not a reason, a stack trace is not for the reader,
      // and a --dart-define value is never repeated.
      expect(probe.message, isNot(contains('Running Gradle task')),
          reason: probe.raw);
      expect(probe.message, isNot(contains('package:flutter_tools')),
          reason: probe.raw);
      expect(probe.message, isNot(contains('s3cr3t-value-123')),
          reason: probe.raw);
    });

    test('malformed protocol lines are ignored, not fatal', () async {
      final probe = await _probe(
        _scriptedFlutter([
          'not json at all',
          '[{"event":"daemon.logMessage","params":{"level":"error","mess',
          '[{"event":"daemon.logMessage","params":"not a map"}]',
          '[{"event":"daemon.logMessage","params":{"level":"error",'
              '"message":42}}]',
          _log('error', 'Target file lib/main.dart not found.'),
        ]),
        timeoutSeconds: 60,
      );

      expect(probe.error, 'StateError', reason: probe.raw);
      expect(probe.message, contains('exited with code 1'), reason: probe.raw);
      expect(probe.message, contains('Target file lib/main.dart not found'),
          reason: probe.raw);
    });

    test('control: status and trace events are not a reason', () async {
      final probe = await _probe(
        _scriptedFlutter(
          [
            _log('status', 'Launching lib/main.dart in debug mode...'),
            _log('trace', 'some internal trace'),
            '[{"event":"app.progress","params":'
                '{"message":"Running Gradle task","finished":false}}]',
          ],
          stderrLine: 'FAKE stderr reason',
        ),
        timeoutSeconds: 60,
      );

      expect(probe.message, contains('exited with code 1'), reason: probe.raw);
      expect(probe.message, contains('FAKE stderr reason'), reason: probe.raw);
      expect(probe.message, isNot(contains('Launching lib/main.dart')),
          reason: probe.raw);
      expect(probe.message, isNot(contains('some internal trace')),
          reason: probe.raw);
    });

    test('a reason on both stdout and stderr is said once', () async {
      final probe = await _probe(
        _scriptedFlutter(
          [_log('error', 'Gradle build failed')],
          stderrLine: 'Gradle build failed',
        ),
        timeoutSeconds: 60,
      );

      expect(
        'Gradle build failed'.allMatches(probe.message),
        hasLength(1),
        reason: probe.raw,
      );
    });

    test('however much is reported, what is kept is bounded', () async {
      final long = 'x' * 3000;
      final probe = await _probe(
        _scriptedFlutter([
          for (var i = 0; i < 400; i++) _log('error', 'error $i $long'),
        ]),
        timeoutSeconds: 60,
      );

      expect(probe.message, contains('exited with code 1'), reason: probe.raw);
      expect(probe.message.length, lessThan(30000));
      // The last word is the one most likely to be the cause.
      expect(probe.message, contains('error 399'));
    });
  });

  test('control: one that keeps running is still a timeout', () async {
    final probe = await _probe(_hangingFlutter(), timeoutSeconds: 8);

    expect(probe.message, contains('did not start within'), reason: probe.raw);
    expect(probe.message, isNot(contains('exited with code')),
        reason: probe.raw);
    expect(_reverseCalls(), hasLength(2), reason: probe.raw);
  });

  test('after a timeout, the flutter run process is gone', () async {
    final probe = await _probe(_hangingFlutter(), timeoutSeconds: 8);

    expect(probe.message, contains('did not start within'), reason: probe.raw);
    expect(_pidFile.existsSync(), isTrue,
        reason: 'the stand-in never started\n${probe.raw}');
    final pid = int.parse(_pidFile.readAsStringSync().trim());
    expect(await _endsSoon(pid), isTrue,
        reason: 'pid $pid outlived the teardown\n${probe.raw}');
  });
}
