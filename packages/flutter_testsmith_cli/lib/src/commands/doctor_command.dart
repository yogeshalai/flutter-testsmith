import 'package:args/command_runner.dart';

import '../environment.dart';
import '../output.dart';

/// Reports whether this machine can run tests, and what to fix if not.
class DoctorCommand extends Command<int> {
  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check that this machine has everything needed to run tests.';

  @override
  Future<int> run() async {
    final report = await const EnvironmentProbe().run();
    Output().renderDoctor(report);
    return report.exitCode;
  }
}
