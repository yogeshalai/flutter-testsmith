import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  const policy = RedactionPolicy.strictDefaults();

  group('sensitive key detection', () {
    test('catches the obvious credential names', () {
      for (final key in [
        'authorization',
        'password',
        'token',
        'access_token',
        'refreshToken',
        'api-key',
        'apiKey',
        'cookie',
        'set-cookie',
        'cardNumber',
        'cvv',
        'pin',
        'otp',
      ]) {
        expect(policy.isSensitive(key), isTrue, reason: 'missed "$key"');
      }
    });

    test('is insensitive to case and to separators', () {
      // Real payloads mix camelCase, snake_case and kebab-case freely.
      for (final key in [
        'Authorization',
        'ACCESS_TOKEN',
        'access-token',
        'accessToken',
        'Access_Token',
      ]) {
        expect(policy.isSensitive(key), isTrue, reason: 'missed "$key"');
      }
    });

    test('catches an unlisted key that looks like a credential', () {
      // Allow-by-exception: a field nobody thought to list is still
      // redacted if it reads like a secret.
      expect(policy.isSensitive('stripeSecretKey'), isTrue);
      expect(policy.isSensitive('user_password_hash'), isTrue);
      expect(policy.isSensitive('sessionToken'), isTrue);
    });

    test('does not redact ordinary fields that merely contain a substring',
        () {
      // Over-redaction is cheap but not free: a report full of
      // [REDACTED] where the data was harmless is a report nobody reads.
      for (final key in [
        'author',
        'authorName',
        'keyboard',
        'monkey',
        'description',
        'pinned',
        'name',
        'price',
        'available',
      ]) {
        expect(policy.isSensitive(key), isFalse, reason: 'over-redacted "$key"');
      }
    });

    test('an explicit allowance wins over the default rules', () {
      const relaxed = RedactionPolicy(
        sensitiveKeys: {'token'},
        allowedKeys: {'token'},
      );

      expect(relaxed.isSensitive('token'), isFalse);
    });
  });

  group('redacting headers', () {
    test('replaces sensitive values and keeps the rest', () {
      final redacted = policy.redactHeaders({
        'Authorization': 'Bearer sk_live_abc123',
        'Content-Type': 'application/json',
        'Cookie': 'session=xyz',
      });

      expect(redacted['Authorization'], RedactionPolicy.marker);
      expect(redacted['Cookie'], RedactionPolicy.marker);
      expect(redacted['Content-Type'], 'application/json');
    });

    test('keeps the header name, so its presence is still visible', () {
      // Knowing a request was authenticated matters; knowing the token
      // does not.
      final redacted = policy.redactHeaders({'authorization': 'Bearer x'});

      expect(redacted.keys, contains('authorization'));
    });
  });

  group('redacting a JSON body', () {
    test('replaces sensitive values at the top level', () {
      final redacted = policy.redactJson({
        'username': 'yogesh',
        'password': 'hunter2',
      });

      expect(redacted, {
        'username': 'yogesh',
        'password': RedactionPolicy.marker,
      });
    });

    test('reaches nested objects', () {
      final redacted = policy.redactJson({
        'user': {
          'name': 'Yogesh',
          'profile': {'apiKey': 'sk_live_abc', 'city': 'Pune'},
        },
      });

      final profile = (redacted['user']! as Map)['profile']! as Map;
      expect(profile['apiKey'], RedactionPolicy.marker);
      expect(profile['city'], 'Pune');
      expect((redacted['user']! as Map)['name'], 'Yogesh');
    });

    test('redacts a whole object whose own name reads as a credential', () {
      // Descending into a container called "credentials" and redacting
      // only the leaves it recognises would leak any field nobody
      // thought to list. Dropping the container is the safer default.
      final redacted = policy.redactJson({
        'credentials': {'unlistedFieldName': 'sk_live_abc'},
        'name': 'Nike',
      });

      expect(redacted['credentials'], RedactionPolicy.marker);
      expect(redacted['name'], 'Nike');
    });

    test('reaches inside lists', () {
      final redacted = policy.redactJson({
        'cards': [
          {'cardNumber': '4111111111111111', 'last4': '1111'},
        ],
      });

      final card = (redacted['cards']! as List).first as Map;
      expect(card['cardNumber'], RedactionPolicy.marker);
      expect(card['last4'], '1111');
    });

    test('leaves a body with nothing sensitive untouched', () {
      final body = {'name': 'Nike Air Max', 'price': 2999, 'available': false};

      expect(policy.redactJson(body), body);
    });

    test('redacts a string body by parsing it', () {
      final redacted = policy.redactBodyString(
        '{"password":"hunter2","name":"x"}',
      );

      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, contains('"name":"x"'));
    });

    test('redacts a non-JSON body wholesale rather than guessing', () {
      // An unparseable body cannot be inspected key by key, so it cannot
      // be shown to be safe. Dropping it is the conservative choice.
      final redacted = policy.redactBodyString('user=admin&password=hunter2');

      expect(redacted, isNot(contains('hunter2')));
    });

    test('keeps a plain non-JSON body when nothing looks sensitive', () {
      expect(policy.redactBodyString('plain text response'),
          'plain text response');
    });
  });

  group('endpoint exclusion', () {
    test('skips capture entirely for an excluded endpoint', () {
      // Some endpoints should never be recorded at all, whatever
      // redaction would do to them.
      const strict = RedactionPolicy(
        sensitiveKeys: {},
        excludedPaths: {'/auth/login', '/payments'},
      );

      expect(strict.shouldCapture(Uri.parse('https://x.com/auth/login')),
          isFalse);
      expect(strict.shouldCapture(Uri.parse('https://x.com/payments/card')),
          isFalse);
      expect(strict.shouldCapture(Uri.parse('https://x.com/products/1')),
          isTrue);
    });

    test('captures everything by default', () {
      expect(policy.shouldCapture(Uri.parse('https://x.com/anything')), isTrue);
    });
  });

  group('body truncation', () {
    test('cuts an oversized body and reports that it did', () {
      final result = truncateBody('0123456789', maxBytes: 4);

      expect(result.body, '0123');
      expect(result.truncated, isTrue);
    });

    test('leaves a body within the limit alone', () {
      final result = truncateBody('short', maxBytes: 100);

      expect(result.body, 'short');
      expect(result.truncated, isFalse);
    });

    test('handles a null body', () {
      final result = truncateBody(null, maxBytes: 10);

      expect(result.body, isNull);
      expect(result.truncated, isFalse);
    });

    test('a zero limit drops the body but records the truncation', () {
      final result = truncateBody('anything', maxBytes: 0);

      expect(result.body, isEmpty);
      expect(result.truncated, isTrue);
    });
  });
}
