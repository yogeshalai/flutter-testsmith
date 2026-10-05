import 'dart:convert';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// STOP-1: validating a screen against a response captured before it.
///
/// The measured problem, from external-application validation: a profile
/// screen renders the consumer's name, and the request that fetched it
/// happened during splash. The screen itself calls nothing, so
/// `api-to-ui` reported
///
///   the mappings name "GET /api/profile/me", which this screen
///   did not call. It called: GET /v4beta/geocode/location/18.54,73.78
///
/// Across four screens of that application, **no screen captured the
/// response it rendered**.
///
/// These tests are written against the declaration this milestone adds.
/// They fail before it exists, which is the point.

// ─────────────────────────────────────────────────────────── builders

DateTime at(int second) => DateTime.utc(2026, 9, 12, 10, 0, second);

ApiExchange exchange({
  required String method,
  required String path,
  required Map<String, Object?> body,
  required int second,
  String? requestId,
  int statusCode = 200,
}) {
  final id = requestId ?? '$method $path@$second';
  return ApiExchange(
    request: ApiRequestPayload(
      requestId: id,
      method: method,
      url: 'https://api.example.com$path',
    ),
    requestedAt: at(second),
    response: ApiResponsePayload(
      requestId: id,
      statusCode: statusCode,
      body: jsonEncode(body),
      durationMs: 12,
    ),
    respondedAt: at(second),
  );
}

ScreenSession screen(
  String id, {
  required int enteredAt,
  List<ApiExchange> exchanges = const [],
  UiSnapshot? snapshot,
}) {
  final session = ScreenSession(screenId: id, enteredAt: at(enteredAt))
    ..uiSnapshot = snapshot;
  session.exchanges.addAll(exchanges);
  return session;
}

UiSnapshot treeWith(Map<String, String> texts) => UiSnapshot(
      screenId: '/profile',
      capturedAt: at(30),
      devicePixelRatio: 2,
      viewport: const LogicalRect(x: 0, y: 0, width: 400, height: 800),
      root: UiNode(
        type: 'Root',
        bounds: const LogicalRect(x: 0, y: 0, width: 400, height: 800),
        children: [
          for (final entry in texts.entries)
            UiNode(
              testId: entry.key,
              type: 'Text',
              text: entry.value,
              bounds: const LogicalRect(x: 0, y: 0, width: 100, height: 20),
            ),
        ],
      ),
    );

MappingsFile mappingsFrom(String yaml) =>
    MappingsFile.parse(yaml, source: 'provenance.yaml');

/// A context over a whole session history, as the runner now builds one.
ValidationContext contextOver({
  required List<ScreenSession> history,
  required String currentScreen,
  required MappingsFile mappings,
}) {
  final current = history.lastWhere((s) => s.screenId == currentScreen);
  return ValidationContext(
    session: current,
    sessionHistory: history,
    mappings: mappings,
  );
}

/// The production path, not `validate` directly.
///
/// `runValidator` is what stamps the validator's own dimension onto each
/// result, and `FlowExecutor` uses nothing else. Calling `validate` here
/// produced unstamped results that a report now refuses - which is the
/// invariant doing its job, and the reason this helper goes the way the
/// runner goes.
List<ValidationResult> validateApi(ValidationContext context) =>
    runValidator(const ApiToUiValidator(), context);

String? evidenceOf(ValidationResult result, String kind) {
  for (final item in result.evidence) {
    if (item.kind == kind) return item.reference;
  }
  return null;
}

// ───────────────────────────────────────────────────────────── yaml

const String declaredProfile = '''
screen: /profile
usesResponseFrom:
  endpoint: GET /api/profile/me
mappings:
  - target: profile.display_name
    source: response.data.firstName
''';

