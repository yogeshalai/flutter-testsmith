import 'package:test/test.dart';
// Deliberately imports the neutral path only. If this file ever needs an
// `auth/` import to compile, the primitive is not neutral.
import 'package:flutter_testsmith_engine/src/secrets/secret_ref.dart';

void main() {
  test('a secret reference parses without any authentication code', () {
    final ref = SecretRef.parse('env:EXAMPLE_API_TOKEN', source: 'test');
    expect(ref.scheme, 'env');
    expect(ref.name, 'EXAMPLE_API_TOKEN');
  });

  test('a literal credential is refused', () {
    expect(
      () => SecretRef.parse('sk-live-abc123', source: 'test'),
      throwsA(isA<SecretRefFormatException>()),
    );
  });

  test('a resolved secret renders as the redaction marker', () {
    expect(const Secret('hunter2').toString(), redactionMarker);
    expect(const Secret('hunter2').expose(), 'hunter2');
  });
}
