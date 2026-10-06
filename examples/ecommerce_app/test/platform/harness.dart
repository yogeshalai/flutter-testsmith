import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecommerce_app/api/api_client.dart';
import 'package:ecommerce_app/api/defects.dart';
import 'package:ecommerce_app/api/models.dart';
import 'package:ecommerce_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// Drives the real validators over the real application widgets.
///
/// Nothing here is a mock of the platform. The tree comes from
/// [UiTreeInspector] - the same code that answers `ext.mytest.uiTree` on
/// a device - and the verdict comes from [ApiToUiValidator] and
/// [RulesValidator], the same code a run uses. What is replaced is the
/// socket and the device, because neither changes the answer.
///
/// That matters for the acceptance claim: a matrix built on hand-written
/// `UiNode` fixtures would prove the validators are self-consistent and
/// nothing about whether the application's widgets actually report what
/// the validators read.

/// The scenario files the mock API serves, so a matrix row and a device
/// run are looking at the same bytes.
Directory get scenarioDirectory {
  for (final candidate in [
    'mock_api/scenarios',
    'examples/ecommerce_app/mock_api/scenarios',
  ]) {
    final directory = Directory(candidate);
    if (directory.existsSync()) return directory;
  }
  fail('cannot find mock_api/scenarios from ${Directory.current.path}');
}

/// The body a named scenario returns for one route, decoded.
Map<String, Object?> fixtureBody(
  String scenario,
  String method,
  String path,
) {
  final chain = <String, ApiScenario>{};
  for (final file in scenarioDirectory.listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    final parsed =
        ApiScenario.parse(file.readAsStringSync(), source: file.path);
    chain[parsed.name] = parsed;
  }

  ApiScenario resolve(String name) {
    final one = chain[name]!;
    final parent = one.inherits;
    return parent == null ? one : one.mergedOnto(resolve(parent));
  }

  final route = resolve(scenario).match(method, path);
  if (route == null) {
    fail('scenario "$scenario" says nothing about $method $path');
  }
  final body = route.bodyText;
  if (body == null) fail('scenario "$scenario" returns no body for $path');
  return (jsonDecode(body) as Map).cast<String, Object?>();
}

/// A mappings file from the example application.
MappingsFile mappingsFor(String name) {
  for (final candidate in [
    'mappings/$name.yaml',
    'examples/ecommerce_app/mappings/$name.yaml',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return MappingsFile.parse(file.readAsStringSync(), source: file.path);
    }
  }
  fail('cannot find mappings/$name.yaml from ${Directory.current.path}');
}

/// Builds the [ApiResponsePayload] the SDK would have emitted.
///
/// Constructed rather than captured because `flutter_test` stubs every
/// `HttpClient` to 400, so the real capture path cannot run here. The
/// payload is byte-identical to what the wire would produce: the same
/// JSON text, through the same `readPath`.
ApiResponsePayload responseFrom(
  Map<String, Object?> body, {
  int statusCode = 200,
}) =>
    ApiResponsePayload(
      requestId: 'matrix',
      statusCode: statusCode,
      body: jsonEncode(body),
      durationMs: 12,
    );

/// Pumps [child] at a fixed surface size and captures the tree.
///
/// 402pt wide, which is the design frame's width, so the geometry the
/// tree reports is directly comparable with the Figma spec.
Future<UiSnapshot> pumpAndCapture(
  WidgetTester tester,
  Widget child, {
  required String screenId,
  Size size = const Size(402, 900),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(home: child, theme: ThemeData(useMaterial3: true)),
  );
  await tester.pumpAndSettle();

  return const UiTreeInspector().capture(
    root: tester.binding.rootElement!,
    screenId: screenId,
    devicePixelRatio: 2,
  );
}