void main() {
  // ── 1 ──────────────────────────────────────────────────────────
  group('1. the response was captured before the screen was entered', () {
    test('it is found, and the comparison passes', () {
      final history = [
        screen('/', enteredAt: 0, exchanges: [
          exchange(
            method: 'GET',
            path: '/api/profile/me',
            body: {
              'data': {'firstName': 'Test'},
            },
            second: 5,
          ),
        ]),
        screen('/profile',
            enteredAt: 20,
            snapshot: treeWith({'profile.display_name': 'Test'})),
      ];

      final report = ValidationReport(
        validateApi(contextOver(
          history: history,
          currentScreen: '/profile',
          mappings: mappingsFrom(declaredProfile),
        )),
      );

      expect(report.passed, isTrue, reason: '${report.failures}');
      expect(report.passCount, 1);
    });

    test('the report names the screen the data came from', () {
      // The acceptance requirement: source screen != rendered screen,
      // stated in the result rather than inferred by a reader.
      final history = [
        screen('/', enteredAt: 0, exchanges: [
          exchange(
            method: 'GET',
            path: '/api/profile/me',
            body: {
              'data': {'firstName': 'Test'},
            },
            second: 5,
            requestId: 'req-42',
          ),
        ]),
        screen('/profile',
            enteredAt: 20,
            snapshot: treeWith({'profile.display_name': 'Test'})),
      ];

      final result = validateApi(contextOver(
        history: history,
        currentScreen: '/profile',
        mappings: mappingsFrom(declaredProfile),
      )).single;

      expect(evidenceOf(result, 'sourceEndpoint'),
          'GET /api/profile/me');
      expect(evidenceOf(result, 'sourceScreen'), '/');
      expect(evidenceOf(result, 'sourceCapturedAt'), contains('10:00:05'));
      expect(evidenceOf(result, 'sourceRequestId'), 'req-42');
      expect(evidenceOf(result, 'sourceScreen'),
          isNot(equals(evidenceOf(result, 'renderedScreen'))));
    });
  });

  // ── 2 ──────────────────────────────────────────────────────────
  test('2. unrelated responses on the way do not confuse it', () {
    final history = [
      screen('/', enteredAt: 0, exchanges: [
        exchange(
            method: 'GET',
            path: '/appconfig',
            body: {'data': 1},
            second: 2),
        exchange(
          method: 'GET',
          path: '/api/profile/me',
          body: {
            'data': {'firstName': 'Test'},
          },
          second: 5,
        ),
        exchange(
            method: 'GET',
            path: '/v4beta/geocode/location/18.5,73.7',
            body: {'data': 2},
            second: 7),
      ]),
      screen('/home', enteredAt: 10, exchanges: [
        exchange(
            method: 'GET',
            path: '/api/dashboard/summary',
            body: {'data': 3},
            second: 12),
      ]),
      screen('/profile',
          enteredAt: 20,
          snapshot: treeWith({'profile.display_name': 'Test'})),
    ];

    final report = ValidationReport(
      validateApi(contextOver(
        history: history,
        currentScreen: '/profile',
        mappings: mappingsFrom(declaredProfile),
      )),
    );

    expect(report.passed, isTrue, reason: '${report.failures}');
  });

  // ── 3 & 6 ──────────────────────────────────────────────────────
  group('3. the same endpoint was called more than once', () {
    final twice = [
      screen('/', enteredAt: 0, exchanges: [
        exchange(
          method: 'GET',
          path: '/api/profile/me',
          body: {
            'data': {'firstName': 'Test'},
          },
          second: 5,
        ),
      ]),
      screen('/home', enteredAt: 10, exchanges: [
        exchange(
          method: 'GET',
          path: '/api/profile/me',
          body: {
            'data': {'firstName': 'Test User'},
          },
          second: 12,
        ),
      ]),
      screen('/profile',
          enteredAt: 20,
          snapshot: treeWith({'profile.display_name': 'Test User'})),
    ];

    test('6. by default that is ambiguous, and an ERROR', () {
      // Not "the newest one will do". Choosing by recency alone is the
      // silent-staleness failure this whole mechanism exists to avoid.
      final result = validateApi(contextOver(
        history: twice,
        currentScreen: '/profile',
        mappings: mappingsFrom(declaredProfile),
      )).single;

      expect(result.status, ValidationStatus.error);
      expect(result.message, contains('2'));
      expect(result.message.toLowerCase(), contains('ambiguous'));
    });

    test('the error names every candidate, so it can be disambiguated', () {
      final result = validateApi(contextOver(
        history: twice,
        currentScreen: '/profile',
        mappings: mappingsFrom(declaredProfile),
      )).single;

      expect(result.message, contains('/'));
      expect(result.message, contains('/home'));
    });

    test('an explicit occurrence resolves it', () {
      final result = validateApi(contextOver(
        history: twice,
        currentScreen: '/profile',
        mappings: mappingsFrom('''
screen: /profile
usesResponseFrom:
  endpoint: GET /api/profile/me
  occurrence: last
mappings:
  - target: profile.display_name
    source: response.data.firstName
'''),
      )).single;

      expect(result.status, ValidationStatus.pass);
      expect(evidenceOf(result, 'sourceScreen'), '/home');
    });

    test('occurrence: first picks the earliest, not the newest', () {
      final result = validateApi(contextOver(
        history: twice,
        currentScreen: '/profile',
        mappings: mappingsFrom('''
screen: /profile
usesResponseFrom:
  endpoint: GET /api/profile/me
  occurrence: first
mappings:
  - target: profile.display_name
    source: response.data.firstName
'''),
      )).single;

      // The UI shows "Test User"; the first response said "Test". A
      // deliberate mismatch, to prove the declaration chose the earlier
      // one rather than whichever made the test pass.
      expect(result.status, ValidationStatus.fail);
      expect(evidenceOf(result, 'sourceScreen'), '/');
      expect(evidenceOf(result, 'apiValue'), 'Test');
    });

    test('capturedOn narrows to one screen', () {
      final result = validateApi(contextOver(
        history: twice,
        currentScreen: '/profile',
        mappings: mappingsFrom('''
screen: /profile
usesResponseFrom:
  endpoint: GET /api/profile/me
  capturedOn: /home
mappings:
  - target: profile.display_name
    source: response.data.firstName
'''),
      )).single;

      expect(result.status, ValidationStatus.pass);
      expect(evidenceOf(result, 'sourceScreen'), '/home');
    });
  });

  // ── 4 ──────────────────────────────────────────────────────────
  test('4. one response can serve several screens', () {
    // A cached profile renders on both /profile and /home. Neither
    // consumes it; a response is not spent by being read.
    final history = [
      screen('/', enteredAt: 0, exchanges: [
        exchange(
          method: 'GET',
          path: '/api/profile/me',
          body: {
            'data': {'firstName': 'Test'},
          },
          second: 5,
        ),
      ]),
      screen('/home',
          enteredAt: 10, snapshot: treeWith({'home.greeting': 'Test'})),
      screen('/profile',
          enteredAt: 20,
          snapshot: treeWith({'profile.display_name': 'Test'})),
    ];

    for (final (currentScreen, target) in [
      ('/home', 'home.greeting'),
      ('/profile', 'profile.display_name'),
    ]) {
      final report = ValidationReport(
        validateApi(contextOver(
          history: history,
          currentScreen: currentScreen,
          mappings: mappingsFrom('''
screen: $currentScreen
usesResponseFrom:
  endpoint: GET /api/profile/me
mappings:
  - target: $target
    source: response.data.firstName
'''),
        )),
      );

      expect(report.passed, isTrue,
          reason: '$currentScreen: ${report.failures}');
    }
  });

  // ── 5 ──────────────────────────────────────────────────────────
  group('5. the declared endpoint was never captured', () {
    test('it is an ERROR, not a FAIL', () {
      // Missing source data is not evidence the application is wrong.
      final history = [
        screen('/', enteredAt: 0, exchanges: [
          exchange(
              method: 'GET',
              path: '/appconfig',
              body: {'data': 1},
              second: 2),
        ]),
        screen('/profile',
            enteredAt: 20,
            snapshot: treeWith({'profile.display_name': 'Test'})),
      ];

      final report = ValidationReport(
        validateApi(contextOver(
          history: history,
          currentScreen: '/profile',
          mappings: mappingsFrom(declaredProfile),
        )),
      );

      expect(report.errorCount, 1);
      expect(report.failCount, 0);
      expect(report.passed, isFalse, reason: 'an error still blocks a pass');
    });

    test('and says what the session did capture', () {
      final history = [
        screen('/', enteredAt: 0, exchanges: [
          exchange(
              method: 'GET',
              path: '/appconfig',
              body: {'data': 1},
              second: 2),
        ]),
        screen('/profile',
            enteredAt: 20,
            snapshot: treeWith({'profile.display_name': 'Test'})),
      ];

      final result = validateApi(contextOver(
        history: history,
        currentScreen: '/profile',
        mappings: mappingsFrom(declaredProfile),
      )).single;

      expect(result.message, contains('/appconfig'));
      expect(result.message, contains('anywhere in this session'));
    });
  });

  // ── 7 ──────────────────────────────────────────────────────────
  test('7. a response captured on another screen is usable and labelled',
      () {
    final history = [
      screen('/', enteredAt: 0),
      screen('/home', enteredAt: 10, exchanges: [
        exchange(
          method: 'GET',
          path: '/api/profile/me',
          body: {
            'data': {'firstName': 'Test'},
          },
          second: 12,
        ),
      ]),
      screen('/profile',
          enteredAt: 20,
          snapshot: treeWith({'profile.display_name': 'Test'})),
    ];

    final result = validateApi(contextOver(
      history: history,
      currentScreen: '/profile',
      mappings: mappingsFrom(declaredProfile),
    )).single;

    expect(result.status, ValidationStatus.pass);
    expect(evidenceOf(result, 'sourceScreen'), '/home');
    expect(evidenceOf(result, 'renderedScreen'), '/profile');
  });

  // ── 8 ──────────────────────────────────────────────────────────
  test('8. raw, transformed and UI values are all reported', () {
    final history = [
      screen('/', enteredAt: 0, exchanges: [
        exchange(
          method: 'GET',
          path: '/api/cart',
          body: {'total': 4129},
          second: 5,
        ),
      ]),
      screen('/checkout',
          enteredAt: 20, snapshot: treeWith({'checkout.total': 'Rs 4,129'})),
    ];

    final result = validateApi(contextOver(
      history: history,
      currentScreen: '/checkout',
      mappings: mappingsFrom('''
screen: /checkout
usesResponseFrom:
  endpoint: GET /api/cart
mappings:
  - target: checkout.total
    source: response.total
    transformation: currency(INR)
'''),
    )).single;

    expect(result.status, ValidationStatus.pass);
    expect(evidenceOf(result, 'apiValue'), '4129');
    expect(evidenceOf(result, 'transformation'), 'currency(INR)');
    expect(evidenceOf(result, 'transformedValue'), 'Rs 4,129');
    expect(evidenceOf(result, 'uiValue'), 'Rs 4,129');
  });

  // ── 9 ──────────────────────────────────────────────────────────
  group('9. stale response protection', () {
    List<ScreenSession> historyWithGap(int capturedAt, int screenEnteredAt) => [
          screen('/', enteredAt: 0, exchanges: [
            exchange(
              method: 'GET',
              path: '/api/profile/me',
              body: {
                'data': {'firstName': 'Test'},
              },
              second: capturedAt,
            ),
          ]),
          screen('/profile',
              enteredAt: screenEnteredAt,
              snapshot: treeWith({'profile.display_name': 'Test'})),
        ];

    const withLimit = '''
screen: /profile
usesResponseFrom:
  endpoint: GET /api/profile/me
  maxAgeSeconds: 60
mappings:
  - target: profile.display_name
    source: response.data.firstName
''';

    test('a response inside the declared age is used', () {
      final result = validateApi(contextOver(
        history: historyWithGap(5, 40),
        currentScreen: '/profile',
        mappings: mappingsFrom(withLimit),
      )).single;

      expect(result.status, ValidationStatus.pass);
    });

    test('a response older than the declared age is an ERROR', () {
      // Not a FAIL: the application may be perfectly correct, and what
      // is wrong is that nothing recent enough was captured to judge it.
      final result = validateApi(contextOver(
        history: historyWithGap(5, 400),
        currentScreen: '/profile',
        mappings: mappingsFrom(withLimit),
      )).single;

      expect(result.status, ValidationStatus.error);
      expect(result.message.toLowerCase(), contains('older'));
      expect(result.message, contains('60'));
    });

    test('the age is reported even when it is within the limit', () {
      final result = validateApi(contextOver(
        history: historyWithGap(5, 40),
        currentScreen: '/profile',
        mappings: mappingsFrom(withLimit),
      )).single;

      expect(evidenceOf(result, 'sourceAgeSeconds'), '35');
    });

    test('a response captured after the screen was entered is still used, '
        'and its age is zero rather than negative', () {
      // The screen refetched on entry. Provenance still applies.
      final result = validateApi(contextOver(
        history: historyWithGap(50, 40),
        currentScreen: '/profile',
        mappings: mappingsFrom(withLimit),
      )).single;

      expect(result.status, ValidationStatus.pass);
      expect(evidenceOf(result, 'sourceAgeSeconds'), '0');
    });
  });

  // ── 10 ─────────────────────────────────────────────────────────
  group('10. nothing changes for a screen that fetches its own data', () {
    const sameScreen = '''
screen: /product/details
api: GET /products/123
mappings:
  - target: product.price
    source: response.price
    transformation: currency(INR)
''';

    test('the same-screen response is still used', () {
      final history = [
        screen('/product/details', enteredAt: 0, exchanges: [
          exchange(
              method: 'GET',
              path: '/products/123',
              body: {'price': 90},
              second: 1),
        ], snapshot: treeWith({'product.price': 'Rs 90'})),
      ];

      final result = validateApi(contextOver(
        history: history,
        currentScreen: '/product/details',
        mappings: mappingsFrom(sameScreen),
      )).single;

      expect(result.status, ValidationStatus.pass);
    });

    test('an earlier response on another screen is NOT silently used', () {
      // Without a declaration, provenance stays off. A screen that says
      // nothing about where its data comes from must not start
      // borrowing it from elsewhere.
      final history = [
        screen('/', enteredAt: 0, exchanges: [
          exchange(
              method: 'GET',
              path: '/products/123',
              body: {'price': 90},
              second: 1),
        ]),
        screen('/product/details',
            enteredAt: 10, snapshot: treeWith({'product.price': 'Rs 90'})),
      ];

      final result = validateApi(contextOver(
        history: history,
        currentScreen: '/product/details',
        mappings: mappingsFrom(sameScreen),
      )).single;

      expect(result.status, ValidationStatus.error);
      // An error about *this* screen's own missing exchange - not a
      // quiet borrow of the one captured on "/".
      expect(result.message, contains('GET /products/123'));
      expect(result.message, isNot(contains('captured on')));
    });

    test('a screen with no api: and no declaration still takes its own '
        'first response', () {
      final history = [
        screen('/s', enteredAt: 0, exchanges: [
          exchange(
              method: 'GET', path: '/x', body: {'name': 'here'}, second: 1),
        ], snapshot: treeWith({'a': 'here'})),
      ];

      final result = validateApi(contextOver(
        history: history,
        currentScreen: '/s',
        mappings: mappingsFrom('''
screen: /s
mappings:
  - target: a
    source: response.name
'''),
      )).single;

      expect(result.status, ValidationStatus.pass);
    });
  });

  // ── the declaration itself ─────────────────────────────────────
  group('the declaration is validated when it is read', () {
    test('an endpoint that is not METHOD /path is a parse error', () {
      expect(
        () => mappingsFrom('''
screen: /s
usesResponseFrom:
  endpoint: the profile endpoint
mappings:
  - target: a
    source: response.b
'''),
        throwsA(isA<MappingsFormatException>()),
      );
    });

    test('an unknown occurrence is a parse error, not a default', () {
      expect(
        () => mappingsFrom('''
screen: /s
usesResponseFrom:
  endpoint: GET /a
  occurrence: newest
mappings:
  - target: a
    source: response.b
'''),
        throwsA(isA<MappingsFormatException>()),
      );
    });

    test('an unknown key is rejected', () {
      expect(
        () => mappingsFrom('''
screen: /s
usesResponseFrom:
  endpoint: GET /a
  maxAge: 60
mappings:
  - target: a
    source: response.b
'''),
        throwsA(isA<MappingsFormatException>()),
      );
    });

    test('a missing endpoint is a parse error', () {
      expect(
        () => mappingsFrom('''
screen: /s
usesResponseFrom:
  occurrence: last
mappings:
  - target: a
    source: response.b
'''),
        throwsA(isA<MappingsFormatException>()),
      );
    });

    test('the default occurrence is "only"', () {
      final mappings = mappingsFrom(declaredProfile);

      expect(mappings.usesResponseFrom!.occurrence, ResponseOccurrence.only);
      expect(mappings.usesResponseFrom!.endpoint.toString(),
          'GET /api/profile/me');
      expect(mappings.usesResponseFrom!.maxAge, isNull);
      expect(mappings.usesResponseFrom!.capturedOn, isNull);
    });
  });

  // ── rules see the same response ────────────────────────────────
  test('rules validate against the declared source too', () {
    final history = [
      screen('/', enteredAt: 0, exchanges: [
        exchange(
          method: 'GET',
          path: '/api/profile/me',
          body: {
            'data': {'firstName': 'Test', 'mobileNumber': null},
          },
          second: 5,
        ),
      ]),
      screen('/profile',
          enteredAt: 20,
          snapshot: treeWith({'profile.complete_button': 'Complete'})),
    ];

    final report = ValidationReport(
      runValidator(const RulesValidator(), contextOver(
        history: history,
        currentScreen: '/profile',
        mappings: mappingsFrom('''
screen: /profile
usesResponseFrom:
  endpoint: GET /api/profile/me
mappings:
  - target: profile.complete_button
    source: response.data.firstName
rules:
  - condition: "data.mobileNumber == null"
    expectations:
      - element: profile.complete_button
        property: text
        equals: "Complete"
'''),
      )),
    );

    expect(report.passed, isTrue, reason: '${report.failures}');
  });
}
