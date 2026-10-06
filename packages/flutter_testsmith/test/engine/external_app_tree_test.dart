import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// The validators, run over UI trees captured from a **real external
/// application** on real hardware.
///
/// The trees in `test/engine/fixtures/external/` were produced by
/// `testsmith inspect` against an app the platform team did not write -
/// go_router, Riverpod, dio/retrofit, flutter_svg - on a Samsung
/// SM-M127G. Nothing in them was hand-authored.
///
/// What this establishes: the deterministic chain works on a tree with
/// that app's shape - a `StatefulShellRoute`, `TestId` wrappers around
/// `InkWell`s, third-party widgets, 725 elements filtered to 34.
///
/// What it does **not** establish, and the report says so plainly: that
/// the API response reaches the screen that renders it. On the device
/// it did not, for reasons recorded as an architectural limitation.

UiSnapshot load(String name) {
  for (final candidate in [
    'test/engine/fixtures/external/$name.json',
    'packages/flutter_testsmith/test/engine/fixtures/external/$name.json',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return UiSnapshot.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
    }
  }
  fail('cannot find $name.json from ${Directory.current.path}');
}

ValidationContext contextFor(
  UiSnapshot snapshot, {
  required String mappingsYaml,
  required String responseBody,
  String method = 'GET',
  String path = '/api/tabs',
}) {
  final session = ScreenSession(
    screenId: snapshot.screenId,
    enteredAt: DateTime.utc(2026),
  )..uiSnapshot = snapshot;

  session.exchanges.add(
    ApiExchange(
      request: ApiRequestPayload(
        requestId: 'r',
        method: method,
        url: 'http://127.0.0.1:8080$path',
      ),
      requestedAt: DateTime.utc(2026),
      response: ApiResponsePayload(
        requestId: 'r',
        statusCode: 200,
        body: responseBody,
        durationMs: 7,
      ),
      respondedAt: DateTime.utc(2026),
    ),
  );

  return ValidationContext(
    session: session,
    mappings: MappingsFile.parse(mappingsYaml, source: 'external.yaml'),
  );
}

void main() {
  group('the captured trees are what they claim to be', () {
    test('the orders screen came off a real device', () {
      final snapshot = load('orders');

      expect(snapshot.screenId, '/orders');
      expect(snapshot.devicePixelRatio, 1.875);
      expect(snapshot.totalElementsWalked, greaterThan(900));
      expect(snapshot.viewport?.width, 384.0);
    });

    test('it contains widgets the platform had never met', () {
      // flutter_svg and the app's own InkWell-based tiles. The default
      // retention policy keeps none of these; the application had to
      // extend it, which is recorded as an integration change.
      final types = <String>{};
      void walk(UiNode node) {
        types.add(node.type);
        node.children.forEach(walk);
      }

      walk(load('orders').root);

      expect(types, contains('SvgPicture'));
      expect(types, contains('InkWell'));
      expect(types, contains('Scrollable'));
    });

    test('every node carries the route it belongs to', () {
      // The D-12 fix, on a go_router StatefulShellRoute rather than a
      // contrived two-route test.
      final snapshot = load('orders');
      var withRoute = 0;
      void walk(UiNode node) {
        if (node.properties['routeIndex'] is int) withRoute++;
        node.children.forEach(walk);
      }

      walk(snapshot.root);
      expect(withRoute, greaterThan(20));
    });
  });

  group('reading a property through a TestId wrapper', () {
    test('text comes from the wrapped widget', () {
      // `TestId(id: 'nav.orders', child: InkWell(... Text('Orders')))`.
      // The node carrying the id renders nothing itself.
      final node = load('orders').find('nav.orders')!;

      expect(node.text, isNull, reason: 'the wrapper has no text of its own');
      expect(readProperty(node, 'text'), 'Orders');
    });

    test('enabled comes from the InkWell two levels down', () {
      final node = load('orders').find('nav.orders')!;

      expect(node.enabled, isNull);
      expect(readProperty(node, 'enabled'), isTrue);
    });
  });

  group('API to UI, over the real tree', () {
    const mappings = '''
screen: /orders
api: GET /api/tabs
mappings:
  - target: nav.orders
    source: response.tabs.2.label
  - target: nav.profile
    source: response.tabs.4.label
''';

    String body({String orders = 'Orders', String profile = 'Profile'}) =>
        jsonEncode({
          'tabs': [
            {'label': 'Home'},
            {'label': 'Menu'},
            {'label': orders},
            {'label': 'Rewards'},
            {'label': profile},
          ],
        });

    test('matching values pass', () {
      final report = ValidationReport(
        runValidator(const ApiToUiValidator(),
          contextFor(load('orders'),
              mappingsYaml: mappings, responseBody: body()),
        ),
      );

      expect(report.passed, isTrue, reason: '${report.failures}');
      expect(report.passCount, 2);
    });

    test('a seeded mismatch is caught, with all three values', () {
      // The API says one thing, the screen shows another - the whole
      // point of the platform, on a tree it did not author.
      final result = ValidationReport(
        runValidator(const ApiToUiValidator(),
          contextFor(
            load('orders'),
            mappingsYaml: mappings,
            responseBody: body(orders: 'My Orders'),
          ),
        ),
      ).results.firstWhere((r) => r.elementId == 'nav.orders');

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('My Orders'));
      expect(result.message, contains('Orders'));

      String? evidence(String kind) {
        for (final item in result.evidence) {
          if (item.kind == kind) return item.reference;
        }
        return null;
      }

      expect(evidence('apiValue'), 'My Orders');
      expect(evidence('uiValue'), 'Orders');
    });

    test('a missing field is reported as such', () {
      final result = ValidationReport(
        runValidator(const ApiToUiValidator(),
          contextFor(
            load('orders'),
            mappingsYaml: mappings,
            responseBody: jsonEncode({'tabs': <Object?>[]}),
          ),
        ),
      ).results.first;

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('has no field'));
    });

    test('a declared endpoint the screen never called is an error, and '
        'names what it did call', () {
      final context = contextFor(
        load('orders'),
        mappingsYaml: mappings,
        responseBody: body(),
        path: '/v4beta/geocode/location/18.5,73.7',
      );

      final result = const ApiToUiValidator().validate(context).single;

      expect(result.status, ValidationStatus.error);
      expect(result.message, contains('did not call'));
      expect(result.message, contains('geocode'));
    });
  });

  group('rules over the real tree', () {
    test('a rule asserting enabled through a TestId wrapper passes', () {
      const mappings = '''
screen: /orders
api: GET /api/tabs
mappings:
  - target: nav.orders
    source: response.tabs.2.label
rules:
  - condition: "tabsEnabled == true"
    expectations:
      - element: nav.orders
        property: enabled
        equals: true
''';

      final report = ValidationReport(
        runValidator(const RulesValidator(),
          contextFor(
            load('orders'),
            mappingsYaml: mappings,
            responseBody: jsonEncode({
              'tabsEnabled': true,
              'tabs': [
                {'label': 'Home'},
                {'label': 'Menu'},
                {'label': 'Orders'},
              ],
            }),
          ),
        ),
      );

      // Before the descendant read, this failed on a correct screen:
      // the node carrying the id reports no enabled state of its own.
      expect(report.passed, isTrue, reason: '${report.failures}');
    });
  });
}
