import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/dotenv.dart';

void main() {
  group('DotEnv.parse', () {
    test('reads key and value pairs', () {
      final values = DotEnv.parse('GROQ_API_KEY=abc123\nFIGMA_TOKEN=xyz\n');

      expect(values['GROQ_API_KEY'], 'abc123');
      expect(values['FIGMA_TOKEN'], 'xyz');
    });

    test('ignores blank lines and comments', () {
      final values = DotEnv.parse('\n# a comment\n\nA=1\n');

      expect(values, {'A': '1'});
    });

    test('keeps an "=" inside a value', () {
      // Base64 secrets end in padding. Splitting on every "=" would
      // silently truncate them.
      final values = DotEnv.parse('TOKEN=abc==\n');

      expect(values['TOKEN'], 'abc==');
    });

    test('strips quotes people add out of habit', () {
      final values = DotEnv.parse('A="one"\nB=\'two\'\n');

      expect(values['A'], 'one');
      expect(values['B'], 'two');
    });

    test('skips a line with no key', () {
      expect(DotEnv.parse('=orphan\nA=1\n'), {'A': '1'});
    });

    test('exposes names but never values', () {
      // `doctor` says what is configured; it must not print a secret.
      const env = DotEnv({'GROQ_API_KEY': 'secret', 'A': 'b'});

      expect(env.names, ['A', 'GROQ_API_KEY']);
      expect(env.names.join(), isNot(contains('secret')));
    });
  });

  group('precedence', () {
    test('the real environment wins over the file', () {
      // CI sets variables properly; a stray committed .env must not
      // override them.
      const env = DotEnv({'PATH': 'from-file'});

      expect(env['PATH'], isNot('from-file'));
    });

    test('the file supplies what the environment does not', () {
      const env = DotEnv({'A_VARIABLE_NOBODY_EXPORTS': 'from-file'});

      expect(env['A_VARIABLE_NOBODY_EXPORTS'], 'from-file');
    });

    test('an unknown name is null', () {
      expect(const DotEnv.empty()['NOT_SET_ANYWHERE_X'], isNull);
    });
  });
}
