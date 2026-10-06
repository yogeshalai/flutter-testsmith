import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

MappingsFile _parse(String yaml) =>
    MappingsFile.parse(yaml, source: 'test.yaml');

void main() {
  test('a figmaSource block parses', () {
    final source = _parse('''
screen: /product/details
figmaSource:
  url: https://figma.com/design/abc123/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/product_details.mapping.yaml
''').figmaSource!;
    expect(source.url, contains('node-id=909-1'));
    expect(source.token.name, 'FIGMA_TOKEN');
    expect(source.mappingPath, 'figma/product_details.mapping.yaml');
  });

  test('a literal Figma token is refused at parse time', () {
    expect(
      () => _parse('''
screen: /s
figmaSource:
  url: https://figma.com/design/abc/F?node-id=1-2
  token: figd_realtokenvalue
  mapping: m.yaml
'''),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('a url that names no node is refused', () {
    expect(
      () => _parse('''
screen: /s
figmaSource:
  url: https://figma.com/design/abc/File
  token: env:FIGMA_TOKEN
  mapping: m.yaml
'''),
      throwsA(
        isA<MappingsFormatException>()
            .having((e) => e.message, 'message', contains('node-id')),
      ),
    );
  });

  test('an unknown key is refused', () {
    expect(
      () => _parse('''
screen: /s
figmaSource:
  url: https://figma.com/design/abc/F?node-id=1-2
  token: env:FIGMA_TOKEN
  mappng: m.yaml
'''),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('a missing mapping path is refused', () {
    // Mapping by node id is mandatory: layer names like "Rectangle 91"
    // are not identifiers, and inferring ids from them produces
    // something that looks like it works and is wrong.
    expect(
      () => _parse('''
screen: /s
figmaSource:
  url: https://figma.com/design/abc/F?node-id=1-2
  token: env:FIGMA_TOKEN
'''),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('a screen with no figmaSource has none', () {
    expect(_parse('screen: /s').figmaSource, isNull);
  });
}
