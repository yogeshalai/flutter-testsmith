import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

MappingsFile _parse(String yaml) =>
    MappingsFile.parse(yaml, source: 'test.yaml');

void main() {
  test('an apiSource block parses', () {
    final file = _parse('''
screen: /product/details
apiSource:
  baseUrl: env:EXAMPLE_API_BASE
  method: GET
  endpoint: /products/123
  token: env:EXAMPLE_API_TOKEN
''');
    final source = file.apiSource!;
    expect(source.baseUrl, 'env:EXAMPLE_API_BASE');
    expect(source.method, 'GET');
    expect(source.endpoint, '/products/123');
    expect(source.token!.name, 'EXAMPLE_API_TOKEN');
  });

  test('a literal token is refused at parse time', () {
    expect(
      () => _parse('''
screen: /s
apiSource:
  baseUrl: https://api.example.com
  method: GET
  endpoint: /p
  token: sk-live-abc123
'''),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('an unknown key is refused and the nearest is suggested', () {
    expect(
      () => _parse('''
screen: /s
apiSource:
  baseUrl: https://api.example.com
  methd: GET
  endpoint: /p
'''),
      throwsA(
        isA<MappingsFormatException>()
            .having((e) => e.message, 'message', contains('method')),
      ),
    );
  });

  test('a missing method or endpoint is refused', () {
    expect(
      () => _parse('screen: /s\napiSource:\n  baseUrl: https://a.example\n'),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('the required endpoint is derived from the base URL path', () {
    // The application calls /api/v1/products/123. Matching on
    // /products/123 alone would miss it entirely.
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example/api/v1
  method: GET
  endpoint: /products/123
''').apiSource!;
    final endpoint = source.requiredEndpoint('https://host.example/api/v1');
    expect(endpoint.method, 'GET');
    expect(endpoint.path, '/api/v1/products/123');
    expect(endpoint.matches('GET', '/api/v1/products/123'), isTrue);
    expect(endpoint.matches('GET', '/products/123'), isFalse);
  });

  test('a base URL with no path yields the endpoint unchanged', () {
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /products/123
''').apiSource!;
    expect(
        source.requiredEndpoint('https://host.example').path, '/products/123');
  });

  test('a trailing slash on the base URL does not double up', () {
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example/api/
  method: GET
  endpoint: /products/123
''').apiSource!;
    expect(source.requiredEndpoint('https://host.example/api/').path,
        '/api/products/123');
  });

  test('headers, query and body are optional and parse', () {
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example
  method: POST
  endpoint: /search
  headers:
    Accept: application/json
  query:
    include: pricing
  body: '{"q":"shoes"}'
''').apiSource!;
    expect(source.headers['Accept'], 'application/json');
    expect(source.query['include'], 'pricing');
    expect(source.body, '{"q":"shoes"}');
    expect(source.resolvedUri('https://host.example').toString(),
        'https://host.example/search?include=pricing');
  });

  test('the method is upper-cased so matching is not case-dependent', () {
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example
  method: get
  endpoint: /p
''').apiSource!;
    expect(source.method, 'GET');
  });

  test('a screen with no apiSource has none', () {
    expect(_parse('screen: /s').apiSource, isNull);
  });
}
