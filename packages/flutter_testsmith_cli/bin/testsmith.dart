import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith_cli/src/commands/auth_command.dart';
import 'package:flutter_testsmith_cli/src/commands/devices_command.dart';
import 'package:flutter_testsmith_cli/src/commands/doctor_command.dart';
import 'package:flutter_testsmith_cli/src/commands/figma_command.dart';
import 'package:flutter_testsmith_cli/src/commands/generate_command.dart';
import 'package:flutter_testsmith_cli/src/commands/impact_command.dart';
import 'package:flutter_testsmith_cli/src/commands/inspect_command.dart';
import 'package:flutter_testsmith_cli/src/commands/preflight_command.dart';
import 'package:flutter_testsmith_cli/src/commands/run_command.dart';
import 'package:flutter_testsmith_cli/src/commands/smoke_command.dart';
import 'package:flutter_testsmith_cli/src/commands/suite_command.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<int>(
    'testsmith',
    'AI-native testing for Flutter applications.',
  )
    ..addCommand(AuthCommand())
    ..addCommand(DoctorCommand())
    ..addCommand(DevicesCommand())
    ..addCommand(FigmaCommand())
    ..addCommand(GenerateCommand())
    ..addCommand(ImpactCommand())
    ..addCommand(InspectCommand())
    ..addCommand(PreflightCommand())
    ..addCommand(RunCommand())
    ..addCommand(SmokeCommand())
    ..addCommand(SuiteCommand());

  var code = 0;
  try {
    code = await runner.run(arguments) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    code = 64; // EX_USAGE
  }

  // Flush explicitly: Dart block-buffers stdout when it is a pipe rather
  // than a terminal, so a redirected run would otherwise lose its report.
  await stdout.flush();

  // Exit rather than returning. Driving an external device leaves timers
  // and platform resources that can keep the event loop alive after the
  // work is done.
  exit(code);
}
