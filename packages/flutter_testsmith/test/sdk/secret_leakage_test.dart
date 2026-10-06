import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// Phase 12, brief item 10 - seeded secrets, and where they must never
/// appear.
///
/// The assertion is deliberately crude: **search the serialised event
/// for the literal**. Checking that the right keys were redacted only
/// proves the redactor did what it was told; searching the bytes proves
/// the secret is not there by some route nobody thought of - a nested
/// object, an array element, a URL parameter, an unparseable body.

/// One seeded credential and where the application puts it.
class Seed {
  const Seed(this.name, this.value, this.where);

  final String name;
  final String value;
  final String where;
}

const List<Seed> seeds = [
  Seed('authorization token', 'Bearer SEEDED_ACCESS_TOKEN_8a17fc',
      'request header'),
  Seed('password', 'SEEDED_PASSWORD_c41e77b0', 'request body'),
  Seed('access token', 'SEEDED_ACCESS_TOKEN_8a17fc', 'response body'),
  Seed('refresh token', 'SEEDED_REFRESH_TOKEN_20b93e', 'response body'),
  Seed('OTP', '884512', 'request body'),
  Seed('card number', '4111111111111111', 'request body'),
  Seed('CVV', '731', 'request body'),
  Seed('session cookie', 'MOCK_SESSION_SECRET', 'response header'),
];

/// Captures one exchange and returns every emitted event, serialised.
///
/// Serialised rather than inspected field by field: what matters is
/// whether the bytes that leave the process contain the secret.
List<String> captureExchange({
  Map<String, String> requestHeaders = const {},
  String? requestBody,
  Map<String, String> responseHeaders = const {},
  String? responseBody,
  TestSdkConfig? config,
}) {
  final emitted = <EventPayload>[];
  final capture = NetworkCapture(
    config: config ??
        const TestSdkConfig(
          enabled: true,
          redaction: RedactionPolicy.strictDefaults(),
        ),
    emit: emitted.add,
  );

  final id = capture.begin(
    method: 'POST',
    url: Uri.parse('http://127.0.0.1:8080/checkout'),
    headers: requestHeaders,
    body: requestBody,
  );
  capture.complete(
    id,
    statusCode: 200,
    headers: responseHeaders,
    body: responseBody,
  );

  return [for (final payload in emitted) jsonEncode(payload.toJson())];
}

