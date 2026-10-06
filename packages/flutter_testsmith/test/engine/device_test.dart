import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/protocol.dart';

/// Records commands and replays canned results, so command construction can
/// be asserted without a device attached.
class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner({this.results = const {}});

  final Map<String, ProcessResultData> results;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<ProcessResultData> run(
    String executable,
    List<String> arguments,
  ) async {
    calls.add([executable, ...arguments]);
    final key = arguments.join(' ');
    for (final entry in results.entries) {
      if (key.contains(entry.key)) return entry.value;
    }
    return const ProcessResultData(exitCode: 0, stdout: '', stderr: '');
  }

  List<String> get lastCall => calls.last;
  String get lastCommand => calls.last.join(' ');
}

const String serial = 'RZ8T11QETWM';

/// The adb these tests assert against.
///
/// Named explicitly, because the default is now located from the
/// environment: `ANDROID_HOME` on the machine running the suite decides
/// it, and a unit test about *command construction* must not depend on
/// which Android SDK happens to be installed. Naming one is also the
/// behaviour every caller with an opinion relies on.
const String adbExecutable = 'adb';

AdbDeviceController controller(FakeProcessRunner runner) => AdbDeviceController(
      serial: serial,
      processRunner: runner,
      adbExecutable: adbExecutable,
    );

