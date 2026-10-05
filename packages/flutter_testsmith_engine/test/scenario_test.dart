import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

ApiScenario parse(String json) => ApiScenario.parse(json, source: 'test.json');

void main() {
  group('parsing', () {
    test('reads a route into a status and a body', () {
      final scenario = parse('''
{
  "name": "happy",
  "routes": {
    "GET /products/123": { "status": 200, "body": { "price": 90 } }
  }
}
''');

      final route = scenario.match('GET', '/products/123')!;
      expect(route.status, 200);
      expect(route.bodyText, '{"price":90}');
      expect(route.delay, Duration.zero);
    });

    test('defaults a status to 200, because that is what a fixture is for',
        () {
      final scenario = parse('''
{ "name": "x", "routes": { "GET /cart": { "body": { "items": [] } } } }
''');

      expect(scenario.match('GET', '/cart')!.status, 200);
    });

    test('serves a raw body verbatim, so a malformed reply can be tested',
        () {
      final scenario = parse('''
{
  "name": "broken",
  "routes": {
    "GET /products/123": { "status": 200, "rawBody": "{not json" }
  }
}
''');

      expect(scenario.match('GET', '/products/123')!.bodyText, '{not json');
    });

    test('refuses a route that sets both body and rawBody', () {
      // Ambiguous: there is no defensible answer to "which one is sent?".
      expect(
        () => parse('''
{
  "name": "x",
  "routes": {
    "GET /a": { "body": {}, "rawBody": "y" }
  }
}
'''),
        throwsA(
          isA<ScenarioFormatException>().having(
            (e) => e.message,
            'message',
            contains('both "body" and "rawBody"'),
          ),
        ),
      );
    });

    test('refuses a route key that is not METHOD /path', () {
      expect(
        () => parse('{ "name": "x", "routes": { "/products": {} } }'),
        throwsA(
          isA<ScenarioFormatException>().having(
            (e) => e.message,
            'message',
            contains('METHOD /path'),
          ),
        ),
      );
    });

    test('refuses an unknown key rather than ignoring it', () {
      // A typo'd key that does nothing is how a fixture comes to serve
      // the default state under an edge-case name.
      expect(
        () => parse('''
{ "name": "x", "routes": { "GET /a": { "statusCode": 404 } } }
'''),
        throwsA(
          isA<ScenarioFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('statusCode'), contains('status')),
          ),
        ),
      );
    });

    test('refuses a negative delay', () {
      expect(
        () => parse(
          '{ "name": "x", "routes": { "GET /a": { "delayMs": -1 } } }',
        ),
        throwsA(isA<ScenarioFormatException>()),
      );
    });

    test('carries a delay, which is how a timeout is arranged', () {
      final scenario = parse('''
{ "name": "slow", "routes": { "GET /a": { "delayMs": 9000 } } }
''');

      expect(scenario.match('GET', '/a')!.delay, const Duration(seconds: 9));
    });

    test('carries headers', () {
      final scenario = parse('''
{
  "name": "x",
  "routes": {
    "GET /a": { "headers": { "x-trace": "abc" } }
  }
}
''');

      expect(scenario.match('GET', '/a')!.headers['x-trace'], 'abc');
    });

    // A value of the wrong *type*, as distinct from the unknown keys and
    // malformed routes above. `name` has always been checked and
    // `inherits` was a cast, so the same kind of slip in the same file
    // gave two answers: `generate` and `preflight` exited 255 with a
    // stack trace, while `suite run` exited 2 only because the broad
    // guard that milestone put at its step 5 happened to catch it.
    group('an "inherits" that is not a name', () {
      test('is refused, naming the field and the file', () {
        expect(
          () => parse('{ "name": "x", "inherits": 5, "routes": {} }'),
          throwsA(
            isA<ScenarioFormatException>()
                .having((e) => e.toString(), 'message', contains('inherits'))
                .having((e) => e.toString(), 'source', contains('test.json')),
          ),
        );
      });

      test('and a list is refused the same way', () {
        expect(
          () => parse('{ "name": "x", "inherits": ["a"], "routes": {} }'),
          throwsA(isA<ScenarioFormatException>()),
        );
      });
    });

    group('and what a wrong "inherits" must not change', () {
      test('a valid parent is still read', () {
        final scenario = parse(
          '{ "name": "x", "inherits": "base", "routes": {} }',
        );

        expect(scenario.inherits, 'base');
      });

      test('an absent "inherits" still means no parent', () {
        expect(parse('{ "name": "x", "routes": {} }').inherits, isNull);
      });

      test('an explicit null still means no parent', () {
        // The cast accepted this and so must the guard.
        expect(
          parse('{ "name": "x", "inherits": null, "routes": {} }').inherits,
          isNull,
        );
      });
    });
  });

  group('matching', () {
    test('matches a wildcard segment, so one route covers every id', () {
      final scenario = parse('''
{ "name": "x", "routes": { "GET /products/*": { "status": 404 } } }
''');

      expect(scenario.match('GET', '/products/999')!.status, 404);
      expect(scenario.match('GET', '/products/1/reviews'), isNull);
    });

    test('prefers an exact route over a wildcard', () {
      final scenario = parse('''
{
  "name": "x",
  "routes": {
    "GET /products/*": { "status": 404 },
    "GET /products/123": { "status": 200 }
  }
}
''');

      expect(scenario.match('GET', '/products/123')!.status, 200);
      expect(scenario.match('GET', '/products/456')!.status, 404);
    });

    test('is not fooled by method', () {
      final scenario = parse('''
{ "name": "x", "routes": { "POST /checkout": { "status": 201 } } }
''');

      expect(scenario.match('GET', '/checkout'), isNull);
      expect(scenario.match('POST', '/checkout')!.status, 201);
    });

    test('ignores a query string', () {
      final scenario = parse('''
{ "name": "x", "routes": { "GET /products": { "status": 200 } } }
''');

      expect(scenario.match('GET', '/products')!.status, 200);
    });
  });

  group('inheritance', () {
    final base = parse('''
{
  "name": "default",
  "routes": {
    "GET /products/123": { "status": 200, "body": { "price": 90 } },
    "GET /cart": { "status": 200, "body": { "items": [] } }
  }
}
''');

    test('overrides one route and keeps the rest', () {
      final scenario = parse('''
{
  "name": "out_of_stock",
  "inherits": "default",
  "routes": {
    "GET /products/123": { "status": 200, "body": { "available": false } }
  }
}
''').mergedOnto(base);

      expect(scenario.match('GET', '/products/123')!.bodyText,
          '{"available":false}');
      expect(scenario.match('GET', '/cart')!.status, 200);
      expect(scenario.name, 'out_of_stock');
    });

    test('a scenario with no routes of its own is the base', () {
      final scenario = parse('{ "name": "same", "inherits": "default" }')
          .mergedOnto(base);

      expect(scenario.routes.length, 2);
    });

    test('names what it inherits, so a loader knows what to read first',
        () {
      expect(parse('{ "name": "x", "inherits": "default" }').inherits,
          'default');
      expect(parse('{ "name": "x" }').inherits, isNull);
    });
  });

  group('binary bodies', () {
    // A dashboard drawing remote images cannot be photographed
    // deterministically while those images come from somebody else's
    // CDN. The fixture server has to be able to answer with the bytes
    // of a picture, and a picture is not text - `body` goes through
    // jsonEncode and `rawBody` is a Dart string, so neither can carry
    // a PNG.
    test('reads bodyBase64 into the bytes it decodes to', () {
      final scenario = parse('''
{
  "name": "images",
  "routes": {
    "GET /fixtures/outlet.png": {
      "status": 200,
      "headers": { "content-type": "image/png" },
      "bodyBase64": "aGVsbG8="
    }
  }
}
''');

      final route = scenario.match('GET', '/fixtures/outlet.png')!;
      expect(route.bodyBytes, [104, 101, 108, 108, 111]);
      // Not text. A caller that writes bodyText would send the base64
      // itself, which decodes to a corrupt image rather than failing.
      expect(route.bodyText, isNull);
    });

    test('refuses base64 that is not base64, at parse time', () {
      expect(
        () => parse('''
{ "name": "x", "routes": { "GET /a": { "bodyBase64": "not base64!!" } } }
'''),
        throwsA(
          isA<ScenarioFormatException>().having(
            (e) => e.message,
            'message',
            contains('"bodyBase64" must be base64'),
          ),
        ),
      );
    });

    test('refuses a route that sets bodyBase64 alongside a text body', () {
      // Same reasoning as body + rawBody: which one is sent has no
      // defensible answer.
      for (final other in const ['"body": {}', '"rawBody": "y"']) {
        expect(
          () => parse(
            '{ "name": "x", "routes": { "GET /a": '
            '{ $other, "bodyBase64": "aGk=" } } }',
          ),
          throwsA(isA<ScenarioFormatException>()),
          reason: 'bodyBase64 with $other',
        );
      }
    });

    test('a text body still reports no bytes, so nothing changed for it',
        () {
      final scenario = parse(
        '{ "name": "x", "routes": { "GET /a": { "body": { "ok": true } } } }',
      );

      final route = scenario.match('GET', '/a')!;
      expect(route.bodyBytes, isNull);
      expect(route.bodyText, '{"ok":true}');
    });
  });
}