void main() {
  obscuredFieldTests();
  maskedSubtreeTests();
  group('a seeded secret never reaches an emitted event', () {
    test('an authorization header is replaced, and the name is kept', () {
      final events = captureExchange(
        requestHeaders: {
          'authorization': 'Bearer SEEDED_ACCESS_TOKEN_8a17fc',
          'x-device-secret': 'DEVICE_SECRET_9f2a41c8',
          'accept': 'application/json',
        },
      );

      final request = events.first;
      expect(request, isNot(contains('SEEDED_ACCESS_TOKEN_8a17fc')));
      expect(request, isNot(contains('DEVICE_SECRET_9f2a41c8')));
      // Knowing a request was authenticated is useful; knowing the
      // token is not. The header name survives, the value does not.
      expect(request, contains('authorization'));
      expect(request, contains('[REDACTED]'));
      // Something innocent is untouched, so this is redaction rather
      // than deletion.
      expect(request, contains('application/json'));
    });

    test('a password in a request body is replaced', () {
      final events = captureExchange(
        requestBody: jsonEncode({
          'email': 'test.user@example.com',
          'password': 'SEEDED_PASSWORD_c41e77b0',
        }),
      );

      expect(events.first, isNot(contains('SEEDED_PASSWORD_c41e77b0')));
      expect(events.first, contains('test.user@example.com'));
    });

    test('a token and a refresh token in a response body are replaced', () {
      final events = captureExchange(
        responseBody: jsonEncode({
          'token': 'SEEDED_ACCESS_TOKEN_8a17fc',
          'refreshToken': 'SEEDED_REFRESH_TOKEN_20b93e',
          'user': {'name': 'Test User'},
        }),
      );

      final response = events.last;
      expect(response, isNot(contains('SEEDED_ACCESS_TOKEN_8a17fc')));
      expect(response, isNot(contains('SEEDED_REFRESH_TOKEN_20b93e')));
      expect(response, contains('Test User'));
    });

    test('card number, CVV and OTP in a request body are replaced', () {
      final events = captureExchange(
        requestBody: jsonEncode({
          'address': '221B Baker Street',
          'cardNumber': '4111111111111111',
          'cvv': '731',
          'otp': '884512',
        }),
      );

      final request = events.first;
      for (final secret in ['4111111111111111', '731', '884512']) {
        expect(request, isNot(contains(secret)), reason: secret);
      }
      expect(request, contains('221B Baker Street'));
    });

    test('a set-cookie header is replaced', () {
      final events = captureExchange(
        responseHeaders: {
          'set-cookie': 'session=MOCK_SESSION_SECRET; HttpOnly',
          'content-type': 'application/json',
        },
      );

      expect(events.last, isNot(contains('MOCK_SESSION_SECRET')));
    });

    test('a secret nested inside an object is replaced', () {
      // Key-by-key checking of the top level would miss this.
      final events = captureExchange(
        responseBody: jsonEncode({
          'session': {
            'credentials': {'accessToken': 'SEEDED_ACCESS_TOKEN_8a17fc'},
          },
        }),
      );

      expect(events.last, isNot(contains('SEEDED_ACCESS_TOKEN_8a17fc')));
    });

    test('a secret inside an array element is replaced', () {
      final events = captureExchange(
        responseBody: jsonEncode({
          'devices': [
            {'id': 1, 'refresh_token': 'SEEDED_REFRESH_TOKEN_20b93e'},
          ],
        }),
      );

      expect(events.last, isNot(contains('SEEDED_REFRESH_TOKEN_20b93e')));
    });

    test('a body that does not parse but looks credential-shaped is dropped '
        'whole', () {
      // It cannot be inspected key by key, so it cannot be shown to be
      // safe. Dropping it is the conservative choice and the reason is
      // recorded in its place.
      final events = captureExchange(
        responseBody: 'password=SEEDED_PASSWORD_c41e77b0&user=testuser',
      );

      expect(events.last, isNot(contains('SEEDED_PASSWORD_c41e77b0')));
      expect(events.last, contains('[REDACTED]'));
      expect(events.last, contains('unparseable'));
    });

    test('every seeded secret at once, in one exchange', () {
      final events = captureExchange(
        requestHeaders: {
          'authorization': 'Bearer SEEDED_ACCESS_TOKEN_8a17fc',
          'x-device-secret': 'DEVICE_SECRET_9f2a41c8',
        },
        requestBody: jsonEncode({
          'password': 'SEEDED_PASSWORD_c41e77b0',
          'cardNumber': '4111111111111111',
          'cvv': '731',
          'otp': '884512',
        }),
        responseHeaders: {
          'set-cookie': 'session=MOCK_SESSION_SECRET; HttpOnly',
        },
        responseBody: jsonEncode({
          'token': 'SEEDED_ACCESS_TOKEN_8a17fc',
          'refreshToken': 'SEEDED_REFRESH_TOKEN_20b93e',
        }),
      );

      final everything = events.join('\n');
      for (final seed in seeds) {
        expect(
          everything,
          isNot(contains(seed.value)),
          reason: '${seed.name} leaked from its ${seed.where}',
        );
      }
    });
  });

  group('redaction happens at capture, not at reporting', () {
    test('the payload object itself already holds the marker', () {
      // This is the whole argument for doing it here. A secret that
      // never enters an event cannot leak from a report, a log, a crash
      // dump or a bug someone files with a screenshot of their console.
      final emitted = <EventPayload>[];
      NetworkCapture(
        config: const TestSdkConfig(enabled: true),
        emit: emitted.add,
      ).begin(
        method: 'GET',
        url: Uri.parse('http://x/y'),
        headers: {'authorization': 'Bearer SEEDED_ACCESS_TOKEN_8a17fc'},
      );

      final request = emitted.single as ApiRequestPayload;
      expect(request.headers['authorization'], '[REDACTED]');
    });

    test('nothing downstream has to remember to redact', () {
      // The payload is already clean, so a consumer that simply prints
      // it is safe. Any design where the report does the redacting is
      // strictly weaker: it only protects the reports someone thought
      // of.
      final emitted = <EventPayload>[];
      NetworkCapture(
        config: const TestSdkConfig(enabled: true),
        emit: emitted.add,
      ).begin(
        method: 'POST',
        url: Uri.parse('http://x/y'),
        body: jsonEncode({'cvv': '731'}),
      );

      expect(
        (emitted.single as ApiRequestPayload).body,
        isNot(contains('731')),
      );
    });
  });

  group('what redaction does not claim', () {
    test('an excluded endpoint is not captured at all', () {
      final emitted = <EventPayload>[];
      final capture = NetworkCapture(
        config: const TestSdkConfig(
          enabled: true,
          redaction: RedactionPolicy(
            sensitiveKeys: {},
            excludedPaths: {'/auth'},
          ),
        ),
        emit: emitted.add,
      );

      expect(
        capture.begin(method: 'POST', url: Uri.parse('http://x/auth/login')),
        isNull,
      );
      expect(emitted, isEmpty);
    });

    test('an endpoint is still named, so a report can say what was called',
        () {
      final events = captureExchange();
      expect(events.first, contains('/checkout'));
    });

    test('a truncated body records that it was truncated', () {
      // A report showing half a response as though it were the whole
      // thing is worse than one that says it was truncated.
      final emitted = <EventPayload>[];
      NetworkCapture(
        config: const TestSdkConfig(enabled: true, maxBodyBytes: 20),
        emit: emitted.add,
      ).begin(
        method: 'POST',
        url: Uri.parse('http://x/y'),
        body: jsonEncode({'note': 'a' * 200}),
      );

      expect((emitted.single as ApiRequestPayload).bodyTruncated, isTrue);
    });
  });

  urlQueryTests();
}

