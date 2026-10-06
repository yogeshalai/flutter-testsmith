import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const LogicalRect anyRect =
    LogicalRect(x: 0, y: 0, width: 100, height: 20);

UiNode text(String id, String value) =>
    UiNode(testId: id, type: 'Text', text: value, bounds: anyRect);

UiSnapshot treeOf(List<UiNode> children) => UiSnapshot(
      screenId: '/product/details',
      capturedAt: DateTime.utc(2026),
      devicePixelRatio: 1.875,
      root: UiNode(type: 'Root', bounds: anyRect, children: children),
    );

ScreenSession sessionWith({
  required String responseBody,
  required List<UiNode> nodes,
  String path = '/products/123',
}) {
  final session = ScreenSession(
    screenId: '/product/details',
    enteredAt: DateTime.utc(2026),
  )..uiSnapshot = treeOf(nodes);

  session.exchanges.add(
    ApiExchange(
      request: ApiRequestPayload(
        requestId: 'r1',
        method: 'GET',
        url: 'http://x$path',
      ),
      requestedAt: DateTime.utc(2026),
      response: ApiResponsePayload(
        requestId: 'r1',
        statusCode: 200,
        body: responseBody,
        durationMs: 10,
      ),
      respondedAt: DateTime.utc(2026),
    ),
  );

  return session;
}

const String priceMapping = '''
screen: /product/details
mappings:
  - target: product.price
    source: response.price
    transformation: currency(INR)
''';

ValidationContext contextFor(
  ScreenSession session,
  String mappingsYaml,
) =>
    ValidationContext(
      session: session,
      mappings: MappingsFile.parse(mappingsYaml, source: 'test'),
    );

