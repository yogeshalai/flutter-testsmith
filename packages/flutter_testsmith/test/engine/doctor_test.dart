import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

void main() {
  group('DoctorCheck', () {
    test('passes with a version string', () {
      const check = DoctorCheck.pass('Flutter', detail: '3.44.7');

      expect(check.status, CheckStatus.pass);
      expect(check.isBlocking, isFalse);
    });

    test('a failure carries a remedy, not just a complaint', () {
      // A doctor that says "adb not found" without saying what to do is
      // just a slower error message.
      const check = DoctorCheck.fail(
        'adb',
        detail: 'not on PATH',
        remedy: 'Install Android platform-tools and add it to PATH',
      );

      expect(check.status, CheckStatus.fail);
      expect(check.isBlocking, isTrue);
      expect(check.remedy, isNotEmpty);
    });

    test('a warning does not block', () {
      const check = DoctorCheck.warn('Emulator', detail: 'no AVD configured');

      expect(check.status, CheckStatus.warn);
      expect(check.isBlocking, isFalse);
    });
  });

  group('DoctorReport', () {
    test('is healthy when nothing failed', () {
      const report = DoctorReport([
        DoctorCheck.pass('Flutter', detail: '3.44.7'),
        DoctorCheck.warn('Emulator', detail: 'no AVD'),
      ]);

      expect(report.isHealthy, isTrue);
      expect(report.exitCode, 0);
    });

    test('is unhealthy and exits non-zero when something failed', () {
      const report = DoctorReport([
        DoctorCheck.pass('Flutter', detail: '3.44.7'),
        DoctorCheck.fail('adb', detail: 'missing', remedy: 'install it'),
      ]);

      expect(report.isHealthy, isFalse);
      expect(report.exitCode, 1);
      expect(report.failures.map((DoctorCheck c) => c.name), ['adb']);
    });

    test('counts each status', () {
      const report = DoctorReport([
        DoctorCheck.pass('a'),
        DoctorCheck.pass('b'),
        DoctorCheck.warn('c'),
        DoctorCheck.fail('d', remedy: 'x'),
      ]);

      expect(report.passCount, 2);
      expect(report.warnCount, 1);
      expect(report.failCount, 1);
    });

    test('an empty report is healthy but says nothing was checked', () {
      const report = DoctorReport([]);

      expect(report.isHealthy, isTrue);
      expect(report.checks, isEmpty);
    });
  });

  group('parsing adb devices output', () {
    test('reads attached devices with their model', () {
      const output = '''
List of devices attached
RZ8T11QETWM            device product:m12dd model:SM_M127G device:m12 transport_id:2
emulator-5554          device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64x transport_id:1
''';

      final devices = parseAdbDevices(output);

      expect(devices, hasLength(2));
      expect(devices.first.serial, 'RZ8T11QETWM');
      expect(devices.first.model, 'SM_M127G');
      expect(devices.first.isEmulator, isFalse);
      expect(devices.last.isEmulator, isTrue);
    });

    test('returns nothing when no device is attached', () {
      expect(parseAdbDevices('List of devices attached\n\n'), isEmpty);
    });

    test('skips devices that are not ready', () {
      // An unauthorised or offline device would fail confusingly later.
      const output = '''
List of devices attached
ABC123                 unauthorized
DEF456                 offline
GHI789                 device model:Pixel_7
''';

      final devices = parseAdbDevices(output);

      expect(devices.map((AdbDevice d) => d.serial), ['GHI789']);
    });

    test('reports a device with no model rather than dropping it', () {
      const output = '''
List of devices attached
XYZ999                 device
''';

      final devices = parseAdbDevices(output);

      expect(devices.single.serial, 'XYZ999');
      expect(devices.single.model, isNotEmpty);
    });
  });
}