/// Limitation L3: a credential in a query string, which used to be the
/// one route out.
///
/// Phase 12 recorded it as limitation L3 and asserted the leak with a
/// passing test, "so that fixing it makes a test fail and the
/// documentation gets updated". That test is now this group: the same
/// seeded token, the opposite expectation.
///
/// Per parameter rather than dropping the query, for the reason headers
/// keep their names - `?page=2` is diagnostic, and a report that cannot
/// say which page was asked for has lost something for nothing.
void urlQueryTests() {
  /// The `url` of the one event [url] produces.
  String captured(String url, {RedactionPolicy? redaction}) {
    final emitted = <EventPayload>[];
    NetworkCapture(
      config: TestSdkConfig(
        enabled: true,
        redaction: redaction ?? const RedactionPolicy.strictDefaults(),
      ),
      emit: emitted.add,
    ).begin(method: 'GET', url: Uri.parse(url));
    return (emitted.single as ApiRequestPayload).url;
  }

  group('a credential in the query string', () {
    test('is masked, and nothing else about the request is lost', () {
      final url = captured('http://x/y?token=SEEDED_ACCESS_TOKEN_8a17fc');

      expect(url, isNot(contains('SEEDED_ACCESS_TOKEN_8a17fc')));
      // Each half matters on its own. Without the marker the value might
      // merely have been dropped; without the name a reader cannot tell
      // an authenticated request from an anonymous one.
      expect(url, contains('[REDACTED]'));
      expect(url, contains('token='));
      expect(url, startsWith('http://x/y?'));
    });

    test('and the seeded token is absent from the serialised event', () {
      // The crude assertion this file is built on: search the bytes that
      // leave the process, not the fields somebody remembered to check.
      final emitted = <EventPayload>[];
      NetworkCapture(
        config: const TestSdkConfig(
          enabled: true,
          redaction: RedactionPolicy.strictDefaults(),
        ),
        emit: emitted.add,
      ).begin(
        method: 'GET',
        url: Uri.parse('http://x/y?access_token=SEEDED_ACCESS_TOKEN_8a17fc'),
      );

      expect(
        jsonEncode(emitted.single.toJson()),
        isNot(contains('SEEDED_ACCESS_TOKEN_8a17fc')),
      );
    });

    test('is recognised however the application spells it', () {
      // The normalisation `isSensitive` already applies to headers and
      // JSON keys. A second spelling rule for URLs is exactly how two
      // rules start disagreeing.
      final url = captured(
        'http://x/y?access_token=A&access-token=B&accessToken=C&apiKey=D',
      );

      for (final value in const ['A', 'B', 'C', 'D']) {
        expect(url, isNot(contains('=$value')), reason: url);
      }
    });

    test('every occurrence of a repeated parameter is masked', () {
      // `queryParameters` keeps only the last; redacting through it
      // would have left the first in the clear.
      final url = captured('http://x/y?token=ONE&token=TWO');

      expect(url, isNot(contains('ONE')), reason: url);
      expect(url, isNot(contains('TWO')), reason: url);
    });
  });

  group('and what it must not touch', () {
    test('an ordinary parameter is still readable', () {
      expect(captured('http://x/y?page=2&sort=asc'),
          'http://x/y?page=2&sort=asc');
    });

    test('only the sensitive one changes, in place', () {
      expect(
        captured('http://x/y?page=2&token=SEED&sort=asc'),
        'http://x/y?page=2&token=[REDACTED]&sort=asc',
      );
    });

    test('a URL with no query is byte-identical', () {
      expect(captured('http://x/y'), 'http://x/y');
    });

    test('an empty value and a bare name survive untouched', () {
      // `queryParametersAll` drops both, so rebuilding a URL through it
      // would silently rewrite a request nobody had a secret in.
      expect(captured('http://x/y?a=&raw&t=1&t=2'),
          'http://x/y?a=&raw&t=1&t=2');
    });

    test('an empty sensitive value does not throw, and is still masked', () {
      expect(captured('http://x/y?token=&page=2'),
          'http://x/y?token=[REDACTED]&page=2');
    });

    test('the fragment and the rest of the URL are kept', () {
      expect(
        captured('http://x:8080/a/b?token=SEED&page=2#section'),
        'http://x:8080/a/b?token=[REDACTED]&page=2#section',
      );
    });

    test('a secret-looking value inside another value is not a parameter',
        () {
      // Only names are judged. Treating an encoded `token=` inside a
      // value as a parameter would redact a request that has no
      // credential in it at all.
      expect(
        captured('http://x/y?filter=a%3Db%26token%3DNOTASECRET'),
        'http://x/y?filter=a%3Db%26token%3DNOTASECRET',
      );
    });

    test('allowedKeys lets a named parameter through, as it does a header',
        () {
      // The override that already exists. A parameter someone has
      // declared safe must behave the same way in a URL as in a header.
      final url = captured(
        'http://x/y?token=PUBLIC_FEED_ID',
        redaction: const RedactionPolicy(
          sensitiveKeys: {'token'},
          allowedKeys: {'token'},
        ),
      );

      expect(url, 'http://x/y?token=PUBLIC_FEED_ID');
    });
  });
}

