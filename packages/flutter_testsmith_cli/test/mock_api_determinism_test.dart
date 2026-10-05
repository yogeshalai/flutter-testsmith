import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/mock_api_server.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Whether the fixture server answers the same way twice.
///
/// This is the layer everything above it assumes and nothing above it
/// could detect. A visual baseline is a claim that a screen looks a
/// certain way *given a response*; if the response drifts between runs,
/// the baseline fails for a reason that has nothing to do with the
/// application, and the natural reaction is to widen the tolerance until
/// it stops - which is how a visual check dies.
///
/// So the server is asked the same question repeatedly and the answers
/// are compared **byte for byte**, before any device is involved.

Future<({int status, Uint8List bytes, String? contentType})> fetch(
  int port,
  String path, {
  String method = 'GET',
}) async {
  final client = HttpClient();
  try {
    final request =
        await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    final response = await request.close().timeout(const Duration(seconds: 5));
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
    }
    return (
      status: response.statusCode,
      bytes: Uint8List.fromList(chunks),
      contentType: response.headers.contentType?.mimeType,
    );
  } finally {
    client.close(force: true);
  }
}

/// A one-pixel PNG, so a binary route can be served without a file.
const String redDot =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
    'IQAAAABJRU5ErkJggg==';

ApiScenario scenarioOf(Map<String, Object?> routes) => ApiScenario.parse(
      jsonEncode({'name': 'fixture', 'routes': routes}),
      source: 'test.json',
    );

void main() {
  group('the same request, over and over', () {
    late MockApiServer server;

    setUp(() async {
      server = await MockApiServer.start(
        port: 0,
        scenario: scenarioOf({
          'GET /api/dashboard': {
            'status': 200,
            'body': {
              'outletsNearYou': {
                'isOutletsNearYouDataAvailable': true,
                'outletsNearYouData': [
                  {'_id': 'b-1', 'businessName': 'One', 'overallRating': 4.6},
                  {'_id': 'b-2', 'businessName': 'Two', 'overallRating': 4.3},
                ],
              },
            },
          },
          'GET /fixtures/outlet.png': {
            'status': 200,
            'headers': {'content-type': 'image/png'},
            'bodyBase64': redDot,
          },
        }),
      );
    });

    tearDown(() => server.close());

    test('answers a JSON route byte for byte identically, ten times over',
        () async {
      final first = await fetch(server.port, '/api/dashboard');
      expect(first.status, 200);

      for (var attempt = 2; attempt <= 10; attempt++) {
        final again = await fetch(server.port, '/api/dashboard');
        expect(again.status, first.status, reason: 'attempt $attempt');
        expect(again.bytes, first.bytes, reason: 'attempt $attempt');
      }
    });

    test('keeps the order of a list, so a rendered screen keeps its order',
        () async {
      // Not implied by equal bytes alone, and worth asserting in its own
      // words: an API that shuffled a list would redraw the dashboard in
      // a different order and fail the picture for a reason nobody would
      // look for in the fixture.
      for (var attempt = 0; attempt < 5; attempt++) {
        final response = await fetch(server.port, '/api/dashboard');
        final decoded = jsonDecode(utf8.decode(response.bytes)) as Map;
        final outlets = ((decoded['outletsNearYou'] as Map)
            ['outletsNearYouData'] as List)
            .cast<Map<String, Object?>>();

        expect([for (final o in outlets) o['_id']], ['b-1', 'b-2']);
      }
    });

    test('answers a binary route with the same bytes and the declared type',
        () async {
      final first = await fetch(server.port, '/fixtures/outlet.png');

      expect(first.status, 200);
      expect(first.contentType, 'image/png');
      // The decoded bytes, not the base64 - a route that wrote the
      // encoding as text would still be stable and still be wrong.
      expect(first.bytes, base64Decode(redDot));

      for (var attempt = 2; attempt <= 5; attempt++) {
        final again = await fetch(server.port, '/fixtures/outlet.png');
        expect(again.bytes, first.bytes, reason: 'attempt $attempt');
        expect(again.contentType, 'image/png', reason: 'attempt $attempt');
      }
    });

    test('needs no network beyond the loopback interface', () async {
      // The claim the milestone turns on. The server is bound to
      // 127.0.0.1 and every route is answered out of a committed file,
      // so a run cannot silently reach a backend.
      await fetch(server.port, '/api/dashboard');
      expect(
        server.exchanges.every((e) => e.matched),
        isTrue,
        reason: 'a route the scenario does not cover would 404, and the '
            'application would then be showing an error state nobody '
            'declared',
      );
    });

    test('a route the scenario says nothing about is a 404 that says which '
        'scenario', () async {
      final response = await fetch(server.port, '/api/not/in/the/fixture');

      expect(response.status, 404);
      expect(utf8.decode(response.bytes), contains('fixture'));
      expect(server.exchanges.last.matched, isFalse);
    });
  });

  group('two independent servers on the same scenario', () {
    test('answer identically, so a rerun on a fresh process matches',
        () async {
      // The determinism that actually matters for CI: not "twice within
      // one process", which a cached string would satisfy, but twice
      // across two starts.
      Future<Uint8List> once() async {
        final server = await MockApiServer.start(
          port: 0,
          scenario: scenarioOf({
            'GET /api/orders': {
              'status': 200,
              'body': {
                'data': [
                  {'_id': 'o-1', 'currentStatus': 'DELIVERED', 'amount': 560},
                ],
                'total': 1,
              },
            },
          }),
        );
        try {
          return (await fetch(server.port, '/api/orders')).bytes;
        } finally {
          await server.close();
        }
      }

      expect(await once(), await once());
    });
  });
}
