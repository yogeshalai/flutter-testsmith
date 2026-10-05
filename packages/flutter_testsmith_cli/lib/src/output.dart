import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Terminal formatting.
///
/// Colour is suppressed when stdout is not a terminal, so redirected output
/// and CI logs stay readable.
class Output {
  Output({bool? useColour})
      : _colour = useColour ?? stdout.supportsAnsiEscapes;

  final bool _colour;

  String _wrap(String text, String code) =>
      _colour ? '[${code}m$text[0m' : text;

  String green(String text) => _wrap(text, '32');
  String yellow(String text) => _wrap(text, '33');
  String red(String text) => _wrap(text, '31');
  String dim(String text) => _wrap(text, '90');
  String bold(String text) => _wrap(text, '1');

  void line([String text = '']) => stdout.writeln(text);

  String symbolFor(CheckStatus status) => switch (status) {
        CheckStatus.pass => green('[ok]'),
        CheckStatus.warn => yellow('[warn]'),
        CheckStatus.fail => red('[fail]'),
      };

  /// Renders what preflight found, one prerequisite per line.
  ///
  /// A deferral is printed as plainly as a blocker. "We could not know
  /// this yet" is a real finding, and hiding it would leave the reader
  /// believing everything had been checked.
  void renderPreflight(PreflightReport report) {
    line(bold('preflight'));
    line();

    for (final check in report.checks) {
      final symbol = switch (check.outcome) {
        PreflightOutcome.satisfied => green('[ok]   '),
        PreflightOutcome.blocked => red('[BLOCK]'),
        PreflightOutcome.deferred => yellow('[defer]'),
        PreflightOutcome.notice => dim('[note] '),
      };
      line('  $symbol ${check.name.padRight(22)} ${dim(check.detail)}');
      if (check.isBlocking && check.remedy.isNotEmpty) {
        line('          ${dim('-> ${check.remedy}')}');
      }
    }

    line();
    if (report.isBlocked) {
      line(red(
        '${report.blockers.length} blocking: '
        '${report.blockers.map((c) => c.name).join(', ')}',
      ));
      line(dim(
        'Nothing was run. These are environment problems, so no test '
        'below them would have said anything about the application.',
      ));
    } else {
      line(green('nothing blocking'));
    }
  }

  void renderDoctor(DoctorReport report) {
    line(bold('testsmith doctor'));
    line();

    for (final check in report.checks) {
      final detail = check.detail.isEmpty ? '' : dim('  ${check.detail}');
      line('  ${symbolFor(check.status)} ${check.name}$detail');
      if (check.remedy.isNotEmpty && check.status != CheckStatus.pass) {
        line('         ${dim('-> ${check.remedy}')}');
      }
    }

    line();
    final summary = '${report.passCount} ok, ${report.warnCount} warning, '
        '${report.failCount} failed';
    line(report.isHealthy ? green(summary) : red(summary));
  }
}
