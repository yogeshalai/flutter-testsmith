// The type split the whole milestone rests on: a reference is allowed to
// travel, a value is not. These tests are about the *rendering* of each,
// because rendering is how a credential actually escapes in practice -
// through a message somebody interpolated in a hurry.

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Records every reference it was asked about, and whether it was ever
/// asked for a value.
class RecordingResolver implements SecretResolver {
  RecordingResolver(this._values);

  final Map<String, String> _values;
  final List<SecretRef> presenceChecks = [];
  final List<SecretRef> resolutions = [];

  @override
  bool isPresent(SecretRef ref) {
    presenceChecks.add(ref);
    return (_values[ref.name] ?? '').isNotEmpty;
  }

  @override
  Secret resolve(SecretRef ref) {
    resolutions.add(ref);
    final value = _values[ref.name];
    if (value == null || value.isEmpty) throw MissingSecretException(ref);
    return Secret(value);
  }
}

void main() {
  group('SecretRef.parse', () {
    test('reads scheme and name', () {
      final ref = SecretRef.parse('env:MYTEST_AUTH_PIN', source: 'auth.yaml');
      expect(ref.scheme, 'env');
      expect(ref.name, 'MYTEST_AUTH_PIN');
      expect(ref.toString(), 'env:MYTEST_AUTH_PIN');
    });

    test('a bare value is refused, because it would be a literal credential',
        () {
      expect(
        () => SecretRef.parse('1234', source: 'auth.yaml'),
        throwsA(isA<SecretRefFormatException>()),
      );
    });

    test('an unknown scheme is refused, naming the one that is known', () {
      // This used to assert the message repeated "vault". It no longer
      // does, on purpose: the "scheme" is whatever precedes the first
      // colon, and for a literal credential that contains one it is the
      // front of the credential. Nothing can tell `vault:PIN` from
      // `hunter2:abc`, so neither is repeated.
      expect(
        () => SecretRef.parse('vault:PIN', source: 'auth.yaml'),
        throwsA(
          isA<SecretRefFormatException>()
              .having((e) => e.message, 'message',
                  contains('unknown secret scheme'))
              .having((e) => e.message, 'message', contains('Known: env'))
              .having((e) => e.message, 'message', isNot(contains('vault'))),
        ),
      );
    });

    group('never repeats the value it was given', () {
      // AUTH-SECRET-DISCLOSURE. A reference that is not one is, as often
      // as not, the credential itself, pasted where its name belongs.
      // Measured at c24656b: `"<value>" is not a secret reference` - the
      // literal, printed back by the check that exists to keep literals
      // out of files, on a console and into CI logs.
      const sentinel = 'SUPER_SECRET_SENTINEL_DO_NOT_PRINT';

      Matcher refusedWithout(List<String> fragments, String reason) =>
          throwsA(
            isA<SecretRefFormatException>()
                .having((e) => e.message, 'message', contains(reason))
                .having((e) => e.source, 'source', 'auth.yaml')
                .having(
                  (e) => '$e',
                  'rendering',
                  allOf([for (final f in fragments) isNot(contains(f))]),
                ),
          );

      test('a bare literal', () {
        expect(
          () => SecretRef.parse(sentinel, source: 'auth.yaml'),
          refusedWithout([sentinel], 'is not a secret reference'),
        );
      });

      test('a literal with a colon in it, either half', () {
        expect(
          () => SecretRef.parse('SUPER_SECRET:SENTINEL_DO_NOT_PRINT',
              source: 'auth.yaml'),
          refusedWithout(
            ['SUPER_SECRET', 'SENTINEL_DO_NOT_PRINT'],
            'unknown secret scheme',
          ),
        );
      });

      test('still says how to write one', () {
        expect(
          () => SecretRef.parse(sentinel, source: 'auth.yaml'),
          throwsA(isA<SecretRefFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"<scheme>:<name>"'),
                contains('A literal credential is never accepted')),
          )),
        );
      });
    });

    test('a scheme with no name is refused', () {
      expect(
        () => SecretRef.parse('env:', source: 'auth.yaml'),
        throwsA(isA<SecretRefFormatException>()),
      );
    });

    test('equal references compare equal', () {
      expect(
        SecretRef.parse('env:A', source: 's'),
        SecretRef.parse('env:A', source: 's'),
      );
    });
  });

  group('Secret', () {
    test('interpolating one yields the marker, not the value', () {
      const secret = Secret('SEEDED_PIN_9f2a41c8');
      expect('$secret', redactionMarker);
      expect(secret.toString(), isNot(contains('SEEDED_PIN_9f2a41c8')));
    });

    test('a message built from one carries no credential', () {
      const secret = Secret('SEEDED_PIN_9f2a41c8');
      final message = 'could not type $secret into the field';
      expect(message, isNot(contains('SEEDED_PIN_9f2a41c8')));
      expect(message, contains(redactionMarker));
    });

    test('expose is the only way to the value', () {
      const secret = Secret('SEEDED_PIN_9f2a41c8');
      expect(secret.expose(), 'SEEDED_PIN_9f2a41c8');
    });
  });

  group('MissingSecretException', () {
    test('names the reference and nothing else', () {
      final error =
          MissingSecretException(SecretRef.parse('env:PIN', source: 's'));
      expect('$error', contains('env:PIN'));
      expect('$error', contains('PIN'));
    });
  });

  group('presence is checked without reading', () {
    test('isPresent answers without ever resolving', () {
      final resolver = RecordingResolver({'PIN': '1234'});
      final ref = SecretRef.parse('env:PIN', source: 's');

      expect(resolver.isPresent(ref), isTrue);
      expect(resolver.presenceChecks, [ref]);
      expect(
        resolver.resolutions,
        isEmpty,
        reason: 'a presence check must not pull the value into the process',
      );
    });

    test('an empty value is not present', () {
      final resolver = RecordingResolver({'PIN': ''});
      expect(
        resolver.isPresent(SecretRef.parse('env:PIN', source: 's')),
        isFalse,
      );
    });
  });
}
