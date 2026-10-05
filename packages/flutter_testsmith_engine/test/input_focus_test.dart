// DEF-E05-04 - text sent before the field is focused arrives truncated.
//
// Measured on a Samsung SM-M127G against an external login screen:
// the runner tapped the mobile field and typed "9000000001" immediately.
// The field received "000000001". The leading character was swallowed
// while the field was still taking focus, the Continue button stayed
// disabled at nine digits, and the application - correctly - never made
// a login request. The tool had typed the wrong value.
//
// The fix waits on an OBSERVABLE condition: Android reports
// `mInputShown` in `dumpsys input_method` once an editor has focus.
// These tests pin the device-layer half of that: the flag is read, and
// it is read from the right field.
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Answers adb calls from a script, and records what was asked.
class FakeRunner implements ProcessRunner {
  FakeRunner({this.imeDump = _imeShown});

  final String imeDump;
  final List<List<String>> calls = [];

  static const String _imeShown =
      '  mShowRequested=true mShowExplicitlyRequested=false '
      'mShowForced=false mInputShown=true\n'
      '  mIsInputViewShown=true mStatusIcon=0';

  static const String imeHidden =
      '  mShowRequested=false mShowExplicitlyRequested=false '
      'mShowForced=false mInputShown=false\n'
      '  mIsInputViewShown=true mStatusIcon=0';

  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) async {
    calls.add(arguments);
    final joined = arguments.join(' ');
    if (joined.contains('input_method')) {
      return ProcessResultData(exitCode: 0, stdout: imeDump, stderr: '');
    }
    return const ProcessResultData(exitCode: 0, stdout: '', stderr: '');
  }
}

AdbDeviceController _controller(FakeRunner runner) => AdbDeviceController(
      serial: 'RZ8T11QETWM',
      processRunner: runner,
    );

void main() {
  group('the readiness signal is observable, not a sleep', () {
    test('a focused editor reports ready', () async {
      final runner = FakeRunner();
      expect(await _controller(runner).isTextInputReady(), isTrue);
    });

    test('no focused editor reports not ready', () async {
      final runner = FakeRunner(imeDump: FakeRunner.imeHidden);
      expect(await _controller(runner).isTextInputReady(), isFalse);
    });

    test('readiness is read from mInputShown, not mIsInputViewShown', () {
      // The distinction is the whole point: mIsInputViewShown stays true
      // while the IME process is alive with no field focused at all,
      // which is exactly the state this has to tell apart.
      expect(FakeRunner.imeHidden, contains('mIsInputViewShown=true'));
      expect(FakeRunner.imeHidden, contains('mInputShown=false'));
    });

    test('it asks the platform rather than waiting a fixed time', () async {
      final runner = FakeRunner();
      await _controller(runner).isTextInputReady();
      expect(
        runner.calls.any((c) => c.join(' ').contains('dumpsys input_method')),
        isTrue,
      );
    });
  });

  group('the value reaching the device is whole and unlogged', () {
    test('a ten digit value is sent in full', () async {
      final runner = FakeRunner();
      await _controller(runner).inputText('9000000001');

      final typed = runner.calls.firstWhere((c) => c.contains('text'));
      expect(typed.last, '9000000001',
          reason: 'the value was altered on the way to the device');
    });

    test('a secret is sent in full, and never rendered', () async {
      final runner = FakeRunner();
      await _controller(runner).inputSecret(const Secret('9000000001'));

      final typed = runner.calls.firstWhere((c) => c.contains('text'));
      expect(typed.last, '9000000001');
      // The Secret itself still renders as the marker wherever it is
      // interpolated, which is what keeps it out of a report.
      expect('${const Secret('9000000001')}', redactionMarker);
    });

    test('an empty value is still a value', () async {
      final runner = FakeRunner();
      await _controller(runner).inputText('');
      expect(runner.calls.any((c) => c.contains('text')), isTrue);
    });

    test('spaces are escaped, and nothing else is dropped', () async {
      final runner = FakeRunner();
      await _controller(runner).inputText('ab cd');
      final typed = runner.calls.firstWhere((c) => c.contains('text'));
      expect(typed.last, 'ab%scd');
    });
  });
}