/// Phase 12, found by reading a real capture from the device: the UI
/// tree carried an obscured field's contents in plaintext.
///
/// `TextField #login.password "SEEDED_PASSWORD_c41e77b0"` - on a screen
/// that was showing dots. Network capture had been redacting since
/// Phase 3; nothing had ever looked at this path, and the tree leaves
/// the process as a WIDGET_TREE event and through
/// `testsmith inspect --json`.
void obscuredFieldTests() {
  Future<UiSnapshot> capture(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: child)),
    );
    await tester.pumpAndSettle();

    return const UiTreeInspector().capture(
      root: tester.binding.rootElement!,
      screenId: '/login',
      devicePixelRatio: 2,
    );
  }

  group('an obscured field', () {
    testWidgets('is redacted in the captured tree', (tester) async {
      final snapshot = await capture(
        tester,
        TextField(
          key: const TestKey('login.password'),
          obscureText: true,
          controller:
              TextEditingController(text: 'SEEDED_PASSWORD_c41e77b0'),
        ),
      );

      expect(
        jsonEncode(snapshot.toJson()),
        isNot(contains('SEEDED_PASSWORD_c41e77b0')),
        reason: 'the whole subtree, not just the node carrying the id',
      );
      expect(snapshot.find('login.password')?.text, '[REDACTED]:24');
    });

    testWidgets('keeps its length, which is not part of the secret',
        (tester) async {
      // "the field is empty" and "the field has something in it" is a
      // distinction a test legitimately needs.
      final snapshot = await capture(
        tester,
        TextField(
          key: const TestKey('p'),
          obscureText: true,
          controller: TextEditingController(text: 'abc'),
        ),
      );

      expect(snapshot.find('p')?.text, '[REDACTED]:3');
    });

    testWidgets('an empty obscured field stays empty', (tester) async {
      final snapshot = await capture(
        tester,
        TextField(
          key: const TestKey('p'),
          obscureText: true,
          controller: TextEditingController(),
        ),
      );

      expect(snapshot.find('p')?.text, '');
    });

    testWidgets('a field that is NOT obscured is untouched', (tester) async {
      // Redacting every text field would make the platform useless for
      // the thing it exists to do.
      final snapshot = await capture(
        tester,
        TextField(
          key: const TestKey('login.email'),
          controller: TextEditingController(text: 'test.user@example.com'),
        ),
      );

      expect(snapshot.find('login.email')?.text, 'test.user@example.com');
    });

    testWidgets('an ordinary Text is untouched', (tester) async {
      final snapshot = await capture(
        tester,
        const Text('Rs 4,129', key: TestKey('total')),
      );

      expect(snapshot.find('total')?.text, 'Rs 4,129');
    });
  });
}