void main() {
  endpointSelectionTests();
  enabledFromDescendantTests();
  group('ApiToUiValidator', () {
    test('passes when the transformed API value matches the UI', () {
      final session = sessionWith(
        responseBody: '{"price":2999}',
        nodes: [text('product.price', 'Rs 2,999')],
      );

      final results = const ApiToUiValidator()
          .validate(contextFor(session, priceMapping));

      expect(results.single.status, ValidationStatus.pass);
    });

    test('fails a mismatch reporting raw, transformed and UI values', () {
      // The motivating example. All three numbers matter: they are what
      // distinguish a data bug from a formatting bug.
      final session = sessionWith(
        responseBody: '{"price":2999}',
        nodes: [text('product.price', 'Rs 2,599')],
      );

      final result = const ApiToUiValidator()
          .validate(contextFor(session, priceMapping))
          .single;

      expect(result.status, ValidationStatus.fail);
      expect(result.elementId, 'product.price');
      expect(result.expected, 'Rs 2,999');
      expect(result.actual, 'Rs 2,599');
      expect(result.message, contains('2999'),
          reason: 'the raw API value must be visible in the message');
    });

    test('compares a non-text property', () {
      final session = sessionWith(
        responseBody: '{"available":false}',
        nodes: [
          const UiNode(
            testId: 'product.add_to_cart',
            type: 'FilledButton',
            enabled: false,
            bounds: anyRect,
          ),
        ],
      );

      final results = const ApiToUiValidator().validate(
        contextFor(session, '''
screen: /product/details
mappings:
  - target: product.add_to_cart
    property: enabled
    source: response.available
'''),
      );

      expect(results.single.status, ValidationStatus.pass);
    });

    test('fails when a mapped element is missing from the tree', () {
      final session = sessionWith(
        responseBody: '{"price":2999}',
        nodes: [text('product.name', 'Nike')],
      );

      final result = const ApiToUiValidator()
          .validate(contextFor(session, priceMapping))
          .single;

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('product.price'));
    });

    test('fails when the response has no such field', () {
      // The mapping asserts the field exists; its absence is a contract
      // violation, not a reason to skip.
      final session = sessionWith(
        responseBody: '{"name":"Nike"}',
        nodes: [text('product.price', 'Rs 2,999')],
      );

      final result = const ApiToUiValidator()
          .validate(contextFor(session, priceMapping))
          .single;

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('price'));
    });

    test('errors, rather than fails, when no response was captured', () {
      // Nothing was proven about the screen. That is not the same as the
      // screen being wrong.
      final session = ScreenSession(
        screenId: '/product/details',
        enteredAt: DateTime.utc(2026),
      )..uiSnapshot = treeOf([text('product.price', 'Rs 2,999')]);

      final result = const ApiToUiValidator()
          .validate(contextFor(session, priceMapping))
          .single;

      expect(result.status, ValidationStatus.error);
    });

    test('errors when no UI tree was captured', () {
      final session = sessionWith(responseBody: '{"price":2999}', nodes: [])
        ..uiSnapshot = null;

      final result = const ApiToUiValidator()
          .validate(contextFor(session, priceMapping))
          .single;

      expect(result.status, ValidationStatus.error);
    });

    test('skips when no mappings are configured', () {
      final session = sessionWith(
        responseBody: '{"price":2999}',
        nodes: [text('product.price', 'Rs 2,999')],
      );

      final results = const ApiToUiValidator().validate(
        ValidationContext(session: session),
      );

      expect(results.single.status, ValidationStatus.skip);
    });

    test('reports a broken transformation as an error, not a mismatch', () {
      // The tool is wrong here, not the application.
      final session = sessionWith(
        responseBody: '{"price":"not a number"}',
        nodes: [text('product.price', 'Rs 2,999')],
      );

      final result = const ApiToUiValidator()
          .validate(contextFor(session, priceMapping))
          .single;

      expect(result.status, ValidationStatus.error);
    });

    test('never applies a suggested mapping', () {
      final session = sessionWith(
        responseBody: '{"rating":4.5}',
        nodes: [text('product.rating', 'WRONG')],
      );

      final results = const ApiToUiValidator().validate(
        contextFor(session, '''
screen: /product/details
suggested:
  - target: product.rating
    source: response.rating
    transformation: toText
    confidence: 0.9
'''),
      );

      // Skipped for having no active mappings, not failed on the
      // suggestion.
      expect(results.single.status, ValidationStatus.skip);
    });
  });

  group('UiPresenceValidator', () {
    test('passes when every mapped element is present', () {
      final session = sessionWith(
        responseBody: '{"price":2999}',
        nodes: [text('product.price', 'Rs 2,999')],
      );

      final results = const UiPresenceValidator()
          .validate(contextFor(session, priceMapping));

      expect(results.every((r) => r.status == ValidationStatus.pass), isTrue);
    });

    test('fails naming the ids that are actually present', () {
      final session = sessionWith(
        responseBody: '{"price":2999}',
        nodes: [text('product.name', 'Nike')],
      );

      final result = const UiPresenceValidator()
          .validate(contextFor(session, priceMapping))
          .single;

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('product.name'));
    });

    test('fails on an ambiguous id', () {
      final session = sessionWith(
        responseBody: '{"price":2999}',
        nodes: [text('product.price', 'a')],
      );
      session.uiSnapshot = UiSnapshot(
        screenId: '/product/details',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 1.875,
        duplicateTestIds: const {'product.price'},
        root: UiNode(
          type: 'Root',
          bounds: anyRect,
          children: [text('product.price', 'a')],
        ),
      );

      final result = const UiPresenceValidator()
          .validate(contextFor(session, priceMapping))
          .single;

      expect(result.status, ValidationStatus.fail);
      expect(result.message.toLowerCase(), contains('more than one'));
    });
  });

  group('RulesValidator', () {
    const rules = '''
screen: /product/details
rules:
  - condition: "available == false"
    expectations:
      - element: product.unavailable
        property: visible
        equals: true
      - element: product.add_to_cart
        property: enabled
        equals: false

  - condition: "discount > 0"
    expectations:
      - element: product.discount_badge
        property: visible
        equals: true
''';

    test('checks expectations of a rule whose condition holds', () {
      final session = sessionWith(
        responseBody: '{"available":false,"discount":0}',
        nodes: [
          const UiNode(
            testId: 'product.unavailable',
            type: 'Text',
            bounds: anyRect,
          ),
          const UiNode(
            testId: 'product.add_to_cart',
            type: 'FilledButton',
            enabled: false,
            bounds: anyRect,
          ),
        ],
      );

      final results =
          const RulesValidator().validate(contextFor(session, rules));

      expect(results.where((r) => r.isFailure), isEmpty);
      expect(results.where((r) => r.status == ValidationStatus.pass),
          hasLength(2));
    });

    test('fails when an expectation is not met', () {
      final session = sessionWith(
        responseBody: '{"available":false,"discount":0}',
        nodes: [
          const UiNode(
            testId: 'product.unavailable',
            type: 'Text',
            bounds: anyRect,
          ),
          // Still enabled, though the product is unavailable.
          const UiNode(
            testId: 'product.add_to_cart',
            type: 'FilledButton',
            enabled: true,
            bounds: anyRect,
          ),
        ],
      );

      final results =
          const RulesValidator().validate(contextFor(session, rules));

      final failure = results.firstWhere((r) => r.isFailure);
      expect(failure.elementId, 'product.add_to_cart');
      expect(failure.expected, 'false');
      expect(failure.actual, 'true');
    });

    test('skips a rule whose condition does not hold', () {
      final session = sessionWith(
        responseBody: '{"available":true,"discount":0}',
        nodes: [
          const UiNode(
            testId: 'product.add_to_cart',
            type: 'FilledButton',
            enabled: true,
            bounds: anyRect,
          ),
        ],
      );

      final results =
          const RulesValidator().validate(contextFor(session, rules));

      // Both rules' conditions are false, so nothing was checked.
      expect(results.every((r) => r.status == ValidationStatus.skip), isTrue);
    });

    test('an element absent when a rule expects it visible is a failure', () {
      final session = sessionWith(
        responseBody: '{"available":false,"discount":0}',
        nodes: [
          const UiNode(
            testId: 'product.add_to_cart',
            type: 'FilledButton',
            enabled: false,
            bounds: anyRect,
          ),
        ],
      );

      final results =
          const RulesValidator().validate(contextFor(session, rules));

      final failure = results.firstWhere((r) => r.isFailure);
      expect(failure.elementId, 'product.unavailable');
    });

    test('an absent element satisfies an expectation of not visible', () {
      final session = sessionWith(
        responseBody: '{"discount":0,"available":true}',
        nodes: [],
      );

      final results = const RulesValidator().validate(
        contextFor(session, '''
screen: /product/details
rules:
  - condition: "discount == 0"
    expectations:
      - element: product.discount_badge
        property: visible
        equals: false
'''),
      );

      expect(results.single.status, ValidationStatus.pass);
    });
  });
}

