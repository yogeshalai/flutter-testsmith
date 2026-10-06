import 'package:ecommerce_app/api/api_client.dart';
import 'package:ecommerce_app/screens/checkout_screen.dart';
import 'package:ecommerce_app/screens/login_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/src/cli/mock_api_server.dart';

import 'harness.dart';

/// Phase 12, brief item 2 - API errors, over a real socket.
///
/// **No `testWidgets` in this file, deliberately.** Initialising the
/// Flutter test binding replaces `HttpOverrides.global` with one that
/// answers every request with a canned 400, and a request made from a
/// widget's `initState` is then never delivered at all - measured, not
/// assumed: a `MockApiServer` bound inside a widget test never sees the
/// connection, and the test hangs until it times out.
///
/// So the chain is proven in two halves. This half is real: a real
/// server, a real socket, the real `ApiClient`, asserting that a 403, a
/// timeout and a malformed body are three different outcomes rather than
/// one generic failure. The other half - what each outcome puts on
/// screen - is `ui_state_matrix_test.dart`. The join between them is
/// exercised on a device, which is where it belongs.

final matrix = MatrixRecorder(
  'API transport matrix (real socket)',
  'docs/evidence/api_transport_matrix.md',
  const [
    'Case',
    'Fixture',
    'Server really returned',
    'ApiException.statusCode',
    'Classified as',
    'Message shown to a person',
  ],
);

Future<T> withServer<T>(
  String scenario,
  Future<T> Function(MockApiServer server, ApiClient api) body,
) async {
  final server = await MockApiServer.start(
    scenario: ScenarioLibrary.load(scenarioDirectory).resolve(scenario),
    port: 0,
  );
  try {
    return await body(
      server,
      ApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        // 400ms against api_timeout's 9s delay. Shortening the timeout
        // changes when it fires, not what the client does about it.
        timeout: const Duration(milliseconds: 400),
      ),
    );
  } finally {
    await server.close();
  }
}

/// Calls [request] and returns the exception it produced.
Future<ApiException> failureOf(Future<Object?> Function() request) async {
  try {
    await request();
  } on ApiException catch (error) {
    return error;
  }
  fail('the request succeeded; it was expected to fail');
}