/// Like [pumpAndCapture], with an API client in scope.
Future<UiSnapshot> pumpAndCaptureWith(
  WidgetTester tester,
  Widget child, {
  required String screenId,
  String scenario = 'default',
  Size size = const Size(402, 900),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    AppScope(
      api: apiFor(scenario),
      child: MaterialApp(home: child, theme: ThemeData(useMaterial3: true)),
    ),
  );
  await tester.pumpAndSettle();

  return const UiTreeInspector().capture(
    root: tester.binding.rootElement!,
    screenId: screenId,
    devicePixelRatio: 2,
  );
}

/// Runs the deterministic validators exactly as the flow executor does.
ValidationReport validate({
  required UiSnapshot snapshot,
  required ApiResponsePayload response,
  required MappingsFile mappings,
}) {
  final session = ScreenSession(
    screenId: mappings.screen,
    enteredAt: DateTime.now().toUtc(),
  )..uiSnapshot = snapshot;

  // `api:` is "METHOD /path", so it cannot be pasted into a URL. Before
  // the engine used the declared endpoint to choose which response to
  // compare, this produced the nonsense URL
  // `http://127.0.0.1:8080GET /products/123` and nothing noticed,
  // because the first captured response was used regardless.
  final endpoint = ApiEndpoint.tryParse(mappings.api);

  session.exchanges.add(
    ApiExchange(
      request: ApiRequestPayload(
        requestId: 'matrix',
        method: endpoint?.method ?? 'GET',
        url: 'http://127.0.0.1:8080${endpoint?.path ?? '/'}',
      ),
      requestedAt: session.enteredAt,
      response: response,
      respondedAt: session.enteredAt,
    ),
  );

  final context = ValidationContext(
    session: session,
    mappings: mappings,
    figmaTolerances: mappings.figma,
  );

  // `runValidator`, not `validate` - the same call `FlowExecutor` makes.
  //
  // A validator states what it found and leaves the dimension unset;
  // `runValidator` stamps the validator's own dimension onto it, once, in
  // one place. Calling `validate` directly skipped that, and
  // `ValidationReport` refuses an unstamped result because `verdictFor`
  // matches on dimension - so an unstamped FAIL would sit in the results
  // and in no dimension block, leaving the overall verdict free to
  // disagree with the evidence beneath it.
  //
  // This harness exists to exercise the production contract, so it uses
  // the production boundary rather than a copy of what it does.
  return ValidationReport([
    ...runValidator(const UiPresenceValidator(), context),
    ...runValidator(const ApiToUiValidator(), context),
    ...runValidator(const RulesValidator(), context),
  ]);
}

/// The first result from [validatorId] about [elementId].
ValidationResult resultFor(
  ValidationReport report,
  String validatorId,
  String elementId,
) {
  for (final result in report.results) {
    if (result.validatorId == validatorId && result.elementId == elementId) {
      return result;
    }
  }
  fail('no $validatorId result for "$elementId". Got:\n'
      '${report.results.map((r) => '  $r').join('\n')}');
}

/// One evidence value, by kind.
String? evidence(ValidationResult result, String kind) {
  for (final item in result.evidence) {
    if (item.kind == kind) return item.reference;
  }
  return null;
}

/// Restores a clean application between rows.
void resetDefects() {
  addTearDown(() => Defects.current = Defects.none);
  Defects.current = Defects.none;
}

/// Collects matrix rows and writes them where the acceptance report can
/// quote them.
///
/// Generated rather than transcribed: a table typed by hand drifts from
/// the run it describes, and a hardening phase that does that has
/// disproved its own point.
class MatrixRecorder {
  MatrixRecorder(this.title, this.path, this.columns);

  final String title;
  final String path;
  final List<String> columns;
  final List<List<String>> rows = [];

  void add(List<String> row) {
    assert(row.length == columns.length, 'row does not match the columns');
    rows.add(row);
  }