/// Found on a real external application: the semantic id sits on a
/// wrapper and the interactive widget two levels below it is what
/// carries `enabled`, so the node carrying the id reported null and a
/// rule asserting on it failed against a correct screen.
void enabledFromDescendantTests() {
  UiNode node({
    String? id,
    bool? enabled,
    String? text,
    List<UiNode> children = const [],
  }) =>
      UiNode(
        testId: id,
        type: 'Widget',
        enabled: enabled,
        text: text,
        bounds: const LogicalRect(x: 0, y: 0, width: 10, height: 10),
        children: children,
      );

  group('enabled', () {
    test('is read from the node itself when it has one', () {
      expect(readProperty(node(enabled: false), 'enabled'), isFalse);
    });

    test('the node wins over a disagreeing descendant', () {
      final tree = node(enabled: false, children: [node(enabled: true)]);

      expect(readProperty(tree, 'enabled'), isFalse);
    });

    test('falls through to the one descendant that has one', () {
      // TestId -> InkWell(enabled) -> GestureDetector -> Text
      final tree = node(
        id: 'nav.orders',
        children: [
          node(enabled: true, children: [node(children: [node(text: 'Orders')])]),
        ],
      );

      expect(readProperty(tree, 'enabled'), isTrue);
    });

    test('descendants that agree are not ambiguous', () {
      final tree = node(children: [node(enabled: false), node(enabled: false)]);

      expect(readProperty(tree, 'enabled'), isFalse);
    });

    test('descendants that disagree report unknown, not a guess', () {
      // Answering would be a guess dressed up as a result.
      final tree = node(children: [node(enabled: true), node(enabled: false)]);

      expect(readProperty(tree, 'enabled'), isNull);
    });

    test('no descendant with a notion of enabled is still null', () {
      final tree = node(children: [node(text: 'hello')]);

      expect(readProperty(tree, 'enabled'), isNull);
    });
  });

  group('text', () {
    test('the node wins', () {
      final tree = node(text: 'outer', children: [node(text: 'inner')]);

      expect(readProperty(tree, 'text'), 'outer');
    });

    test('falls through to a single text-bearing descendant', () {
      final tree = node(id: 'x', children: [node(text: 'Orders')]);

      expect(readProperty(tree, 'text'), 'Orders');
    });

    test('two texts are ambiguous', () {
      final tree = node(children: [node(text: 'a'), node(text: 'b')]);

      expect(readProperty(tree, 'text'), isNull);
    });
  });
}

