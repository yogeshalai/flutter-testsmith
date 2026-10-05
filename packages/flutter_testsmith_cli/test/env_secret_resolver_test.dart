// `DotEnv` already establishes the precedence rule - the real
// environment always wins, so CI is never overridden by a developer's
// local file that happened to reach a branch. The resolver inherits it
// rather than inventing a second one.

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/dotenv.dart';
import 'package:flutter_testsmith_cli/src/secrets/env_secret_resolver.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

SecretRef _ref(String raw) => SecretRef.parse(raw, source: 'test');

void main() {
  test('resolves from the process environment', () {
    final resolver = EnvSecretResolver(
      environment: {'MYTEST_AUTH_PIN': 'SEEDED_PIN_9f2a41c8'},
    );
    expect(
      resolver.resolve(_ref('env:MYTEST_AUTH_PIN')).expose(),
      'SEEDED_PIN_9f2a41c8',
    );
  });

  test('falls back to the .env file', () {
    final resolver = EnvSecretResolver(
      environment: const {},
      dotenv: DotEnv(DotEnv.parse('MYTEST_AUTH_PIN=FROM_FILE')),
    );
    expect(resolver.resolve(_ref('env:MYTEST_AUTH_PIN')).expose(), 'FROM_FILE');
  });

  test('the real environment wins over the file', () {
    final resolver = EnvSecretResolver(
      environment: {'MYTEST_AUTH_PIN': 'FROM_ENV'},
      dotenv: DotEnv(DotEnv.parse('MYTEST_AUTH_PIN=FROM_FILE')),
    );
    expect(resolver.resolve(_ref('env:MYTEST_AUTH_PIN')).expose(), 'FROM_ENV');
  });

  test('isPresent is true when set and false when absent or empty', () {
    final resolver = EnvSecretResolver(
      environment: {'SET': 'x', 'EMPTY': ''},
    );
    expect(resolver.isPresent(_ref('env:SET')), isTrue);
    expect(resolver.isPresent(_ref('env:EMPTY')), isFalse);
    expect(resolver.isPresent(_ref('env:ABSENT')), isFalse);
  });

  test('resolving an absent reference throws, naming only the reference', () {
    final resolver = EnvSecretResolver(environment: const {});
    expect(
      () => resolver.resolve(_ref('env:MYTEST_AUTH_PIN')),
      throwsA(
        isA<MissingSecretException>().having(
          (e) => '$e',
          'message',
          allOf(contains('env:MYTEST_AUTH_PIN'), isNot(contains('='))),
        ),
      ),
    );
  });
}
