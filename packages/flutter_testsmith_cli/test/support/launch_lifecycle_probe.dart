// One `AppSession.launch` with a flutter the test controls, and how it
// ended.
//
// Run as a child process for the reason `smoke_launch_failure_probe`
// gives: which adb the launch uses is read from the process environment.
// The flutter is passed in, and so is the launch timeout - the only
// way to see a wait that would otherwise be eight minutes long.
//
//   ELAPSED_MS=<how long launch took to return or throw>
//   ERROR=<the type it threw>           or ERROR=none
//   MESSAGE=<what it said, one line>
//   LOG=<a line the session logged>     one per line
//
// Exits explicitly, so nothing the launch left running can hold it open.
import 'dart:io';

import 'package:flutter_testsmith_cli/src/app_session.dart';

Future<void> main(List<String> arguments) async {
  // Anything after the fifth argument is a `--dart-define`.
  final [
    projectPath,
    serial,
    flutter,
    timeoutSeconds,
    reversePort,
    ...defines,
  ] = arguments;

  final lines = <String>[];
  final clock = Stopwatch()..start();
  var thrown = 'none';
  var message = '';
  try {
    final session = await AppSession.launch(
      projectDirectory: Directory(projectPath),
      deviceSerial: serial,
      appId: 'com.example.x',
      log: lines.add,
      reversePort: reversePort == 'none' ? null : int.parse(reversePort),
      launchTimeout: Duration(seconds: int.parse(timeoutSeconds)),
      dartDefines: defines,
      flutterExecutable: flutter,
    );
    await session.dispose();
  } catch (error) {
    thrown = '${error.runtimeType}';
    message = '$error'.replaceAll(RegExp(r'\s+'), ' ');
  }
  clock.stop();

  stdout
    ..writeln('ELAPSED_MS=${clock.elapsedMilliseconds}')
    ..writeln('ERROR=$thrown')
    ..writeln('MESSAGE=$message');
  for (final line in lines) {
    stdout.writeln('LOG=$line');
  }
  await stdout.flush();
  exit(0);
}
