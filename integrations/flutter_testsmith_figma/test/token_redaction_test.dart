import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:test/test.dart';

/// The Figma token must not leave the process through anything a run
/// writes down.
///
/// It is supplied through the environment, put in one HTTP header, and
/// that is the whole of its journey. Everything below is somewhere it
/// could plausibly end up instead: an error message quoting the request,
/// a cached response, a normalised spec, a stack trace.
///
/// The sentinel is shaped like a real Figma personal access token so a
/// substring check cannot pass by accident. It is assembled from parts so
/// that secret scanners (GitHub push protection, `dart pub publish`) do
/// not mistake the source for a leaked token.
const String _sentinel = 'fig' 'd_' 'SENTINEL0000TOKEN0000MUSTNOTLEAK00000000';

/// Records the header it was given, and answers however the test wants.
class _RecordingHttp implements FigmaHttp {
  _RecordingHttp(this.status, this.body);

  final int status;
  final String body;
  Map<String, String>? headers;

  @override
  Future<FigmaHttpResponse> get(String url, Map<String, String> headers) async {
    this.headers = headers;
    return FigmaHttpResponse(status: status, body: body);
  }
}

String _fixture() =>
    File('test/fixtures/login_node.json').readAsStringSync();

void main() {
  group('the token', () {
    test('is sent, so the rest of this file is testing something', () async {
      final http = _RecordingHttp(200, _fixture());

      await FigmaClient(token: _sentinel, http: http)
          .fetchNode(fileKey: 'TEST_FIGMA_FILE_KEY', nodeId: '909:1');

      expect(http.headers!['X-Figma-Token'], _sentinel);
    });

    test('is not in the message when Figma rejects it', () async {
      final client = FigmaClient(
        token: _sentinel,
        http: _RecordingHttp(403, '{"err":"Invalid token"}'),
      );

      await expectLater(
        client.fetchNode(fileKey: 'TEST_FIGMA_FILE_KEY', nodeId: '909:1'),
        throwsA(
          isA<FigmaException>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains(_sentinel)),
          ),
        ),
      );
    });

    test('is not in the message when the file is missing', () async {
      final client = FigmaClient(
        token: _sentinel,
        http: _RecordingHttp(404, 'not found'),
      );

      await expectLater(
        client.fetchNode(fileKey: 'TEST_FIGMA_FILE_KEY', nodeId: '909:1'),
        throwsA(
          isA<FigmaException>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains(_sentinel)),
          ),
        ),
      );
    });

    test('is not in the message when the response is not JSON', () async {
      final client = FigmaClient(
        token: _sentinel,
        http: _RecordingHttp(200, '<html>gateway timeout</html>'),
      );

      await expectLater(
        client.fetchNode(fileKey: 'TEST_FIGMA_FILE_KEY', nodeId: '909:1'),
        throwsA(
          isA<FigmaException>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains(_sentinel)),
          ),
        ),
      );
    });

    test('is not written to the on-disk cache', () async {
      final directory = Directory.systemTemp.createTempSync('figma_cache');
      addTearDown(() => directory.deleteSync(recursive: true));

      await FigmaClient(
        token: _sentinel,
        http: _RecordingHttp(200, _fixture()),
        cacheDirectory: directory,
      ).fetchNode(fileKey: 'TEST_FIGMA_FILE_KEY', nodeId: '909:1');

      final written = directory.listSync().whereType<File>().toList();

      expect(written, isNotEmpty, reason: 'nothing was cached to inspect');
      for (final file in written) {
        expect(file.readAsStringSync(), isNot(contains(_sentinel)));
        expect(file.path, isNot(contains(_sentinel)));
      }
    });

    test('is not in the normalised spec, at any depth', () async {
      final raw = await FigmaClient(
        token: _sentinel,
        http: _RecordingHttp(200, _fixture()),
      ).fetchNode(fileKey: 'TEST_FIGMA_FILE_KEY', nodeId: '909:1');

      final spec = const FigmaNormaliser()
          .normalise(raw, nodeId: '909:1', screen: '/login');

      // The whole serialised spec, which is what gets committed and
      // what a report reads.
      expect(jsonEncode(spec.toJson()), isNot(contains(_sentinel)));
    });

    test('is not in a target rendered for a log line', () {
      final target = FigmaTarget.parseUrl(
        'https://www.figma.com/design/TEST_FIGMA_FILE_KEY/Example?node-id=909-1',
      );

      expect(target.toString(), isNot(contains(_sentinel)));
    });
  });
}