  void write({String preamble = ''}) {
    final file = File(path.startsWith('docs/') &&
            !Directory('docs').existsSync()
        ? '../../$path'
        : path);
    file.parent.createSync(recursive: true);

    final buffer = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln('Generated by the test that produced it, on '
          '${DateTime.now().toUtc().toIso8601String().substring(0, 16)}Z. '
          'Do not edit by hand.')
      ..writeln();
    if (preamble.isNotEmpty) buffer..writeln(preamble)..writeln();

    buffer
      ..writeln('| ${columns.join(' | ')} |')
      ..writeln('|${columns.map((_) => '---').join('|')}|');
    for (final row in rows) {
      buffer.writeln('| ${row.map(_escape).join(' | ')} |');
    }
    file.writeAsStringSync(buffer.toString());
  }

  static String _escape(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', ' ');
}

/// An [ApiClient] whose answers are canned.
///
/// Needed because a widget test cannot reach a socket: initialising the
/// Flutter test binding replaces `HttpOverrides.global`, and a request
/// made from `initState` is never delivered - a `MockApiServer` bound
/// inside a widget test never sees the connection at all.
///
/// So the transport half of the chain is proven over a real socket in
/// `api_transport_matrix_test.dart`, and this fake supplies the same
/// outcomes to the widgets. It extends the real client rather than
/// reimplementing an interface, so a method nobody overrode still goes
/// down the real path and fails loudly rather than quietly returning
/// nothing.
class FakeApi extends ApiClient {
  FakeApi({this.failure, this.overrides = const {}, this.neverAnswers = false});

  /// Leaves every call pending forever, which is what a screen's loading
  /// state actually looks like. An empty override map is not the same
  /// thing: that fails the call, which is the error state.
  final bool neverAnswers;

  /// Thrown by every call, for the error rows.
  final ApiException? failure;

  /// Canned bodies, keyed by `METHOD /path`.
  final Map<String, Map<String, Object?>> overrides;

  Future<Map<String, Object?>> _pending() =>
      Completer<Map<String, Object?>>().future;

  Map<String, Object?> _body(String key) {
    final failed = failure;
    if (failed != null) throw failed;
    final body = overrides[key];
    if (body == null) fail('FakeApi has nothing for "$key"');
    return body;
  }

  @override
  Future<Session> login({
    required String email,
    required String password,
  }) async =>
      Session.fromJson(
        neverAnswers ? await _pending() : _body('POST /auth/login'),
      );

  @override
  Future<HomeSummary> homeSummary() async => HomeSummary.fromJson(
        neverAnswers ? await _pending() : _body('GET /home/summary'),
      );

  @override
  Future<List<Product>> products() async {
    final body = neverAnswers ? await _pending() : _body('GET /products');
    return [
      for (final item in (body['items'] as List?) ?? const [])
        if (item is Map) Product.fromJson(item.cast<String, Object?>()),
    ];
  }

  @override
  Future<Product> product(String id) async => Product.fromJson(
        neverAnswers ? await _pending() : _body('GET /products/$id'),
      );

  @override
  Future<Cart> cart() async => Cart.fromJson(
        neverAnswers ? await _pending() : _body('GET /cart'),
      );

  @override
  Future<Order> checkout({
    required String address,
    required String cardNumber,
    required String cvv,
    required String otp,
  }) async =>
      Order.fromJson(_body('POST /checkout'));
}

/// A [FakeApi] answering from a named scenario file.
///
/// The same bytes the mock API serves on a device, so a widget row and a
/// device row are looking at one fixture rather than two descriptions of
/// one.
FakeApi apiFor(String scenario, {List<String> routes = const []}) {
  final overrides = <String, Map<String, Object?>>{};
  for (final route in [
    'POST /auth/login',
    'GET /home/summary',
    'GET /products',
    'GET /products/123',
    'GET /products/789',
    'GET /cart',
    'POST /checkout',
    ...routes,
  ]) {
    final parts = route.split(' ');
    overrides[route] = fixtureBody(scenario, parts.first, parts.last);
  }
  return FakeApi(overrides: overrides);
}
