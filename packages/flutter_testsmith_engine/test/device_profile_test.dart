import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// The runtime environment a baseline belongs to.
///
/// A serial number is not it. `RZ8T11QETWM` identifies the handset on
/// this desk, not the conditions a picture was recorded under, and
/// binding a baseline to it would mean the baseline could only ever be
/// checked on the machine that took it.
///
/// What actually makes two runs comparable is the model, the OS, the
/// resolution, the pixel ratio, the orientation and the build mode. That
/// is what a profile names, and it is stable across devices of the same
/// kind.
const String _yaml = '''
id: samsung-m127g
model: SM-M127G
os: Android 13
physical:
  width: 720
  height: 1600
devicePixelRatio: 1.875
orientation: portrait
buildMode: debug
''';

DeviceProfile parse(String yaml) =>
    DeviceProfile.parse(yaml, source: 'test.yaml');

void main() {
  group('parsing', () {
    test('reads every declared field', () {
      final profile = parse(_yaml);

      expect(profile.id, 'samsung-m127g');
      expect(profile.model, 'SM-M127G');
      expect(profile.os, 'Android 13');
      expect(profile.physicalWidth, 720);
      expect(profile.physicalHeight, 1600);
      expect(profile.devicePixelRatio, 1.875);
      expect(profile.orientation, DeviceOrientation.portrait);
      expect(profile.buildMode, 'debug');
    });

    test('derives the logical viewport from the physical size', () {
      // Stated rather than declared: two numbers that must agree are one
      // number and an opportunity to get it wrong.
      final profile = parse(_yaml);

      expect(profile.logicalWidth, closeTo(384, 0.01));
      expect(profile.logicalHeight, closeTo(853.33, 0.01));
    });

    test('rejects a profile with no id', () {
      expect(
        () => parse('model: SM-M127G\n'),
        throwsA(isA<ProfileFormatException>()),
      );
    });

    test('rejects an unknown key rather than ignoring it', () {
      // A typo that is silently ignored is a setting that silently does
      // nothing.
      expect(
        () => parse('$_yaml\nresolutions: 720x1600\n'),
        throwsA(
          isA<ProfileFormatException>().having(
            (e) => e.toString(),
            'message',
            contains('resolutions'),
          ),
        ),
      );
    });

    test('rejects a non-positive dimension', () {
      expect(
        () => parse('id: x\nphysical:\n  width: 0\n  height: 100\n'),
        throwsA(isA<ProfileFormatException>()),
      );
    });
  });

  group('identity', () {
    test('is the declared id, not the serial', () {
      // The serial is not a field a profile has. This asserts the
      // absence, because the whole point is that it cannot leak in.
      final profile = parse(_yaml);

      expect(profile.id, 'samsung-m127g');
      expect(profile.toJson().keys, isNot(contains('device')));
      expect(profile.toJson().keys, isNot(contains('serial')));
    });

    test('two profiles with the same id are the same profile', () {
      expect(parse(_yaml), parse(_yaml));
    });
  });

  group('verification against a connected device', () {
    test('accepts a device that matches', () {
      final mismatches = parse(_yaml).mismatchesAgainst(
        const DeviceFacts(
          model: 'SM-M127G',
          os: 'Android 13',
          physicalWidth: 720,
          physicalHeight: 1600,
          devicePixelRatio: 1.875,
          buildMode: 'debug',
        ),
      );

      expect(mismatches, isEmpty);
    });

    test('reports a different model', () {
      final mismatches = parse(_yaml).mismatchesAgainst(
        const DeviceFacts(model: 'Pixel 7', os: 'Android 13'),
      );

      expect(mismatches, contains(contains('model')));
    });

    test('reports a different resolution and pixel ratio', () {
      final mismatches = parse(_yaml).mismatchesAgainst(
        const DeviceFacts(
          model: 'SM-M127G',
          physicalWidth: 1080,
          physicalHeight: 2400,
          devicePixelRatio: 3,
        ),
      );

      expect(mismatches, hasLength(2));
      expect(mismatches.join(' '), contains('1080'));
      expect(mismatches.join(' '), contains('3'));
    });

    test('says nothing about a fact the device did not report', () {
      // A runner that cannot read the OS must not turn that into a
      // mismatch; it has learned nothing, which is different from
      // learning a disagreement.
      final mismatches = parse(_yaml).mismatchesAgainst(
        const DeviceFacts(model: 'SM-M127G'),
      );

      expect(mismatches, isEmpty);
    });
  });
}
