import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// A real server, because dart:io interception is precisely the thing
/// that looks correct against a mock and fails against a socket.
Future<HttpServer> startServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();

    switch (request.uri.path) {
      case '/products/123':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..headers.add('set-cookie', 'session=SERVERSECRET; HttpOnly')
          ..write('{"name":"Nike Air Max","price":2999,"available":false}');
      case '/login':
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"accessToken":"MINTED_SECRET","user":"y"}');
      case '/echo':
        request.response
          ..statusCode = 201
          ..write(body);
      case '/boom':
        request.response.statusCode = 500;
      default:
        request.response.statusCode = 404;
    }
    await request.response.close();
  });

  return server;
}

void main() {
  late HttpServer server;
  late List<EventPayload> emitted;
  late NetworkCapture capture;
  late String base;

  setUp(() async {
    server = await startServer();
    base = 'http://${server.address.address}:${server.port}';
    emitted = <EventPayload>[];
    capture = NetworkCapture(
      config: const TestSdkConfig(enabled: true),
      emit: emitted.add,
    );
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  List<ApiRequestPayload> requests() =>
      emitted.whereType<ApiRequestPayload>().toList();
  List<ApiResponsePayload> responses() =>
      emitted.whereType<ApiResponsePayload>().toList();
  String everything() =>
      jsonEncode([for (final e in emitted) e.toJson()]);

  Future<String> fetch(
    String path, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final client = HttpClient();
    final request = await client.openUrl(method, Uri.parse('$base$path'));
    headers.forEach(request.headers.set);
    if (body != null) request.write(body);
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    client.close();
    return text;
  }

  group('CapturingHttpOverrides', () {
    test('captures a request and its response', () async {
      HttpOverrides.global = CapturingHttpOverrides(capture);

      final body = await fetch('/products/123');

      expect(body, contains('Nike Air Max'));
      expect(requests().single.method, 'GET');
      expect(requests().single.path, '/products/123');
      expect(responses().single.statusCode, 200);
      expect(responses().single.readPath('price'), 2999);
    });

    test('does not alter what the application receives', () async {
      // Interception that changes the response would be worse than no
      // interception at all.
      HttpOverrides.global = null;
      final uncaptured = await fetch('/products/123');

      HttpOverrides.global = CapturingHttpOverrides(capture);
      final captured = await fetch('/products/123');

      expect(captured, uncaptured);
    });

    test('captures a request body', () async {
      HttpOverrides.global = CapturingHttpOverrides(capture);

      await fetch('/echo', method: 'POST', body: '{"qty":2}');

      expect(requests().single.body, contains('qty'));
    });

    test('redacts a request header before it is emitted', () async {
      HttpOverrides.global = CapturingHttpOverrides(capture);

      await fetch(
        '/products/123',
        headers: {'authorization': 'Bearer CLIENTSECRET'},
      );

      expect(everything(), isNot(contains('CLIENTSECRET')));
    });

    test('redacts a secret the server sends back', () async {
      // The dangerous direction: a token minted by the server, which the
      // application never wrote down anywhere.
      HttpOverrides.global = CapturingHttpOverrides(capture);

      await fetch('/login', method: 'POST');

      expect(everything(), isNot(contains('MINTED_SECRET')));
      expect(responses().single.readPath('user'), 'y');
    });

    test('redacts a set-cookie header from the server', () async {
      HttpOverrides.global = CapturingHttpOverrides(capture);

      await fetch('/products/123');

      expect(everything(), isNot(contains('SERVERSECRET')));
    });

    test('records an error status without treating it as success',
        () async {
      HttpOverrides.global = CapturingHttpOverrides(capture);

      await fetch('/boom');

      expect(responses().single.statusCode, 500);
      expect(responses().single.isSuccess, isFalse);
    });

    test('records a connection failure as an error, not a status',
        () async {
      HttpOverrides.global = CapturingHttpOverrides(capture);
      await server.close(force: true);

      await expectLater(fetch('/products/123'), throwsA(anything));

      expect(responses().single.statusCode, isNull);
      expect(responses().single.error, isNotNull);
    });

    test('a credential in the URL does not come back through a real failure',
        () async {
      // A server that hangs up before answering. dart:io then raises a
      // genuine HttpException, whose text quotes the whole request URL -
      // the case NetworkCapture.fail now redacts. Against a socket, not a
      // hand-built exception, so the premise is measured too.
      final hangUp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      hangUp.listen((socket) => socket.destroy());
      addTearDown(hangUp.close);

      HttpOverrides.global = CapturingHttpOverrides(capture);
      final url = 'http://${hangUp.address.address}:${hangUp.port}'
          '/orders?access_token=TOPSECRET&page=2';

      Object? raised;
      try {
        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(url));
        await request.close();
        client.close();
      } catch (error) {
        raised = error;
      }

      // The premise: what the application itself sees carries the secret.
      expect('$raised', contains('TOPSECRET'));
      // The guarantee: nothing the capture emitted does.
      expect(everything(), isNot(contains('TOPSECRET')));
      expect(responses().single.error, contains('access_token=[REDACTED]'));
      expect(responses().single.error, contains('page=2'));
    });

    test('leaves an excluded endpoint entirely uncaptured', () async {
      capture = NetworkCapture(
        config: const TestSdkConfig(
          enabled: true,
          redaction: RedactionPolicy(
            sensitiveKeys: {},
            excludedPaths: {'/login'},
          ),
        ),
        emit: emitted.add,
      );
      HttpOverrides.global = CapturingHttpOverrides(capture);

      await fetch('/login', method: 'POST');

      expect(emitted, isEmpty);
    });

    test('delegates to a previously installed override', () async {
      // An application may already have its own HttpOverrides; replacing
      // rather than wrapping it would silently break it.
      var delegated = false;
      HttpOverrides.global = _MarkerOverrides(() => delegated = true);

      HttpOverrides.global = CapturingHttpOverrides(
        capture,
        previous: HttpOverrides.current,
      );
      await fetch('/products/123');

      expect(delegated, isTrue);
    });
  });
}

class _MarkerOverrides extends HttpOverrides {
  _MarkerOverrides(this.onCreate);

  final void Function() onCreate;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    onCreate();
    return super.createHttpClient(context);
  }
}
