import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:yaml/yaml.dart';

FigmaTolerances _parse(String yaml) => FigmaTolerances.fromYaml(
      loadYaml(yaml),
      source: 'test.yaml',
    );

void main() {
  group('FigmaTolerances', () {
    test('defaults are stated in one place, not at the call sites', () {
      const tolerances = FigmaTolerances.defaults;

      expect(tolerances.positionPx, 4);
      expect(tolerances.sizePx, 3);
      expect(tolerances.fontSizePx, 1);
    });

    test('ignores design copy by default, because a design holds '
        'placeholder text and the app holds live data', () {
      expect(FigmaTolerances.defaults.text, TextComparisonMode.ignore);
    });

    test('leaves font family comparison off by default, because Flutter '
        'reports package-prefixed family names', () {
      expect(FigmaTolerances.defaults.checkFontFamily, isFalse);
    });

    test('does not report unexpected elements by default', () {
      expect(FigmaTolerances.defaults.reportUnexpected, isFalse);
    });

    test('reads overrides', () {
      final tolerances = _parse('''
positionPx: 10
sizePx: 6
fontSizePx: 2
text: strict
checkFontFamily: true
reportUnexpected: true
checkOrdering: false
''');

      expect(tolerances.positionPx, 10);
      expect(tolerances.sizePx, 6);
      expect(tolerances.fontSizePx, 2);
      expect(tolerances.text, TextComparisonMode.strict);
      expect(tolerances.checkFontFamily, isTrue);
      expect(tolerances.reportUnexpected, isTrue);
      expect(tolerances.checkOrdering, isFalse);
    });

    test('an absent section means the defaults', () {
      expect(
        FigmaTolerances.fromYaml(null, source: 'test.yaml'),
        FigmaTolerances.defaults,
      );
    });

    test('rejects an unknown key rather than silently ignoring it', () {
      expect(
        () => _parse('positionPix: 10'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('positionPix'), contains('positionPx')),
          ),
        ),
      );
    });

    test('rejects an unknown text mode and names the valid ones', () {
      expect(
        () => _parse('text: sometimes'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('sometimes'), contains('strict')),
          ),
        ),
      );
    });

    test('rejects a negative tolerance', () {
      expect(() => _parse('positionPx: -1'), throwsA(isA<FormatException>()));
    });
  });
}