void main() {
  group('logical to physical conversion', () {
    test('scales by the device pixel ratio', () {
      // The whole point of routing every conversion through one function:
      // on this device the ratio is 1.875, so an unconverted coordinate is
      // wrong by nearly half a screen.
      final space = CoordinateSpace(devicePixelRatio: 1.875);

      expect(space.toPhysical(100), 188);
      expect(space.toPhysical(0), 0);
      expect(space.toPhysical(384), 720);
    });

    test('rounds to the nearest whole pixel', () {
      final space = CoordinateSpace(devicePixelRatio: 1.875);

      // 10 * 1.875 = 18.75
      expect(space.toPhysical(10), 19);
      // 12 * 1.875 = 22.5
      expect(space.toPhysical(12), 23);
    });

    test('converts back to logical', () {
      final space = CoordinateSpace(devicePixelRatio: 2);
      expect(space.toLogical(200), 100);
    });

    test('finds the physical centre of a logical rectangle', () {
      final space = CoordinateSpace(devicePixelRatio: 1.875);

      final centre = space.centreOf(
        const LogicalRect(x: 32, y: 420, width: 300, height: 28),
      );

      // Centre in logical space is (182, 434).
      expect(centre.x, 341); // 182 * 1.875 = 341.25
      expect(centre.y, 814); // 434 * 1.875 = 813.75
    });

    test('rejects a non-positive device pixel ratio', () {
      // A zero ratio would silently collapse every coordinate to the origin.
      expect(() => CoordinateSpace(devicePixelRatio: 0), throwsArgumentError);
      expect(() => CoordinateSpace(devicePixelRatio: -1), throwsArgumentError);
    });
  });

  group('AdbDeviceController command construction', () {
    test('targets the serial on every command', () async {
      final runner = FakeProcessRunner();

      await controller(runner).pressBack();

      expect(runner.lastCall.take(3), [adbExecutable, '-s', serial]);
    });

    test('taps using physical coordinates', () async {
      final runner = FakeProcessRunner();

      await controller(runner).tap(const PhysicalPoint(341, 814));

      expect(runner.lastCommand, endsWith('shell input tap 341 814'));
    });

    test('clears the application state when a suite asks it to', () async {
      // Explicit, never implied. A suite that wiped the device between
      // every test would spend its life re-signing-in, and each test's
      // real precondition would become invisible.
      final runner = FakeProcessRunner();

      await controller(runner).clearAppState('com.example.app');

      expect(runner.lastCommand, endsWith('shell pm clear com.example.app'));
    });

    test('grants a permission', () async {
      // Clearing state also revokes what the user granted, and the
      // resulting system permission dialog is drawn over the
      // application - so a tap meant for a button lands on the dialog
      // instead. Measured on the real device.
      final runner = FakeProcessRunner();

      await controller(runner).grantPermission(
        'com.example.app',
        'android.permission.POST_NOTIFICATIONS',
      );

      expect(
        runner.lastCommand,
        endsWith(
          'shell pm grant com.example.app android.permission.POST_NOTIFICATIONS',
        ),
      );
    });

    test('long-presses with an explicit duration', () async {
      final runner = FakeProcessRunner();

      await controller(runner).longPress(
        const PhysicalPoint(100, 200),
        const Duration(milliseconds: 800),
      );

      expect(
        runner.lastCommand,
        endsWith('shell input swipe 100 200 100 200 800'),
      );
    });

    test('swipes between two points over a duration', () async {
      final runner = FakeProcessRunner();

      await controller(runner).swipe(
        const PhysicalPoint(10, 20),
        const PhysicalPoint(30, 40),
        const Duration(milliseconds: 300),
      );

      expect(runner.lastCommand, endsWith('shell input swipe 10 20 30 40 300'));
    });

    test('sends the back key', () async {
      final runner = FakeProcessRunner();

      await controller(runner).pressBack();

      expect(runner.lastCommand, endsWith('shell input keyevent KEYCODE_BACK'));
    });

    test('reverses a port so a device can reach a host-run server',
        () async {
      // A physical device cannot use 10.0.2.2 the way an emulator does.
      final runner = FakeProcessRunner();

      await controller(runner).reversePort(8080, 8080);

      expect(runner.lastCommand, endsWith('reverse tcp:8080 tcp:8080'));
    });

    test('removes the reverse again, so a run leaves no port forwarded',
        () async {
      // Symmetric with reversePort and called from the same place. A
      // device still forwarding a port to a host that stopped listening
      // is state one run leaves for the next, and a run whose behaviour
      // depends on whether a previous run happened is not deterministic.
      final runner = FakeProcessRunner();

      await controller(runner).removeReversePort(8080);

      expect(runner.lastCommand, endsWith('reverse --remove tcp:8080'));
    });

    test('wakes and unlocks, because a physical device sleeps mid-run',
        () async {
      final runner = FakeProcessRunner();

      await controller(runner).wake();

      final commands = runner.calls.map((c) => c.join(' ')).toList();
      expect(commands.any((c) => c.contains('KEYCODE_WAKEUP')), isTrue);
      expect(commands.any((c) => c.contains('KEYCODE_MENU')), isTrue);
    });

    test('terminates an app by package id', () async {
      final runner = FakeProcessRunner();

      await controller(runner).terminateApp('com.example.shop');

      expect(runner.lastCommand, endsWith('shell am force-stop com.example.shop'));
    });
  });

  group('AdbDeviceController results', () {
    test('reads device info from getprop and wm', () async {
      final runner = FakeProcessRunner(results: {
        'ro.product.model': const ProcessResultData(
          exitCode: 0,
          stdout: 'SM-M127G\n',
          stderr: '',
        ),
        'ro.build.version.release': const ProcessResultData(
          exitCode: 0,
          stdout: '13\n',
          stderr: '',
        ),
        'wm size': const ProcessResultData(
          exitCode: 0,
          stdout: 'Physical size: 720x1600\n',
          stderr: '',
        ),
        'wm density': const ProcessResultData(
          exitCode: 0,
          stdout: 'Physical density: 300\n',
          stderr: '',
        ),
      });

      final info = await controller(runner).info();

      expect(info.serial, serial);
      expect(info.model, 'SM-M127G');
      expect(info.androidVersion, '13');
      expect(info.screenWidth, 720);
      expect(info.screenHeight, 1600);
      expect(info.density, 300);
    });

    test('returns screenshot bytes from screencap', () async {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      final runner = FakeProcessRunner(results: {
        'screencap': ProcessResultData(
          exitCode: 0,
          stdout: '',
          stderr: '',
          stdoutBytes: png,
        ),
      });

      final bytes = await controller(runner).screenshot();

      expect(bytes, png);
    });

    test('fails with the command and stderr when adb reports an error',
        () async {
      // A bare "adb failed" would be useless; the diagnostic has to say
      // which command and what the device said.
      final runner = FakeProcessRunner(results: {
        'input tap': const ProcessResultData(
          exitCode: 1,
          stdout: '',
          stderr: 'error: device unauthorized',
        ),
      });

      await expectLater(
        controller(runner).tap(const PhysicalPoint(1, 2)),
        throwsA(
          isA<DeviceCommandException>()
              .having((e) => e.toString(), 'message', contains('input tap'))
              .having(
                (e) => e.toString(),
                'message',
                contains('device unauthorized'),
              ),
        ),
      );
    });
  });

  // adb that will not launch at all.
  //
  // `_adb` turned a non-zero exit into a DeviceCommandException and let a
  // failure to *start* adb straight out, so `testsmith inspect --device X`
  // exited 255 with a stack trace and `testsmith smoke --device X` printed
  // the raw ProcessException text. The command was never sent, so there is
  // no exit code to report and DeviceCommandException cannot say this
  // honestly.
  group('adb is not installed', () {
    test('a device command reports it instead of crashing', () async {
      final device = AdbDeviceController(
        serial: serial,
        processRunner: _MissingAdb(),
        adbExecutable: adbExecutable,
      );

      await expectLater(
        device.wake(),
        throwsA(isA<DeviceUnavailableException>()),
      );
    });

    test('and says so without quoting the launch failure', () async {
      final device = AdbDeviceController(
        serial: serial,
        processRunner: _MissingAdb(),
        adbExecutable: r'C:\Users\somebody\Sdk\platform-tools\adb.exe',
      );

      try {
        await device.wake();
        fail('expected a DeviceUnavailableException');
      } on DeviceUnavailableException catch (error) {
        expect('$error'.toLowerCase(), contains('adb'));
        expect('$error', isNot(contains('ProcessException')));
        // The same rule `_displayName` already applies: a report must
        // not carry somebody's home directory.
        expect('$error', isNot(contains('somebody')));
      }
    });

    test('a non-zero exit is still a command failure, not a missing adb',
        () async {
      final runner = FakeProcessRunner(results: {
        'input keyevent': const ProcessResultData(
          exitCode: 1,
          stdout: '',
          stderr: 'error: device offline',
        ),
      });

      await expectLater(
        controller(runner).wake(),
        throwsA(isA<DeviceCommandException>()),
      );
    });
  });
}

/// An adb that cannot be launched at all.
class _MissingAdb implements ProcessRunner {
  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) =>
      throw ProcessException(
        executable,
        arguments,
        'The system cannot find the file specified',
        2,
      );
}
