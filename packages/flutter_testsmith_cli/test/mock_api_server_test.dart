import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/mock_api_server.dart';
import 'package:flutter_testsmith/engine.dart';

/// The scenarios the example application ships with.
///
/// Loaded from disk rather than fabricated: the thing worth asserting is
/// that the files a run will actually serve are well formed, not that a
/// string literal in this file is.
Directory get scenarios {
  for (final candidate in [
    'examples/ecommerce_app/mock_api/scenarios',
    '../../examples/ecommerce_app/mock_api/scenarios',
  ]) {
    final directory = Directory(candidate);
    if (directory.existsSync()) return directory;
  }
  fail('cannot find the example application\'s scenarios from '
      '${Directory.current.path}');
}

Future<({int status, String body, Map<String, String> headers})> get(
  int port,
  String path, {
  String method = 'GET',
  Duration timeout = const Duration(seconds: 2),
}) async {
  final client = HttpClient();
  try {
    final request =
        await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    final headers = <String, String>{};
    response.headers.forEach((name, values) => headers[name] = values.join(','));
    return (status: response.statusCode, body: body, headers: headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late ScenarioLibrary library;

  setUpAll(() => library = ScenarioLibrary.load(scenarios));

  group('the shipped scenarios', () {
    test('all parse, and every one names its own file', () {
      // ScenarioLibrary.load throws on either problem, so reaching here
      // is the assertion. The count guards against the directory quietly
      // becoming empty.
      expect(library.names.length, greaterThanOrEqualTo(20));
      expect(library.names, contains('default'));
    });

    test('every scenario resolves, including its inheritance', () {
      for (final name in library.names) {
        expect(() => library.resolve(name), returnsNormally, reason: name);
      }
    });

    test('every scenario answers the routes the application calls', () {
      const required = [
        ('POST', '/auth/login'),
        ('GET', '/home/summary'),
        ('GET', '/products'),
        ('GET', '/products/123'),
        ('GET', '/cart'),
        ('POST', '/checkout'),
      ];

      for (final name in library.names) {
        final scenario = library.resolve(name);
        for (final (method, path) in required) {
          expect(
            scenario.match(method, path),
            isNotNull,
            // A scenario silently missing a route serves a 404 the
            // application reads as a real error, which would make a
            // fixture bug look like an application bug.
            reason: 'scenario "$name" says nothing about $method $path',
          );
        }
      }
    });

    test('resolving a name that does not exist throws, listing what does',
        () {
      expect(
        () => library.resolve('no_such_scenario'),
        throwsA(
          isA<ScenarioFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('no such scenario'), contains('default')),
          ),
        ),
      );
    });
  });

  group('serving', () {
    late MockApiServer server;

    Future<void> serve(String scenario) async {
      server = await MockApiServer.start(
        scenario: library.resolve(scenario),
        port: 0,
      );
    }

    tearDown(() => server.close());

    test('serves a different scenario after being told to', () async {
      // A suite runs several flows against one server, and the flows
      // name different API states. Restarting the server between them
      // would tear down the `adb reverse` the device is talking through,
      // so the scenario is swapped in place instead.
      await serve('default');
      expect(
        jsonDecode((await get(server.port, '/products/123')).body),
        containsPair('available', true),
      );

      server.serve(library.resolve('product_out_of_stock'));

      expect(server.scenario.name, 'product_out_of_stock');
      expect(
        jsonDecode((await get(server.port, '/products/123')).body),
        containsPair('available', false),
      );
    });

    test('forgets the previous scenario exchanges when it swaps', () async {
      // The exchanges are what an API assertion reads. Carrying the
      // previous test's requests into the next one would let a flow
      // assert against traffic it never made.
      await serve('default');
      await get(server.port, '/products/123');
      expect(server.exchanges, isNotEmpty);

      server.serve(library.resolve('default'));

      expect(server.exchanges, isEmpty);
    });

    test('serves the happy path', () async {
      await serve('default');
      final response = await get(server.port, '/products/123');

      expect(response.status, 200);
      expect(jsonDecode(response.body), containsPair('price', 90));
    });

    test('an override replaces one route and leaves the rest', () async {
      await serve('product_out_of_stock');

      final product = await get(server.port, '/products/123');
      expect(jsonDecode(product.body), containsPair('available', false));

      final cart = await get(server.port, '/cart');
      expect(cart.status, 200);
    });

    for (final (name, status) in [
      ('api_400_bad_request', 400),
      ('api_401_unauthorised', 401),
      ('api_403_forbidden', 403),
      ('api_404_not_found', 404),
      ('api_500_server_error', 500),
    ]) {
      test('$name really returns $status', () async {
        await serve(name);
        expect((await get(server.port, '/products/123')).status, status);
      });
    }

    test('api_malformed returns a body that is not JSON', () async {
      await serve('api_malformed');
      final response = await get(server.port, '/products/123');

      expect(response.status, 200);
      // Content type still claims JSON: that is what makes a client try
      // to parse it, which is the situation being tested.
      expect(response.headers['content-type'], contains('application/json'));
      expect(() => jsonDecode(response.body), throwsFormatException);
    });

    test('api_timeout does not answer within a client-sized wait', () async {
      await serve('api_timeout');

      await expectLater(
        get(server.port, '/products/123',
            timeout: const Duration(milliseconds: 400)),
        throwsA(anything),
      );
    });

    test('a route the scenario says nothing about is reported as such',
        () async {
      await serve('default');
      final response = await get(server.port, '/nope');

      expect(response.status, 404);
      expect(response.body, contains('not in scenario'));
      expect(server.exchanges.last.matched, isFalse);
    });

    test('records what it served, with the status', () async {
      await serve('api_500_server_error');
      await get(server.port, '/products/123');

      expect(server.exchanges.single.status, 500);
      expect(server.exchanges.single.matched, isTrue);
      expect(server.requestLog, ['GET /products/123']);
    });

    test('sends a credential-shaped header, so redaction is exercised on '
        'real traffic', () async {
      await serve('default');
      final response = await get(server.port, '/products/123');

      expect(response.headers['set-cookie'], contains('MOCK_SESSION_SECRET'));
    });
  });
}
