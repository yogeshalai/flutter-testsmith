import '../validation/validation_result.dart';
import '../visual/visual_validator.dart';
import 'run_result.dart';

/// The end-of-run report, organised by the layer that failed.
///
/// The problem it solves is not a wrong verdict - those were already
/// right - but an unreadable one. A run that stopped because an
/// undeclared animation blocked the photograph printed a validation
/// error among forty step lines, and the first question anyone asked
/// was "so did the API even work?".
///
/// Four sections, always in this order, each answering one layer's
/// question:
///
/// ```
/// API          did the application get the data it asked for?
/// UI           did the flow get where it was going?
/// QUIESCENCE   was the screen still enough to photograph?
/// VISUAL       does it look like the accepted picture?
/// ```
///
/// An empty section says it is empty rather than being left out. "No
/// API assertions were made" and "every API assertion passed" are
/// different facts, and a missing section reads as the second.
class E2eSummary {
  const E2eSummary();

  static const String _rule =
      '────────────────────────────────────────────────';

  String render(RunResult result) => renderLines(result).join('\n');

  List<String> renderLines(RunResult result) => [
        'E2E: ${result.flowName}',
        _rule,
        '',
        ..._api(result),
        '',
        ..._ui(result),
        '',
        ..._quiescence(result),
        '',
        ..._visual(result),
        '',
        // The run's own verdict, not a second opinion about it.
        //
        // This line used to aggregate the raw results itself, because
        // `overall` could be blind to a result carrying no dimension. A
        // report now refuses one, so every result is in exactly one
        // dimension block and `overall` sees all of them. Two answers to
        // one question is two things to drift.
        'RESULT: ${result.overall.wire.toUpperCase()}',
      ];

  List<String> _api(RunResult result) {
    if (result.apiChecks.isEmpty) {
      return const [
        'API',
        '- no API assertions in this flow',
      ];
    }

    return [
      'API',
      for (final check in result.apiChecks)
        if (check.satisfied)
          '✓ ${check.endpoint}  ${check.status}'
        else ...[
          '✗ ${check.endpoint}',
          for (final failure in check.failures) '    $failure',
        ],
    ];
  }

  List<String> _ui(RunResult result) {
    // The API assertions have a section of their own. A line in both
    // would make the report look like twice as much happened.
    final steps = [
      for (final step in result.steps)
        if (!isApiAssertionStep(
          kind: step.kind.wire,
          description: step.description,
        ))
          step,
    ];

    if (steps.isEmpty) return const ['UI', '- no steps ran'];

    return [
      'UI',
      for (final step in steps) ...[
        '${_mark(step.status)} ${step.description}',
        if (step.detail != null) '    ${step.detail}',
      ],
    ];
  }

  String _mark(StepStatus status) => switch (status) {
        StepStatus.ok => '✓',
        StepStatus.failed => '✗',
        // Distinct from '✗' on purpose: the step did not fail, it could
        // not be carried out.
        StepStatus.observationFailed => '!',
        StepStatus.skipped => '-',
      };

  List<String> _quiescence(RunResult result) {
    final measured = [
      for (final screen in result.screens)
        if (screen.quiescence != null) screen,
    ];

    if (measured.isEmpty) {
      return const [
        'QUIESCENCE',
        '- nothing was ticking on any validated screen',
      ];
    }

    final lines = <String>['QUIESCENCE'];
    for (final screen in measured) {
      final summary = screen.quiescence!;
      if (summary.ticking == 0 && summary.unexpected == 0) {
        lines.add('✓ ${screen.screenId}: nothing was ticking');
        continue;
      }

      final mark = summary.unexpected == 0 ? '✓' : '✗';
      lines
        ..add('$mark ${screen.screenId}')
        ..add('    ticking animations: ${summary.ticking}')
        ..add('    permitted: ${summary.permitted}')
        ..add('    unexpected: ${summary.unexpected}');

      // The evaluator's own wording, not a second paraphrase of it.
      // Two descriptions of one fact drift, and then the report and the
      // terminal disagree about what was excluded.
      for (final detail in summary.lines) {
        if (detail.trimLeft().startsWith('permitted:') ||
            detail.trimLeft().startsWith('unexpected:') ||
            detail.trimLeft().startsWith('declared but not animating')) {
          lines.add('    ${detail.trim()}');
        }
      }
    }
    return lines;
  }

  List<String> _visual(RunResult result) {
    final rows = <({String screenId, ValidationResult result})>[
      for (final screen in result.screens)
        for (final row in screen.report.results)
          if (row.validatorId == VisualValidator.id)
            (screenId: screen.screenId, result: row),
    ];

    if (rows.isEmpty) {
      return const ['VISUAL', '- no screenshot was compared'];
    }

    return [
      'VISUAL',
      for (final row in rows)
        switch (row.result.status) {
          ValidationStatus.pass => '✓ ${row.result.message}',
          ValidationStatus.fail => '✗ ${row.result.message}',
          // Never "failed". An undeclared animation means the tool could
          // not take an honest picture; it is not a claim that the
          // screen is wrong.
          ValidationStatus.error => 'BLOCKED — ${row.result.message}',
          ValidationStatus.skip => '- ${row.result.message}',
        },
    ];
  }
}
