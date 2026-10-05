
import 'dart:async';
import 'dart:io';

import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:test/test.dart';

class FakeHttp implements FigmaHttp {
  FakeHttp({this.status = 200, this.body = '{"nodes":{}}'});

  int status;
  String body;
  final List<({String url, Map<String, String> headers})> calls = [];

  @override
  Future<FigmaHttpResponse> get(String url, Map<String, String> headers) async {
    calls.add((url: url, headers: headers));
    return FigmaHttpResponse(status: status, body: body);
  }
}

/// An HTTP layer that fails the way `HttpClient` really fails.
///
/// The real transport has no `catch` of its own, so whatever it raises is
/// what the caller sees. Each of these is one thing that path can throw.
class FailingHttp implements FigmaHttp {
  FailingHttp(this.error);

  final Object error;

  @override
  Future<FigmaHttpResponse> get(String url, Map<String, String> headers) async {
    throw error;
  }
}

/// Every failure `HttpClient` raises between the request and the body.
///
/// Three unrelated families - `IOException`, `FormatException` and
/// `TimeoutException` - which is why catching one named type is not
/// enough. `HandshakeException` extends `TlsException`, and a
/// `SocketException` covers both a DNS failure and a refused connection.
const Map<String, Object> transportFailures = {
  'a DNS failure': SocketException('Failed host lookup: api.figma.com'),
  'a refused connection': SocketException('Connection refused', port: 443),
  'a rejected certificate': HandshakeException('CERTIFICATE_VERIFY_FAILED'),
  'a TLS error': TlsException('bad record mac'),
  'a connection closed early': HttpException('Connection closed'),
  'a body that is not UTF-8': FormatException('Unexpected extension byte'),
};