/// Found on a real application: the first exchange on a profile screen
/// was a third-party geocoding call to another host, and the profile's
/// mappings were compared against it - reporting "the response has no
/// field data.firstName" about a maps reply.
///
/// `api:` has been in the mappings format since Phase 4, parsed and
/// then ignored.
void endpointSelectionTests() {
  ApiExchange exchange(String method, String path, String body) => ApiExchange(
        request: ApiRequestPayload(
          requestId: path,
          method: method,
          url: 'https://host$path',
        ),
        requestedAt: DateTime.utc(2026),
        response: ApiResponsePayload(
          requestId: path,
          statusCode: 200,
          body: body,
          durationMs: 5,
        ),
        respondedAt: DateTime.utc(2026),
      );

  ValidationContext contextWith(String? api, List<ApiExchange> exchanges) {
    final session = ScreenSession(
      screenId: '/profile',
      enteredAt: DateTime.utc(2026),
    );
    session.exchanges.addAll(exchanges);

    return ValidationContext(
      session: session,
      mappings: MappingsFile.parse(
        'screen: /profile\n${api == null ? '' : 'api: $api\n'}'
        'mappings:\n  - target: x\n    source: response.name\n',
        source: 'x.yaml',
      ),
    );
  }

  group('choosing which response to compare against', () {
    test('the declared endpoint wins over an earlier unrelated call', () {
      final context = contextWith('GET /api/profile/me', [
        exchange('GET', '/v4beta/geocode/location/18.5,73.7', '{"name":"maps"}'),
        exchange('GET', '/api/profile/me', '{"name":"test"}'),
      ]);

      expect(context.response!.readPath('name'), 'test');
    });

    test('with no endpoint declared, the first response wins as before', () {
      final context = contextWith(null, [
        exchange('GET', '/first', '{"name":"first"}'),
        exchange('GET', '/second', '{"name":"second"}'),
      ]);

      expect(context.response!.readPath('name'), 'first');
    });

    test('the method is part of the match', () {
      final context = contextWith('POST /api/orders', [
        exchange('GET', '/api/orders', '{"name":"list"}'),
        exchange('POST', '/api/orders', '{"name":"created"}'),
      ]);

      expect(context.response!.readPath('name'), 'created');
    });

    test('a wildcard segment matches an id', () {
      final context = contextWith('GET /api/orders/*', [
        exchange('GET', '/api/orders/abc123', '{"name":"one"}'),
      ]);

      expect(context.response!.readPath('name'), 'one');
    });

    test('a declared endpoint that was never called compares nothing', () {
      // Not "the first response will do". Comparing against a reply the
      // mappings were not written for is how a maps response came to be
      // judged against a profile.
      final context = contextWith('GET /api/profile/me', [
        exchange('GET', '/v4beta/geocode/location/1,2', '{"name":"maps"}'),
      ]);

      expect(context.response, isNull);
    });

    test('and says what the screen did call', () {
      final context = contextWith('GET /api/profile/me', [
        exchange('GET', '/v4beta/geocode/location/1,2', '{"name":"maps"}'),
      ]);
      // A tree, so the validator reaches the response check rather than
      // stopping at "no UI tree was captured".
      context.session.uiSnapshot = UiSnapshot(
        screenId: '/profile',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 2,
        root: UiNode(
          type: 'Root',
          bounds: const LogicalRect(x: 0, y: 0, width: 10, height: 10),
          children: [
            UiNode(
              testId: 'x',
              type: 'Text',
              text: 'anything',
              bounds: const LogicalRect(x: 0, y: 0, width: 10, height: 10),
            ),
          ],
        ),
      );

      final result = const ApiToUiValidator().validate(context).single;
      expect(result.status, ValidationStatus.error);
      expect(result.message, contains('did not call'));
      expect(result.message, contains('/v4beta/geocode'));
    });

    test('an api: that is not METHOD /path is ignored, not fatal', () {
      // Something written as prose must not break a run that validated
      // fine before this existed.
      final context = contextWith('the products endpoint', [
        exchange('GET', '/anything', '{"name":"kept"}'),
      ]);

      expect(context.endpoint, isNull);
      expect(context.response!.readPath('name'), 'kept');
    });
  });

  group('ApiEndpoint', () {
    test('parses and compares case-insensitively on the method', () {
      final endpoint = ApiEndpoint.tryParse('get /a/b')!;

      expect(endpoint.method, 'GET');
      expect(endpoint.matches('GET', '/a/b'), isTrue);
      expect(endpoint.matches('POST', '/a/b'), isFalse);
    });

    test('a different segment count never matches', () {
      final endpoint = ApiEndpoint.tryParse('GET /a/*')!;

      expect(endpoint.matches('GET', '/a/b'), isTrue);
      expect(endpoint.matches('GET', '/a/b/c'), isFalse);
      expect(endpoint.matches('GET', '/a'), isFalse);
    });
  });
}
