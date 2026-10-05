// A credential must not reach an exception message.
//
// The leak this closes was real and specific: `DeviceCommandException`
// renders the whole command, `_adb` builds that string from the full
// argument vector, and `inputText` passes the typed value as an
// argument. A failed `adb shell input text <PIN>` therefore put the PIN
// into StepOutcome.detail, and from there into result.json, report.html
// and stdout.
//
// Asserted by searching the message for the literal, which is the
// discipline the existing leakage tests already use: checking that the
// right field was redacted proves only that the redactor did what it was
// told.

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const String seededPin = 'SEEDED_PIN_9f2a41c8';

/// Runs nothing, records what it was asked to run, and fails on demand.
class FakeRunner implements ProcessRunner {
  FakeRunner({this.exitCode = 0, this.stderr = ''});

  final int exitCode;
  final String stderr;
  final List<List<String>> calls = [];

  @override
  Future<ProcessResultData> run(
    String executable,
    List<String> arguments,
  ) async {
    calls.add(arguments);
    return ProcessResultData(
      exitCode: exitCode,
      stdout: '',
      stderr: stderr,
    );
  }
}

/// Answers every command the way a bounded run does when it is not
/// answered in time.
class _TimingOutRunner implements ProcessRunner {
  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) =>
      throw const ProcessTimeoutException(
        tool: 'adb',
        timeout: AdbDeviceController.commandTimeout,
        stopped: true,
      );
}

void main() {
  test('the real value is what reaches the device', () async {
    final runner = FakeRunner();
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    await device.inputSecret(const Secret(seededPin));

    expect(
      runner.calls.single,
      ['-s', 'S1', 'shell', 'input', 'text', seededPin],
    );
  });

  test('and never reaches the exception when the command fails', () async {
    final runner = FakeRunner(exitCode: 1);
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    late final Object error;
    try {
      await device.inputSecret(const Secret(seededPin));
      fail('expected a DeviceCommandException');
    } catch (thrown) {
      error = thrown;
    }

    expect(error, isA<DeviceCommandException>());
    expect('$error', isNot(contains(seededPin)));
    expect('$error', contains(redactionMarker));
  });

  test('nor through stderr, if the device echoes it back', () async {
    final runner = FakeRunner(
      exitCode: 1,
      stderr: 'Error: bad argument "$seededPin"',
    );
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    late final Object error;
    try {
      await device.inputSecret(const Secret(seededPin));
      fail('expected a DeviceCommandException');
    } catch (thrown) {
      error = thrown;
    }

    expect('$error', isNot(contains(seededPin)));
  });

  test(
      'a space is escaped for `input text`, and the escaped form is '
      'scrubbed too', () async {
    const spaced = 'SEEDED VALUE';
    final runner = FakeRunner(exitCode: 1, stderr: 'saw SEEDED%sVALUE');
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    late final Object error;
    try {
      await device.inputSecret(const Secret(spaced));
      fail('expected a DeviceCommandException');
    } catch (thrown) {
      error = thrown;
    }

    expect('$error', isNot(contains('SEEDED%sVALUE')));
    expect('$error', isNot(contains(spaced)));
  });

  test('inputText is untouched, so no E-04 behaviour changes', () async {
    final runner = FakeRunner();
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    await device.inputText('hello world');

    expect(
      runner.calls.single,
      ['-s', 'S1', 'shell', 'input', 'text', 'hello%sworld'],
    );
  });

  test('nor the timeout when the command never finishes', () async {
    // The third way out of `_adb`, added for an adb that hangs. It names
    // the command too, so it is held to the same rule as the failure.
    final device = AdbDeviceController(
      serial: 'S1',
      processRunner: _TimingOutRunner(),
    );

    late final Object error;
    try {
      await device.inputSecret(const Secret(seededPin));
      fail('a command that never finished must not succeed');
    } on DeviceTimeoutException catch (e) {
      error = e;
    }

    expect('$error', isNot(contains(seededPin)));
    expect('$error', contains(redactionMarker));
    expect('$error', contains('did not finish within 30 seconds'));
  });

  group('SecretInputStep', () {
    test('describes the reference and never a value', () {
      final step = SecretInputStep(
        elementId: 'secure_login.pin_field',
        ref: SecretRef.parse('env:MYTEST_AUTH_PIN', source: 'test'),
      );

      expect(
        step.describe(),
        'type <env:MYTEST_AUTH_PIN> into "secure_login.pin_field"',
      );
      expect(step.describe(), isNot(contains(seededPin)));
    });
  });
}
