import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Where the API lives from the device's point of view.
///
/// `adb reverse` maps this to the host, so the same address works on a
/// physical device and an emulator. A physical device has no equivalent
/// of the emulator's 10.0.2.2.
const String apiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://127.0.0.1:8080',
);

/// A request failed in a way the UI has to show.
///
/// Carries the status so a screen can distinguish "you are not signed
/// in" from "we broke" - the two need different words and different
/// affordances, and collapsing them is how an app comes to show
/// "something went wrong" for an expired session.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.isTimeout = false});

  final String message;
  final int? statusCode;
  final bool isTimeout;

  bool get isUnauthorised => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isBadRequest => statusCode == 400;
  bool get isServerError => (statusCode ?? 0) >= 500;

  /// What the screen puts in front of a person.
  String get userMessage {
    if (isTimeout) return 'The server took too long to answer. Try again.';
    return switch (statusCode) {
      400 => 'That request was not valid. Check the details and try again.',
      401 => 'Your session has expired. Sign in again.',
      403 => 'You do not have access to this.',
      404 => 'We could not find that.',
      final int code when code >= 500 =>
        'Something went wrong at our end. Try again shortly.',
      _ => message,
    };
  }

  @override
  String toString() => 'ApiException($statusCode: $message)';
}

/// The one place this application talks to the network.
///
/// One place on purpose. Every credential the app sends is seeded here,
/// so "does a secret reach a report?" has one answer to check rather
/// than one per screen. The SDK intercepts `HttpClient` underneath, so
/// nothing here knows it is being watched.
class ApiClient {
  ApiClient({
    this.baseUrl = apiBase,
    this.timeout = const Duration(seconds: 5),
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final String baseUrl;

  /// Short on purpose: a timeout has to be reachable within a test run,
  /// and `api_timeout` delays its reply past this.
  final Duration timeout;

  final HttpClient Function() _clientFactory;

  /// Set once login succeeds. Sent on every later call.
  String? _token;

  /// Deliberately credential-shaped, and deliberately constant, so the
  /// security matrix can grep for it.
  static const String deviceSecret = 'DEVICE_SECRET_9f2a41c8';

  void adopt(Session session) => _token = session.token;

  Map<String, String> get _authHeaders => {
        if (_token != null) 'authorization': 'Bearer $_token',
        'x-device-secret': deviceSecret,
        'accept': 'application/json',
      };

  Future<Session> login({
    required String email,
    required String password,
  }) async {
    final json = await _send(
      'POST',
      '/auth/login',
      // A password in a request body, which redaction must strip before
      // the event leaves the process.
      body: {'email': email, 'password': password},
    );
    final session = Session.fromJson(json);
    _token = session.token;
    return session;
  }

  Future<HomeSummary> homeSummary() async =>
      HomeSummary.fromJson(await _send('GET', '/home/summary'));

  Future<List<Product>> products() async {
    final json = await _send('GET', '/products');
    return [
      for (final item in (json['items'] as List?) ?? const [])
        if (item is Map) Product.fromJson(item.cast<String, Object?>()),
    ];
  }

  Future<Product> product(String id) async =>
      Product.fromJson(await _send('GET', '/products/$id'));

  Future<Cart> cart() async => Cart.fromJson(await _send('GET', '/cart'));

  Future<Order> checkout({
    required String address,
    required String cardNumber,
    required String cvv,
    required String otp,
  }) async {
    final json = await _send(
      'POST',
      '/checkout',
      body: {
        'address': address,
        // Three more credentials, in a body the SDK sees.
        'cardNumber': cardNumber,
        'cvv': cvv,
        'otp': otp,
      },
    );
    return Order.fromJson(json);
  }

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl(method, Uri.parse('$baseUrl$path'));
      for (final header in _authHeaders.entries) {
        request.headers.set(header.key, header.value);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join().timeout(timeout);

      if (response.statusCode >= 400) {
        throw ApiException(
          'HTTP ${response.statusCode} for $method $path',
          statusCode: response.statusCode,
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        // A body that claims to be JSON and is not. Distinct from a 500:
        // the server answered, it just answered nonsense, and a screen
        // that renders a parse error as "no data" hides a real fault.
        throw ApiException(
          'The server sent a reply that could not be read',
          statusCode: response.statusCode,
        );
      }
      if (decoded is! Map) {
        throw ApiException(
          'The server sent ${decoded.runtimeType} where an object was '
          'expected',
          statusCode: response.statusCode,
        );
      }
      return decoded.cast<String, Object?>();
    } on TimeoutException {
      throw const ApiException('timed out', isTimeout: true);
    } on SocketException catch (error) {
      throw ApiException('could not reach the server: ${error.message}');
    } finally {
      client.close();
    }
  }
}