void main() {
  tearDownAll(matrix.write);

  group('status codes are distinguished, not collapsed', () {
    for (final (fixture, status, classification, expectedText) in [
      ('api_400_bad_request', 400, 'bad request', 'not valid'),
      ('api_401_unauthorised', 401, 'unauthorised', 'session has expired'),
      ('api_403_forbidden', 403, 'forbidden', 'do not have access'),
      ('api_404_not_found', 404, 'not found', 'could not find'),
      ('api_500_server_error', 500, 'server error', 'our end'),
    ]) {
      test('$fixture is classified as $classification', () async {
        await withServer(fixture, (server, api) async {
          final failure = await failureOf(() => api.product('123'));

          expect(failure.statusCode, status);
          expect(failure.isTimeout, isFalse);
          expect(failure.userMessage, contains(expectedText));
          // The server really answered with this, rather than the client
          // inventing it.
          expect(server.exchanges.single.status, status);

          matrix.add([
            'HTTP $status',
            fixture,
            '$status',
            '$status',
            classification,
            failure.userMessage,
          ]);
        });
      });
    }

    test('401 and 403 do not share a message', () async {
      // They need different words and different affordances. An app that
      // says "something went wrong" for an expired session is one nobody
      // can sign back into.
      late String unauthorised;
      late String forbidden;

      await withServer('api_401_unauthorised', (_, api) async {
        unauthorised = (await failureOf(() => api.product('123'))).userMessage;
      });
      await withServer('api_403_forbidden', (_, api) async {
        forbidden = (await failureOf(() => api.product('123'))).userMessage;
      });

      expect(unauthorised, isNot(forbidden));
    });
  });

  group('failures that are not status codes', () {
    test('a timeout carries no status at all', () async {
      await withServer('api_timeout', (server, api) async {
        final failure = await failureOf(() => api.product('123'));

        expect(failure.isTimeout, isTrue);
        // The distinction that matters: a 500 is an answer, a timeout is
        // the absence of one.
        expect(failure.statusCode, isNull);
        expect(failure.userMessage, contains('took too long'));

        matrix.add([
          'timeout',
          'api_timeout',
          'nothing within 400ms (fixture delays 9s)',
          'null',
          'timeout',
          failure.userMessage,
        ]);
      });
    });

    test('a 200 with a body that is not JSON is its own failure', () async {
      await withServer('api_malformed', (server, api) async {
        final failure = await failureOf(() => api.product('123'));

        expect(failure.statusCode, 200);
        expect(failure.userMessage, contains('could not be read'));
        expect(server.exchanges.single.status, 200);

        matrix.add([
          'malformed body',
          'api_malformed',
          '200, truncated JSON',
          '200',
          'unreadable reply',
          failure.userMessage,
        ]);
      });
    });

    test('a 200 whose body is an array where an object was promised',
        () async {
      await withServer('api_wrong_shape', (server, api) async {
        final failure = await failureOf(() => api.product('123'));

        expect(failure.userMessage, contains('where an object was expected'));

        matrix.add([
          'wrong shape',
          'api_wrong_shape',
          '200, a JSON array',
          '200',
          'wrong shape',
          failure.userMessage,
        ]);
      });
    });

    test('a refused connection is reported as such', () async {
      // No server at all. Distinct from every row above: nothing was
      // ever spoken to.
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        timeout: const Duration(milliseconds: 400),
      );
      final failure = await failureOf(() => api.product('123'));

      expect(failure.statusCode, isNull);
      expect(failure.message, contains('could not reach the server'));

      matrix.add([
        'connection refused',
        '(no server)',
        'nothing',
        'null',
        'unreachable',
        failure.userMessage,
      ]);
    });
  });

  group('success paths over a real socket', () {
    test('the happy path decodes', () async {
      await withServer('default', (server, api) async {
        final product = await api.product('123');

        expect(product.name, 'Nonveg-Burger');
        expect(product.price, 90);

        matrix.add([
          'success',
          'default',
          '200',
          '-',
          'ok',
          '-',
        ]);
      });
    });

    test('login carries the password on the wire and adopts the token',
        () async {
      await withServer('default', (server, api) async {
        final session = await api.login(
          email: 'test.user@example.com',
          password: LoginScreen.seededPassword,
        );

        expect(session.token, 'SEEDED_ACCESS_TOKEN_8a17fc');
        expect(session.refreshToken, 'SEEDED_REFRESH_TOKEN_20b93e');
      });
    });

    test('checkout really posts the card, CVV and OTP', () async {
      // The point of this row is not the response: it is that four
      // credentials genuinely cross a socket, so the redaction matrix
      // has real traffic to prove itself against.
      await withServer('default', (server, api) async {
        final order = await api.checkout(
          address: '221B Baker Street',
          cardNumber: CheckoutScreen.seededCardNumber,
          cvv: CheckoutScreen.seededCvv,
          otp: CheckoutScreen.seededOtp,
        );

        expect(order.orderId, 'ORD-20260912-0001');
        expect(server.exchanges.single.method, 'POST');
      });
    });

    test('a declined card is a 402, not a crash', () async {
      await withServer('checkout_declined', (server, api) async {
        final failure = await failureOf(
          () => api.checkout(
            address: 'x',
            cardNumber: CheckoutScreen.seededCardNumber,
            cvv: CheckoutScreen.seededCvv,
            otp: CheckoutScreen.seededOtp,
          ),
        );

        expect(failure.statusCode, 402);

        matrix.add([
          'card declined',
          'checkout_declined',
          '402',
          '402',
          'payment refused',
          failure.userMessage,
        ]);
      });
    });

    test('an order with no ETA still parses', () async {
      await withServer('order_no_eta', (server, api) async {
        final order = await api.checkout(
          address: 'x',
          cardNumber: '4111111111111111',
          cvv: '731',
          otp: '884512',
        );

        expect(order.etaMinutes, isNull);
        // A null ETA must produce words, not "null minutes".
        expect(order.etaText, isNot(contains('null')));
      });
    });
  });
}
