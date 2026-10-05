// A fixture server that cannot bind its port.
//
// `suite run` has always reported it: "The fixture server could not be
// started:", then the reason, then exit 2. `testsmith run` did not guard
// the bind at all - the nearest enclosing `try` closed eighteen lines
// above it - so the SocketException went all the way to
// `bin/testsmith.dart`, which catches `UsageException` and nothing else.
// The result was exit 255 and a Dart stack trace. E-04 describes exactly
// that outcome as the thing it fixed; it was fixed for a suite only.
//
// `smoke` did catch it, through the broad `catch (error)` around the
// runner, and printed `Smoke run failed: SocketException: Failed to
// create server socket ...` - the right exit code with the wrong
// sentence in front of it.
//
// Driven end to end and offline. The port is occupied by a real socket
// this test binds, and `MYTEST_ADB` points both commands at a fake adb
// that reports one attached device - which is what lets them past the
// device gate `5e9c169` put in front of the bind, without hardware. The
// bind fails before anything is launched, so no Flutter SDK is needed
// either.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;
late ServerSocket _squatter;
late int _takenPort;

const String _serial = 'FAKESERIAL1';
const String _established = 'The fixture server could not be started';

void _write(String relative, String contents) {
  final file = File('${_app.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// An adb that reports one attached device and nothing else.
///
/// `MYTEST_ADB` is the operator contract `resolveAdb` already honours, so
/// this needs no change to discovery. It answers `devices -l` in the
/// shape `parseAdbDevices` reads and ignores every other command.
String _fakeAdb() {
  final directory = Directory('${_root.path}/bin')..createSync(recursive: true);
  if (Platform.isWindows) {
    final file = File('${directory.path}/adb.bat')
      ..writeAsStringSync(
        '@echo off\r\n'
        'echo List of devices attached\r\n'
        'echo $_serial            device product:fake model:Fake device:fake\r\n',
      );
    return file.path;
  }
  final file = File('${directory.path}/adb')
    ..writeAsStringSync(
      '#!/bin/sh\n'
      'echo "List of devices attached"\n'
      'echo "$_serial            device product:fake model:Fake device:fake"\n',
    );
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

typedef Run = ({String output, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: {'MYTEST_ADB': _fakeAdb()},
  );
  return (output: '${result.stdout}${result.stderr}', code: result.exitCode);
}

/// What a bind failure must never look like, whichever command hit it.
void expectReportedNotCrashed(Run run) {
  expect(run.output, isNot(contains('Unhandled exception')), reason: run.output);
  expect(run.code, isNot(255), reason: run.output);
  expect(run.code, isNot(0), reason: run.output);
  expect(run.output, contains(_established), reason: run.output);
  // The cause may appear as detail; it may not be the headline.
  expect(
    run.output.indexOf(_established) < run.output.indexOf('SocketException'),
    isTrue,
    reason: 'the raw exception came before the established sentence:\n'
        '${run.output}',
  );
}

void main() {
  setUp(() async {
    _root = Directory.systemTemp.createTempSync('fixture_server');
    _app = Directory('${_root.path}/app')..createSync(recursive: true);
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.12.0\n');
    _write('lib/main.dart', 'void main() {}\n');
    _write(
      'tests/home.yaml',
      'appId: com.example.x\nflow: home\nsteps:\n  - launchApp\n',
    );
    _write(
      'mock_api/scenarios/default.json',
      '{"name": "default", "description": "", "routes": {}}',
    );

    _squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _takenPort = _squatter.port;

    addTearDown(() async {
      await _squatter.close();
      _root.deleteSync(recursive: true);
    });
  });

  test('run reports a port it cannot bind, and does not crash', () async {
    final run = await _testsmith([
      'run',
      '${_app.path}/tests/home.yaml',
      '--app',
      _app.path,
      '-d',
      _serial,
      '--mock-api',
      '$_takenPort',
    ]);

    expectReportedNotCrashed(run);
    // 2 since RUN-ENV-EXIT, the code `suite run` gives this failure.
    // `smoke`, below, produces no verdict and keeps its 1.
    expect(run.code, 2, reason: run.output);
  });

  test('smoke reports it with the same sentence, not the raw exception',
      () async {
    final run = await _testsmith([
      'smoke',
      '--app',
      _app.path,
      '--app-id',
      'com.example.x',
      '-d',
      _serial,
      '--mock-api',
      '$_takenPort',
    ]);

    expectReportedNotCrashed(run);
    expect(run.code, 1, reason: run.output);
  });

  test('a free port is still bound and announced, by run', () async {
    // The control: the guard must not turn a working fixture server into
    // a refusal. Watched rather than awaited - a successful bind is
    // followed by the real launch, which would sit here for its whole
    // timeout, so the process is stopped the moment it has proved the
    // point.
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        '${Directory.current.path}/bin/testsmith.dart',
        'run',
        '${_app.path}/tests/home.yaml',
        '--app',
        _app.path,
        '-d',
        _serial,
        '--mock-api',
        '0',
      ],
      environment: {'MYTEST_ADB': _fakeAdb()},
    );

    final announced = Completer<String>();
    final seen = StringBuffer();
    final lines = process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      seen.writeln(line);
      if (line.contains('mock API on') && !announced.isCompleted) {
        announced.complete(line);
      }
    });

    final line = await announced.future
        .timeout(const Duration(seconds: 90), onTimeout: () => '');
    await lines.cancel();
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;

    expect(line, contains('mock API on'), reason: 'saw:\n$seen');
    expect(seen.toString(), isNot(contains(_established)),
        reason: 'saw:\n$seen');
  });
}
