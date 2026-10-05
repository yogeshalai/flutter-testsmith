import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'network_capture.dart';

/// Captures `dart:io` HTTP traffic with no change to application code.
///
/// This is the widest net available without taking a dependency on a
/// specific HTTP package: it sees `package:http`'s IOClient and dio's
/// default adapter, because both go through `HttpClient` underneath.
///
/// What it does **not** see, and what the support matrix must therefore
/// say plainly (risk R9): custom dio adapters, `package:web`/fetch on
/// web, HTTP performed on the native side by a plugin, gRPC, and
/// WebSockets. Applications using those wire up [NetworkCapture]
/// directly.
///
/// Pass [previous] to keep an override the application already installed;
/// replacing it silently would break whatever it was doing.
class CapturingHttpOverrides extends HttpOverrides {
  CapturingHttpOverrides(this.capture, {this.previous});

  final NetworkCapture capture;
  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = previous?.createHttpClient(context) ??
        super.createHttpClient(context);
    return _CapturingHttpClient(inner, capture);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}

/// Delegates everything, and intercepts only the one method every other
/// entry point funnels through.
class _CapturingHttpClient implements HttpClient {
  _CapturingHttpClient(this._inner, this._capture);

  final HttpClient _inner;
  final NetworkCapture _capture;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    // Before the connection: `openUrl` is where DNS, TCP and TLS happen,
    // and where a connection timeout is raised. Timing from close() left
    // all of that out, and recorded a connection that took thirty seconds
    // to fail as roughly nothing.
    final startedAtMicros = _capture.monotonicMicros();
    final HttpClientRequest request;
    try {
      request = await _inner.openUrl(method, url);
    } catch (error) {
      // The connection failed before a request object ever existed - a
      // refused port, a DNS failure. Recorded here because otherwise
      // "the app made no request" and "the request could not connect"
      // look identical in a report. Headers and body are genuinely
      // unknown at this point, so none are claimed.
      final requestId = _capture.begin(
        method: method,
        url: url,
        startedAtMicros: startedAtMicros,
      );
      _capture.fail(requestId, error: error);
      rethrow;
    }
    return _CapturingHttpClientRequest(request, _capture, startedAtMicros);
  }

  // Every convenience method is defined in terms of openUrl, exactly as
  // HttpClient itself does, so one interception point covers them all.
  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) =>
      _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
        f,
  ) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )? f,
  ) =>
      _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set keyLog(void Function(String line)? callback) =>
      _inner.keyLog = callback;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Wraps a request so its body and headers can be recorded, and its
/// response teed.
class _CapturingHttpClientRequest implements HttpClientRequest {
  _CapturingHttpClientRequest(this._inner, this._capture, this._startedAtMicros);

  final HttpClientRequest _inner;
  final NetworkCapture _capture;

  /// Read before the connection was opened, so the duration covers it.
  final int _startedAtMicros;
  final List<int> _body = <int>[];

  @override
  Future<HttpClientResponse> close() async {
    final headers = <String, String>{};
    _inner.headers.forEach((name, values) {
      headers[name] = values.join(', ');
    });

    final requestId = _capture.begin(
      method: _inner.method,
      url: _inner.uri,
      headers: headers,
      body: _body.isEmpty ? null : _decode(_body),
      startedAtMicros: _startedAtMicros,
    );

    final HttpClientResponse response;
    try {
      response = await _inner.close();
    } catch (error) {
      // A refused connection or a timeout produces no response at all.
      _capture.fail(requestId, error: error);
      rethrow;
    }

    if (requestId == null) return response;
    return _CapturingHttpClientResponse(response, _capture, requestId);
  }

  @override
  Future<HttpClientResponse> get done => _inner.done;

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return '<${bytes.length} bytes of binary>';
    }
  }

  @override
  void add(List<int> data) {
    _body.addAll(data);
    _inner.add(data);
  }

  @override
  void write(Object? object) {
    final text = '$object';
    _body.addAll(utf8.encode(text));
    _inner.write(text);
  }

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    // Tee: the application's bytes must reach the socket unchanged, and
    // a copy is kept for the event.
    await _inner.addStream(
      stream.map((chunk) {
        _body.addAll(chunk);
        return chunk;
      }),
    );
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> flush() => _inner.flush();

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
}

/// Tees the response stream so the body can be recorded without the
/// application seeing anything different.
class _CapturingHttpClientResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _CapturingHttpClientResponse(
    this._inner,
    NetworkCapture capture,
    String requestId,
  ) : super(_tee(_inner, capture, requestId));

  final HttpClientResponse _inner;

  static Stream<List<int>> _tee(
    HttpClientResponse response,
    NetworkCapture capture,
    String requestId,
  ) {
    final collected = <int>[];
    return response.map((chunk) {
      collected.addAll(chunk);
      return chunk;
    }).handleError((Object error) {
      capture.fail(requestId, error: error);
      // ignore: only_throw_errors
      throw error;
    }).transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleDone: (sink) {
          final headers = <String, String>{};
          response.headers.forEach((name, values) {
            headers[name] = values.join(', ');
          });
          capture.complete(
            requestId,
            statusCode: response.statusCode,
            headers: headers,
            body: _decodeBody(collected),
          );
          sink.close();
        },
      ),
    );
  }

  static String _decodeBody(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return '<${bytes.length} bytes of binary>';
    }
  }

  @override
  int get statusCode => _inner.statusCode;
  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  int get contentLength => _inner.contentLength;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  bool get isRedirect => _inner.isRedirect;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  List<RedirectInfo> get redirects => _inner.redirects;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;
  @override
  X509Certificate? get certificate => _inner.certificate;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) =>
      _inner.redirect(method, url, followLoops);

  @override
  Future<Socket> detachSocket() => _inner.detachSocket();
}