void main() {
  late Directory cache;

  setUp(() => cache = Directory.systemTemp.createTempSync('figma-cache'));
  tearDown(() => cache.deleteSync(recursive: true));

  FigmaClient clientWith(FakeHttp http) => FigmaClient(
        token: 'figd_TOPSECRET',
        http: http,
        cacheDirectory: cache,
      );

  group('fetching', () {
    test('calls the nodes endpoint for the file and node', () async {
      final http = FakeHttp();

      await clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2');

      expect(http.calls.single.url,
          'https://api.figma.com/v1/files/abc/nodes?ids=1%3A2');
    });

    test('authenticates with the token header', () async {
      final http = FakeHttp();

      await clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2');

      expect(http.calls.single.headers['X-Figma-Token'], 'figd_TOPSECRET');
    });

    test('returns the decoded body', () async {
      final http = FakeHttp(body: '{"nodes":{"1:2":{"document":{}}}}');

      final result =
          await clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2');

      expect(result['nodes'], isA<Map<String, Object?>>());
    });
  });

  group('caching', () {
    test('writes the response to the cache', () async {
      final http = FakeHttp(body: '{"nodes":{"cached":true}}');

      await clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2');

      expect(cache.listSync().whereType<File>(), isNotEmpty);
    });

    test('a second fetch does not hit the network', () async {
      // Figma rate-limits, and a design does not change between two
      // steps of one run.
      final http = FakeHttp(body: '{"nodes":{"cached":true}}');
      final client = clientWith(http);

      await client.fetchNode(fileKey: 'abc', nodeId: '1:2');
      await client.fetchNode(fileKey: 'abc', nodeId: '1:2');

      expect(http.calls, hasLength(1));
    });

    test('refresh bypasses the cache', () async {
      final http = FakeHttp(body: '{"nodes":{}}');
      final client = clientWith(http);

      await client.fetchNode(fileKey: 'abc', nodeId: '1:2');
      await client.fetchNode(fileKey: 'abc', nodeId: '1:2', refresh: true);

      expect(http.calls, hasLength(2));
    });

    test('different nodes cache separately', () async {
      final http = FakeHttp();
      final client = clientWith(http);

      await client.fetchNode(fileKey: 'abc', nodeId: '1:2');
      await client.fetchNode(fileKey: 'abc', nodeId: '3:4');

      expect(http.calls, hasLength(2));
    });

    test('the token is never written to the cache', () async {
      // The cache is an ordinary file in the project; a token in it
      // would be a credential at rest, and probably committed.
      final http = FakeHttp();

      await clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2');

      for (final file in cache.listSync().whereType<File>()) {
        expect(file.readAsStringSync(), isNot(contains('figd_TOPSECRET')));
      }
    });
  });

  group('failures explain themselves', () {
    test('401 says the token is the problem', () async {
      final http = FakeHttp(status: 403, body: '{"err":"Invalid token"}');

      await expectLater(
        clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(
          isA<FigmaException>()
              .having((e) => e.toString(), 'message', contains('token')),
        ),
      );
    });

    test('404 says the file or node is the problem', () async {
      final http = FakeHttp(status: 404, body: '{"err":"Not found"}');

      await expectLater(
        clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(
          isA<FigmaException>()
              .having((e) => e.toString(), 'message', contains('abc')),
        ),
      );
    });

    test('429 says it is rate limiting', () async {
      final http = FakeHttp(status: 429, body: '{}');

      await expectLater(
        clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(
          isA<FigmaException>()
              .having((e) => e.toString(), 'message', contains('rate')),
        ),
      );
    });

    test('an error never repeats the token back', () async {
      final http = FakeHttp(status: 403, body: '{"err":"Invalid token"}');

      try {
        await clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2');
        fail('should have thrown');
      } on FigmaException catch (error) {
        expect(error.toString(), isNot(contains('figd_TOPSECRET')));
      }
    });

    test('a failed fetch is not cached', () async {
      final http = FakeHttp(status: 500, body: 'boom');

      await expectLater(
        clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(isA<FigmaException>()),
      );
      expect(cache.listSync().whereType<File>(), isEmpty);
    });

    test('a non-JSON body is reported as such', () async {
      final http = FakeHttp(body: '<html>gateway error</html>');

      await expectLater(
        clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(isA<FigmaException>()),
      );
    });
  });

  group('a network that will not carry the request', () {
    // Measured before this group existed: every one of these left the
    // client as itself, past `on FigmaException` in `resolveFigmaSources`
    // and `figma pull`, past `bin/testsmith.dart` - which catches
    // `UsageException` and nothing else - and ended the process at 255.
    // A design that cannot be fetched is a Figma failure like any other:
    // the run reports it on the screen that declared it.
    for (final failure in transportFailures.entries) {
      test('${failure.key} is a Figma failure, naming the host', () async {
        await expectLater(
          FigmaClient(
            token: 'figd_TOPSECRET',
            http: FailingHttp(failure.value),
            cacheDirectory: cache,
          ).fetchNode(fileKey: 'abc', nodeId: '1:2'),
          throwsA(
            isA<FigmaException>()
                .having((e) => e.message, 'message', contains('api.figma.com')),
          ),
        );
      });
    }

    test('a timeout is one too, whoever raised it', () async {
      // No timeout is set here - that is a separate question with a
      // number in it. This is the clause that puts one where it belongs
      // if a transport ever applies one.
      await expectLater(
        FigmaClient(
          token: 'figd_TOPSECRET',
          http: FailingHttp(TimeoutException('after 30s')),
          cacheDirectory: cache,
        ).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(isA<FigmaException>()),
      );
    });

    test('and none of them repeats the token back', () async {
      for (final failure in transportFailures.values) {
        try {
          await FigmaClient(
            token: 'figd_TOPSECRET',
            http: FailingHttp(failure),
            cacheDirectory: cache,
          ).fetchNode(fileKey: 'abc', nodeId: '1:2');
          fail('should have thrown for $failure');
        } on FigmaException catch (error) {
          expect(error.toString(), isNot(contains('figd_TOPSECRET')));
        }
      }
    });

    test('and nothing is left in the cache', () async {
      await expectLater(
        FigmaClient(
          token: 'figd_TOPSECRET',
          http: FailingHttp(const SocketException('Failed host lookup')),
          cacheDirectory: cache,
        ).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(isA<FigmaException>()),
      );
      expect(cache.listSync().whereType<File>(), isEmpty);
    });
  });

  group('an answer that is not a design is never cached', () {
    // The comment above the cache write already says a gateway error page
    // must never be stored as though it were a design. The check under it
    // only asked whether the body was a JSON object, so a captive portal
    // or proxy answering HTTP 200 with `{"error": "..."}` was written to
    // `<app>/figma/.cache` - and every later run read it back and died in
    // the normaliser, with the network long since fixed and the cache
    // directory gitignored where nobody would look.
    test('a 200 that carries no nodes is refused', () async {
      final http = FakeHttp(body: '{"error":"blocked by policy"}');

      await expectLater(
        clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(isA<FigmaException>()),
      );
    });

    test('and is not written to the cache', () async {
      final http = FakeHttp(body: '{"error":"blocked by policy"}');

      await expectLater(
        clientWith(http).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(isA<FigmaException>()),
      );
      expect(cache.listSync().whereType<File>(), isEmpty);
    });

    test('and one already there is refused rather than handed on', () async {
      // The caches this fix inherits. They were written before it existed
      // and nothing clears them, so the file answers every later run -
      // offline, from a directory `.gitignore` covers.
      File('${cache.path}/abc.1-2.json')
          .writeAsStringSync('{"error":"blocked by policy"}');

      await expectLater(
        clientWith(FakeHttp()).fetchNode(fileKey: 'abc', nodeId: '1:2'),
        throwsA(
          isA<FigmaException>()
              .having((e) => e.message, 'remedy', contains('--refresh')),
        ),
      );
    });

    test('while a frame with no matching node is still a real answer',
        () async {
      // The line this must not cross. `{"nodes":{}}` is what Figma really
      // says when the id is not in the file: an answer, cacheable, and
      // the normaliser's job to refuse. Only "this is not Figma talking"
      // is stopped here.
      final http = FakeHttp(body: '{"nodes":{}}');

      final node = await clientWith(http).fetchNode(
        fileKey: 'abc',
        nodeId: '1:2',
      );

      expect(node, {'nodes': <String, Object?>{}});
      expect(cache.listSync().whereType<File>(), hasLength(1));
    });
  });

  group('node id forms', () {
    test('accepts the dash form used in Figma URLs', () async {
      // A URL says node-id=913-1; the API wants 913:1. Making
      // the user translate that by hand is a needless trap.
      final http = FakeHttp();

      await clientWith(http).fetchNode(fileKey: 'abc', nodeId: '913-1');

      expect(http.calls.single.url, contains('913%3A1'));
    });

    test('extracts file key and node id from a Figma URL', () {
      final target = FigmaTarget.parseUrl(
        'https://www.figma.com/design/TEST_FIGMA_FILE_KEY/'
        'Example-Design-File?node-id=913-1&m=dev',
      );

      expect(target.fileKey, 'TEST_FIGMA_FILE_KEY');
      expect(target.nodeId, '913:1');
    });

    test('rejects a URL with no node id', () {
      expect(
        () => FigmaTarget.parseUrl('https://www.figma.com/design/abc/Name'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
