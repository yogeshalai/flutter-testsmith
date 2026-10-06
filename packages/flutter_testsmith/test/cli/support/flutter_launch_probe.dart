// The two lines of `AppSession.launch` that matter here, and nothing
// else.
//
// Run as a child process on purpose. The defect this exists to catch
// needs two different directories - the one flutter is *discovered*
// from, and the one it is *launched* into - and the first of those is a
// process's own working directory, which a test cannot change for itself
// without changing it for every other suite sharing the process.
//
// So: the test starts this with `workingDirectory` set to the discovery
// directory, and passes the launch directory as the single argument.
// What it prints is what `AppSession.launch` would have run.
import 'dart:io';

import 'package:flutter_testsmith/engine.dart';

Future<void> main(List<String> arguments) async {
  final launchDirectory = arguments.single;

  // Exactly what AppSession.launch does, in the same order: resolve
  // against where we are standing, then launch somewhere else.
  final flutter = resolveFlutter().executableOrBareName;
  stdout.writeln('RESOLVED=$flutter');

  try {
    final process = await startProcess(
      flutter,
      const [],
      workingDirectory: launchDirectory,
    );
    final out =
        await process.stdout.transform(const SystemEncoding().decoder).join();
    final err =
        await process.stderr.transform(const SystemEncoding().decoder).join();

    stdout.writeln('EXIT=${await process.exitCode}');
    stdout.writeln('RAN=${out.trim().replaceAll('\n', ' ')}');
    stdout.writeln('STDERR=${err.trim().replaceAll('\n', ' ')}');
  } on ProcessException catch (error) {
    stdout.writeln('EXIT=threw');
    stdout.writeln('RAN=');
    stdout.writeln('STDERR=${error.message}');
  }
}
