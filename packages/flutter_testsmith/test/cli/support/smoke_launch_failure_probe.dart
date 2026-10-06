// A smoke run whose launch fails, and whether its fixture server is
// still answering afterwards.
//
// Run as a child process on purpose. Which adb and which flutter the
// launch uses are read from the process environment, and a test cannot
// change its own environment without changing it for every other suite
// sharing the process. So the test starts this with a PATH holding fake
// tools, and reads what it prints:
//
//   LOG=<a line the runner printed>     one per line
//   ERROR=<the type run() threw>        or ERROR=none
//   PORT=<the port the server bound>    or PORT=none
//   SERVING=yes|no                      whether that port still accepts
//
// Exits explicitly: a server left open keeps the event loop alive, and
// the answer is wanted either way.
import 'dart:io';

import 'package:flutter_testsmith/src/cli/mock_api_server.dart';
import 'package:flutter_testsmith/src/cli/smoke.dart';

Future<void> main(List<String> arguments) async {
  final [projectPath, serial] = arguments;
  final project = Directory(projectPath);

  final lines = <String>[];
  final runner = SmokeRunner(
    projectDirectory: project,
    outputDirectory: Directory('${project.path}/out'),
    deviceSerial: serial,
    appId: 'com.example.x',
    mockApiPort: 0,
    // Resolved by the caller, as `smoke` resolves it before the device.
    mockApiScenario: ScenarioLibrary.load(
      Directory('${project.path}/mock_api/scenarios'),
    ).resolve(ScenarioLibrary.defaultName),
    stdout: lines.add,
  );

  String thrown = 'none';
  try {
    await runner.run();
  } catch (error) {
    thrown = '${error.runtimeType}';
  }

  for (final line in lines) {
    stdout.writeln('LOG=$line');
  }
  stdout.writeln('ERROR=$thrown');

  final match = RegExp(r'mock API on http://127\.0\.0\.1:(\d+)')
      .firstMatch(lines.join('\n'));
  if (match == null) {
    stdout.writeln('PORT=none');
  } else {
    final port = int.parse(match.group(1)!);
    stdout.writeln('PORT=$port');
    var serving = false;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 3),
      );
      serving = true;
      socket.destroy();
    } on SocketException {
      serving = false;
    }
    stdout.writeln('SERVING=${serving ? 'yes' : 'no'}');
  }

  await stdout.flush();
  exit(0);
}
