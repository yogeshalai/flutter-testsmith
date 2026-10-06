import 'package:test/test.dart';
import 'package:flutter_testsmith/protocol.dart';

void main() {
  group('ProtocolVersion.parse', () {
    test('parses a major.minor string', () {
      final v = ProtocolVersion.parse('1.4');
      expect(v.major, 1);
      expect(v.minor, 4);
    });

    test('rejects a string that is not major.minor', () {
      expect(() => ProtocolVersion.parse('1'), throwsFormatException);
      expect(() => ProtocolVersion.parse('1.2.3'), throwsFormatException);
      expect(() => ProtocolVersion.parse('x.y'), throwsFormatException);
      expect(() => ProtocolVersion.parse(''), throwsFormatException);
    });

    test('round-trips through its string form', () {
      expect(ProtocolVersion.parse('2.7').value, '2.7');
    });
  });

  group('compatibility', () {
    test('accepts a differing minor version', () {
      const engine = ProtocolVersion(1, 0);
      const sdk = ProtocolVersion(1, 9);
      expect(engine.isCompatibleWith(sdk), isTrue);
    });

    test('rejects a differing major version', () {
      const engine = ProtocolVersion(1, 0);
      const sdk = ProtocolVersion(2, 0);
      expect(engine.isCompatibleWith(sdk), isFalse);
    });
  });

  test('current version is exposed as a constant', () {
    expect(ProtocolVersion.current.value, isNotEmpty);
    expect(ProtocolVersion.current.major, greaterThanOrEqualTo(1));
  });
}