/// Step 8 of the property-resolution milestone: descendant traversal
/// must not reach around the masking that capture applied.
///
/// Asserted on a real widget tree rather than a hand-built node, so the
/// thing under test is what the device would actually produce.
void maskedSubtreeTests() {
  Future<UiSnapshot> capture(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();

    return const UiTreeInspector().capture(
      root: tester.binding.rootElement!,
      screenId: '/login',
      devicePixelRatio: 2,
    );
  }

  group('a semantic id wrapping a sensitive field', () {
    for (final (name, secret) in [
      ('password', 'SEEDED_PASSWORD_c41e77b0'),
      ('OTP', '884512'),
      ('card number', '4111111111111111'),
      ('CVV', '731'),
      ('authorization token', 'SEEDED_ACCESS_TOKEN_8a17fc'),
    ]) {
      testWidgets('$name never appears anywhere in the subtree',
          (tester) async {
        final snapshot = await capture(
          tester,
          TestId(
            id: 'field.wrapper',
            child: TextField(
              obscureText: true,
              controller: TextEditingController(text: secret),
            ),
          ),
        );

        // The whole serialised subtree, not just the node with the id.
        expect(jsonEncode(snapshot.toJson()), isNot(contains(secret)));

        final node = snapshot.find('field.wrapper')!;
        expect(node.text, isNull, reason: 'the wrapper renders nothing');
      });
    }

    testWidgets('a label beside a masked field does not leak it either',
        (tester) async {
      final snapshot = await capture(
        tester,
        TestId(
          id: 'row',
          child: Column(
            children: [
              const Text('Password'),
              TextField(
                obscureText: true,
                controller:
                    TextEditingController(text: 'SEEDED_PASSWORD_c41e77b0'),
              ),
            ],
          ),
        ),
      );

      expect(
        jsonEncode(snapshot.toJson()),
        isNot(contains('SEEDED_PASSWORD_c41e77b0')),
      );
    });

    testWidgets('a field the application did NOT obscure is still readable',
        (tester) async {
      // Redaction must not become a blanket refusal to read text.
      final snapshot = await capture(
        tester,
        TestId(
          id: 'email',
          child: TextField(
            controller: TextEditingController(text: 'test.user@example.com'),
          ),
        ),
      );

      expect(
        jsonEncode(snapshot.toJson()),
        contains('test.user@example.com'),
      );
    });
  });
}
