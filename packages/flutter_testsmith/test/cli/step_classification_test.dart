// Which kind of thing went wrong when a step threw.
//
// `FlowExecutor.run` caught everything and wrote `StepStatus.failed`,
// which `RunResult` turns into a UI FAIL. That is right for an assertion
// that did not hold and wrong for the engine losing its ability to look,
// and the two had no way to be told apart.
//
// The decision is made by type, through the predicate E-05 already
// established. Never by message text: a broad catch that means "the
// application misbehaved" is only correct once the infrastructure types
// have been let through, and matching on wording would make that
// correctness depend on nobody rephrasing a diagnostic.
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/flow_executor.dart';
import 'package:flutter_testsmith/engine.dart';

String executorSource() {
  for (final candidate in [
    'lib/src/cli/flow_executor.dart',
    'packages/flutter_testsmith/lib/src/cli/flow_executor.dart',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find flow_executor.dart');
}

void main() {
  group('the engine could not look', () {
    test('an unanswered RPC is an observation failure', () {
      expect(
        stepStatusFor(
          const TransportTimeoutException(
            operation: 'ext.mytest.uiTree',
            timeout: Duration(seconds: 30),
          ),
        ),
        StepStatus.observationFailed,
      );
    });

    test('a lost connection is an observation failure', () {
      expect(
        stepStatusFor(
          const TransportDisconnectedException(
            TransportLiveness.disconnected,
          ),
        ),
        StepStatus.observationFailed,
      );
    });

    test('an unreadable event stream is an observation failure', () {
      expect(
        stepStatusFor(const ProtocolObservationException('protocol 2.0')),
        StepStatus.observationFailed,
      );
    });

    test('a device that stopped answering is an observation failure', () {
      // A tap or a screenshot whose adb never came back. Recorded as
      // `failed` it was a UI FAIL at exit 1 - the application blamed for
      // a handset that had stopped answering.
      expect(
        stepStatusFor(
          const DeviceTimeoutException(
            command: 'adb -s S1 shell input tap 1 2',
            timeout: Duration(seconds: 30),
            stopped: true,
          ),
        ),
        StepStatus.observationFailed,
      );
    });

    test('control: an adb command that answered with an error is not', () {
      // It ran and replied. Whether that reply is about the device or the
      // application is not decided here, so it keeps what it had.
      expect(
        stepStatusFor(
          const DeviceCommandException(
            command: 'adb -s S1 shell input tap 1 2',
            exitCode: 1,
            stderr: 'error',
          ),
        ),
        StepStatus.failed,
      );
    });
  });

  group('the application did something wrong', () {
    test('an assertion that did not hold is still a failed step', () {
      expect(
        stepStatusFor(StateError('expected to be on "/home"')),
        StepStatus.failed,
      );
    });

    test('an element that is not there is still a failed step', () {
      expect(
        stepStatusFor(
          const ElementNotFoundException(testId: 'cta', available: []),
        ),
        StepStatus.failed,
      );
    });

    test('an element that cannot be tapped is still a failed step', () {
      expect(
        stepStatusFor(
          const ElementNotTappableException(testId: 'cta', reason: 'disabled'),
        ),
        StepStatus.failed,
      );
    });

    test('an unexpected programmer error keeps the existing behaviour', () {
      // Not reclassified. A bug in this codebase must keep surfacing as
      // a failing step rather than being filed as a flaky device.
      expect(stepStatusFor(UnimplementedError('a bug')), StepStatus.failed);
    });
  });

  group('the classification has one source', () {
    test('it is decided by the shared predicate, not a local list', () {
      // A second list of infrastructure types would drift the first time
      // one was added.
      expect(executorSource(), contains('isInfrastructureFailure'));
    });

    test('the run loop uses it rather than hard-coding failed', () {
      expect(executorSource(), contains('stepStatusFor(error)'));
    });

    test('nothing matches on message text', () {
      final source = executorSource();
      expect(source, isNot(contains("contains('Transport")));
      expect(source, isNot(contains('TimeoutException(')));
    });
  });

  group('the exit code says which kind of problem it was', () {
    // The CI contract this repository already states on SuiteVerdict:
    // 0 passed, 1 something is wrong with the application, 2 something
    // is wrong with the run. `testsmith run` returned 1 for everything.
    RunResult runWith(StepStatus status) => RunResult(
          flowName: 'f',
          appId: 'a',
          device: 'd',
          startedAt: DateTime.utc(2026),
          duration: Duration.zero,
          steps: [
            StepOutcome(description: 's', kind: StepKind.tap, status: status, durationMs: 0),
          ],
          screens: const [],
        );

    test('a passing run exits 0', () {
      expect(exitCodeForRun(runWith(StepStatus.ok)), 0);
    });

    test('an application failure exits 1', () {
      expect(exitCodeForRun(runWith(StepStatus.failed)), 1);
    });

    test('an observation failure exits 2, not 1', () {
      expect(exitCodeForRun(runWith(StepStatus.observationFailed)), 2);
    });

    test('a step whose adb never answered is an observation failure, at 2',
        () {
      // From the exception to the run, through the decision the run loop
      // makes: not a UI FAIL, and not the application's exit code.
      final run = runWith(
        stepStatusFor(
          const DeviceTimeoutException(
            command: 'adb -s S1 shell input tap 1 2',
            timeout: Duration(seconds: 30),
            stopped: true,
          ),
        ),
      );

      expect(run.observationFailed, isTrue);
      expect(run.passed, isFalse);
      expect(exitCodeForRun(run), 2);
    });

    RunResult runValidating(ValidationResult check) => RunResult(
          flowName: 'f',
          appId: 'a',
          device: 'd',
          startedAt: DateTime.utc(2026),
          duration: Duration.zero,
          steps: const [
            StepOutcome(description: 's', kind: StepKind.tap, status: StepStatus.ok, durationMs: 0),
          ],
          screens: [
            ScreenResult(screenId: '/s', report: ValidationReport([check])),
          ],
        );

    test('a validation that could not be established exits 2, not 1', () {
      // Exit 1 means the application is wrong. A screen the tool could
      // not photograph has not shown that.
      expect(
        exitCodeForRun(
          runValidating(
            const ValidationResult.error(
              validatorId: 'visual',
              message: 'the screen would not hold still',
              dimension: ValidationDimension.visual,
            ),
          ),
        ),
        2,
      );
    });

    test('a genuine validation failure still exits 1', () {
      expect(
        exitCodeForRun(
          runValidating(
            const ValidationResult.fail(
              validatorId: 'api-to-ui',
              message: 'the price is wrong',
              dimension: ValidationDimension.ui,
            ),
          ),
        ),
        1,
      );
    });
  });
}
