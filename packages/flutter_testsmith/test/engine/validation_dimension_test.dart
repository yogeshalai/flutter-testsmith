import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

void main() {
  test('a result with no dimension takes the validator default', () {
    const result = ValidationResult.pass(
      validatorId: 'api-to-ui',
      message: 'matches',
    );
    expect(result.dimension, isNull);
    expect(result.inDimension(ValidationDimension.api).dimension,
        ValidationDimension.api);
  });

  test('an explicitly stamped dimension survives the default', () {
    const result = ValidationResult.error(
      validatorId: 'api-to-ui',
      message: 'one test id is on two elements',
      dimension: ValidationDimension.ui,
    );
    // The validator's default is api; this result is about UI evidence.
    expect(result.inDimension(ValidationDimension.api).dimension,
        ValidationDimension.ui);
  });

  test('inDimension preserves every other field', () {
    const result = ValidationResult.fail(
      validatorId: 'figma-geometry',
      message: 'width differs',
      elementId: 'login.continue_button',
      expected: 322.0,
      actual: 282.0,
      evidence: [Evidence(kind: 'figmaNode', reference: '909:133')],
    );
    final stamped = result.inDimension(ValidationDimension.figma);
    expect(stamped.validatorId, 'figma-geometry');
    expect(stamped.status, ValidationStatus.fail);
    expect(stamped.elementId, 'login.continue_button');
    expect(stamped.expected, 322.0);
    expect(stamped.actual, 282.0);
    expect(stamped.evidence.single.reference, '909:133');
    expect(stamped.severity, Severity.critical);
  });

  test('the dimension reaches the JSON', () {
    const result = ValidationResult.pass(
      validatorId: 'ui-presence',
      message: 'present',
      dimension: ValidationDimension.ui,
    );
    expect(result.toJson()['dimension'], 'ui');
  });

  test('a result with no dimension omits the key rather than writing null',
      () {
    const result = ValidationResult.pass(validatorId: 'x', message: 'y');
    expect(result.toJson().containsKey('dimension'), isFalse);
  });

  test('a UI-evidence failure is never attributed to API or Figma', () {
    // No UI tree captured at all: the tool could not read the UI, so
    // nothing was compared against the API. Reporting this as an API
    // result would make the API dimension speak for a check that never
    // ran.
    final context = ValidationContext(
      session: ScreenSession(
        screenId: '/product/details',
        enteredAt: DateTime.utc(2026, 9, 15),
      ),
      mappings: MappingsFile.parse(
        'screen: /product/details\n'
        'mappings:\n'
        '  - target: product.price\n'
        '    source: response.price\n',
        source: 'test',
      ),
    );

    final results = runValidator(const ApiToUiValidator(), context);
    expect(results.single.status, ValidationStatus.error);
    expect(results.single.dimension, ValidationDimension.ui);
  });

  test('rules attribute a missing UI tree to ui, not to api', () {
    final results = runValidator(
      const RulesValidator(),
      ValidationContext(
        session: ScreenSession(
          screenId: '/product/details',
          enteredAt: DateTime.utc(2026, 9, 15),
        ),
        mappings: MappingsFile.parse(
          'screen: /product/details\n'
          'rules:\n'
          '  - condition: "available == false"\n'
          '    expectations:\n'
          '      - element: product.add_to_cart\n'
          '        property: enabled\n'
          '        equals: false\n',
          source: 'test',
        ),
      ),
    );
    expect(results.single.dimension, ValidationDimension.ui);
    expect(results.single.message, contains('UI tree'));
  });

  test('each validator declares the source of truth it measures against', () {
    expect(const ApiToUiValidator().dimension, ValidationDimension.api);
    expect(const UiPresenceValidator().dimension, ValidationDimension.ui);
    expect(const RulesValidator().dimension, ValidationDimension.api);
    expect(
        const FigmaStructureValidator().dimension, ValidationDimension.figma);
  });
}
