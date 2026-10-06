import 'package:flutter_testsmith/figma.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/protocol.dart';

const _screen = '/product/details';

LogicalRect _rect(double x, double y, double w, double h) =>
    LogicalRect(x: x, y: y, width: w, height: h);

/// A design element with the semantics these tests have always assumed.
///
/// Left- and top-anchored with a fixed size, which is what Figma reports
/// for an absolutely positioned layer with the default `LEFT/TOP`
/// constraints - the shape every element in this file is modelling.
///
/// It has to be said out loud now. Before E-02's projection model the
/// validator treated every element this way implicitly; it now reads the
/// design's declared anchor, and an element that declares nothing is
/// skipped rather than assumed. Making the assumption visible here is
/// the point: these fixtures assert about geometry, so they have to say
/// what their geometry means.
FigmaElement _design(
  String semanticId, {
  required FigmaElementType type,
  required LogicalRect rect,
  String? text,
  FigmaTypography? typography,
  String? fill,
  FigmaAxisLayout horizontal = const FigmaAxisLayout(
    anchor: FigmaAnchor.start,
    sizing: FigmaSizing.fixed,
  ),
  FigmaAxisLayout vertical = const FigmaAxisLayout(
    anchor: FigmaAnchor.start,
    sizing: FigmaSizing.fixed,
  ),
}) =>
    FigmaElement(
      nodeId: 'n:$semanticId',
      figmaName: 'Layer $semanticId',
      semanticId: semanticId,
      type: type,
      rect: rect,
      text: text,
      typography: typography,
      fill: fill,
      horizontal: horizontal,
      vertical: vertical,
    );

FigmaScreenSpec _spec(
  List<FigmaElement> elements, {
  double width = 400,
  double height = 800,
  List<String> unmatched = const [],
}) =>
    FigmaScreenSpec(
      screen: _screen,
      nodeId: '1:1',
      figmaName: 'Product Details',
      width: width,
      height: height,
      elements: elements,
      unmatchedMappings: unmatched,
    );

UiSnapshot _snapshot(
  List<UiNode> children, {
  double width = 400,
  double height = 800,
  Set<String> duplicates = const {},
}) =>
    UiSnapshot(
      screenId: _screen,
      capturedAt: DateTime.utc(2026, 9, 11),
      devicePixelRatio: 3,
      totalElementsWalked: 120,
      duplicateTestIds: duplicates,
      viewport: _rect(0, 0, width, height),
      root: UiNode(
        // Deliberately narrower than the viewport: the synthetic root is
        // the union of retained nodes, and anything that reads it as the
        // screen size is wrong.
        type: 'Root',
        bounds: _rect(0, 0, width / 2, height / 2),
        children: children,
      ),
    );

ValidationContext _context(
  FigmaScreenSpec spec,
  UiSnapshot snapshot, {
  FigmaTolerances? tolerances,
}) {
  final session = ScreenSession(
    screenId: _screen,
    enteredAt: DateTime.utc(2026, 9, 11),
  )..uiSnapshot = snapshot;

  return ValidationContext(
    session: session,
    figmaSpec: spec,
    figmaTolerances: tolerances,
  );
}

List<ValidationResult> _run(ValidationContext context) =>
    const FigmaStructureValidator().validate(context);

ValidationResult _resultFor(List<ValidationResult> results, String elementId) =>
    results.firstWhere((r) => r.elementId == elementId);

Iterable<ValidationResult> _failures(List<ValidationResult> results) =>
    results.where((r) => r.status == ValidationStatus.fail);

void main() {
  textAlignmentTests();
  group('FigmaStructureValidator', () {
    test('reports a required design element that is absent from the '
        'Flutter UI', () {
      // Phase 6 exit criterion: product.add_to_cart is in the design and
      // has been removed from the app.
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
        ),
        _design(
          'product.add_to_cart',
          type: FigmaElementType.instance,
          rect: _rect(20, 700, 360, 48),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
        ),
      ]);

      final results = _run(_context(spec, snapshot));
      final missing = _resultFor(results, 'product.add_to_cart');

      expect(missing.status, ValidationStatus.fail);
      expect(missing.message, contains('product.add_to_cart'));
      expect(missing.message, contains('design'));
      // The diagnostic has to say what *is* there, or the reader has to
      // go and dump the tree themselves.
      expect(missing.message, contains('product.name'));
    });

    test('passes an element that is present and aligned', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
        ),
      ]);

      final results = _run(_context(spec, snapshot));

      expect(_failures(results), isEmpty);
      expect(results.any((r) => r.status == ValidationStatus.pass), isTrue);
    });

    test('holds a design inset at its own length on a wider screen', () {
      // This test used to assert the opposite: that a design authored at
      // 400pt on an 800pt screen should have *every* coordinate doubled.
      //
      // That is what a design would do if it were a picture. It is not.
      // A 20pt gutter is 20pt on a wider screen - Figma's own
      // auto-layout does not rescale padding when a frame is resized -
      // and scaling it produced an error proportional to the distance
      // from the origin. Measured on a real device: 5.6px of invented
      // error near the top of a screen and 63.6px at the bottom, on an
      // application that was laying out correctly.
      //
      // So: the leading inset stays 20, and the element is left where
      // the design put it.
      final spec = _spec(
        [
          _design(
            'product.name',
            type: FigmaElementType.text,
            rect: _rect(20, 100, 300, 28),
          ),
        ],
        width: 400,
        height: 800,
      );

      final snapshot = _snapshot(
        [
          UiNode(
            testId: 'product.name',
            type: 'Text',
            text: 'Nike Air Max',
            bounds: _rect(20, 100, 300, 28),
          ),
        ],
        width: 800,
        height: 1600,
      );

      expect(_failures(_run(_context(spec, snapshot))), isEmpty);
    });

    test('and reports a doubled inset as the error it is', () {
      // The old model called this correct. It is a 20pt gutter rendered
      // at 40pt.
      final spec = _spec(
        [
          _design(
            'product.name',
            type: FigmaElementType.text,
            rect: _rect(20, 100, 300, 28),
          ),
        ],
        width: 400,
        height: 800,
      );

      final snapshot = _snapshot(
        [
          UiNode(
            testId: 'product.name',
            type: 'Text',
            text: 'Nike Air Max',
            bounds: _rect(40, 200, 600, 56),
          ),
        ],
        width: 800,
        height: 1600,
      );

      expect(
        _failures(_run(_context(spec, snapshot))).map((r) => r.validatorId),
        contains('figma-geometry'),
      );
    });

    test('fails a position that drifts beyond the tolerance, and says by '
        'how much', () {
      final spec = _spec([
        _design(
          'product.price',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 100, 24),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.price',
          type: 'Text',
          text: '2,999',
          bounds: _rect(20, 430, 100, 24),
        ),
      ]);

      final results = _run(_context(spec, snapshot));
      final geometry = results.firstWhere(
        (r) => r.validatorId.contains('geometry') && r.isFailure,
      );

      expect(geometry.message, contains('30'));
      expect(geometry.elementId, 'product.price');
    });

    test('honours a widened position tolerance', () {
      final spec = _spec([
        _design(
          'product.price',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 100, 24),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.price',
          type: 'Text',
          text: '2,999',
          bounds: _rect(20, 430, 100, 24),
        ),
      ]);

      final results = _run(
        _context(
          spec,
          snapshot,
          tolerances: const FigmaTolerances(positionPx: 40),
        ),
      );

      expect(_failures(results), isEmpty);
    });

    test('skips vertical checks when the design frame is a different '
        'shape from the viewport, instead of failing everything', () {
      // A 400x1600 scrolling design against a 400x800 viewport: y is not
      // meaningfully comparable, but x and size still are.
      final spec = _spec(
        [
          _design(
            'product.name',
            type: FigmaElementType.text,
            rect: _rect(20, 900, 300, 28),
          ),
        ],
        width: 400,
        height: 1600,
      );

      final snapshot = _snapshot(
        [
          UiNode(
            testId: 'product.name',
            type: 'Text',
            text: 'Nike Air Max',
            bounds: _rect(20, 400, 300, 28),
          ),
        ],
        width: 400,
        height: 800,
      );

      final results = _run(_context(spec, snapshot));

      expect(_failures(results), isEmpty);
      final skipped = results.where(
        (r) => r.status == ValidationStatus.skip,
      );
      expect(skipped, isNotEmpty);
      expect(
        skipped.map((r) => r.message).join(' '),
        contains('aspect'),
      );
    });

    test('fails a TEXT design node that maps to an element rendering no '
        'text', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'SizedBox',
          bounds: _rect(20, 400, 300, 28),
        ),
      ]);

      final results = _run(_context(spec, snapshot));
      final typeResult = results.firstWhere(
        (r) => r.validatorId.contains('type'),
      );

      expect(typeResult.status, ValidationStatus.fail);
    });

    test('does not judge the type of a design node that carries no type '
        'signal', () {
      final spec = _spec([
        _design(
          'product.add_to_cart',
          type: FigmaElementType.instance,
          rect: _rect(20, 400, 300, 48),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.add_to_cart',
          type: 'ElevatedButton',
          enabled: true,
          bounds: _rect(20, 400, 300, 48),
        ),
      ]);

      final results = _run(_context(spec, snapshot));

      expect(_failures(results), isEmpty);
    });

    test('does not compare the size of a TEXT node, because its box is a '
        'product of the font rather than of the layout', () {
      // Figma reports a text node's glyph box; Flutter reports a line
      // box. Neither font size nor line metrics are projected, so the
      // two can never agree - and figma-typography already checks the
      // font exactly.
      final spec = _spec([
        _design(
          'product.add_to_cart',
          type: FigmaElementType.text,
          rect: _rect(293, 400, 34, 12),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.add_to_cart',
          type: 'Text',
          text: 'Add',
          bounds: _rect(293, 400, 48, 19),
        ),
      ]);

      expect(_failures(_run(_context(spec, snapshot))), isEmpty);
    });

    test('still compares the position of a TEXT node', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(34, 400, 300, 20),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nonveg-Burger',
          bounds: _rect(120, 400, 300, 20),
        ),
      ]);

      final geometry = _run(_context(spec, snapshot)).firstWhere(
        (r) => r.validatorId.contains('geometry'),
      );

      expect(geometry.status, ValidationStatus.fail);
      expect(geometry.message, contains('x'));
    });

    test('still compares the size of a node whose box is laid out, not '
        'typeset', () {
      final spec = _spec([
        _design(
          'product.image',
          type: FigmaElementType.image,
          rect: _rect(20, 137, 362, 362),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.image',
          type: 'Image',
          bounds: _rect(20, 137, 200, 200),
        ),
      ]);

      final geometry = _run(_context(spec, snapshot)).firstWhere(
        (r) => r.validatorId.contains('geometry'),
      );

      expect(geometry.status, ValidationStatus.fail);
      expect(geometry.message, contains('width'));
    });

    test('compares text size when explicitly asked to', () {
      final spec = _spec([
        _design(
          'product.add_to_cart',
          type: FigmaElementType.text,
          rect: _rect(293, 400, 34, 12),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.add_to_cart',
          type: 'Text',
          text: 'Add',
          bounds: _rect(293, 400, 48, 19),
        ),
      ]);

      final results = _run(
        _context(
          spec,
          snapshot,
          tolerances: const FigmaTolerances(checkTextSize: true),
        ),
      );

      expect(_failures(results), isNotEmpty);
    });

    test('accepts a TEXT design node whose label is rendered by a '
        'descendant', () {
      // The canonical shape: the test id is on the button a person taps,
      // and the design's TEXT node describes the label inside it.
      final spec = _spec([
        _design(
          'product.add_to_cart',
          type: FigmaElementType.text,
          rect: _rect(20, 700, 360, 48),
          text: 'Add to cart',
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.add_to_cart',
          type: 'FilledButton',
          enabled: true,
          bounds: _rect(20, 700, 360, 48),
          children: [
            UiNode(
              type: 'Text',
              text: 'Add to cart',
              bounds: _rect(140, 714, 120, 20),
              properties: const {'fontSize': 16.0},
            ),
          ],
        ),
      ]);

      final results = _run(
        _context(
          spec,
          snapshot,
          tolerances: const FigmaTolerances(text: TextComparisonMode.strict),
        ),
      );

      expect(_failures(results), isEmpty);
    });

    test('reads typography from the descendant that renders the text, '
        'not from the element carrying the id', () {
      final spec = _spec([
        _design(
          'product.add_to_cart',
          type: FigmaElementType.text,
          rect: _rect(20, 700, 360, 48),
          typography: const FigmaTypography(
            fontFamily: 'Inter',
            fontSize: 16,
            fontWeight: 500,
          ),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.add_to_cart',
          type: 'FilledButton',
          bounds: _rect(20, 700, 360, 48),
          children: [
            UiNode(
              type: 'Text',
              text: 'Add to cart',
              bounds: _rect(140, 714, 120, 20),
              properties: const {'fontSize': 28.0, 'fontWeight': 500},
            ),
          ],
        ),
      ]);

      final typography = _run(_context(spec, snapshot)).firstWhere(
        (r) => r.validatorId.contains('typography'),
      );

      expect(typography.status, ValidationStatus.fail);
      expect(typography.message, contains('28'));
    });

    test('does not guess a label when several descendants render text', () {
      final spec = _spec([
        _design(
          'product.card',
          type: FigmaElementType.text,
          rect: _rect(20, 700, 360, 48),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.card',
          type: 'Card',
          bounds: _rect(20, 700, 360, 48),
          children: [
            UiNode(type: 'Text', text: 'One', bounds: _rect(20, 700, 50, 20)),
            UiNode(type: 'Text', text: 'Two', bounds: _rect(20, 720, 50, 20)),
          ],
        ),
      ]);

      final typeResult = _run(_context(spec, snapshot)).firstWhere(
        (r) => r.validatorId.contains('type'),
      );

      expect(typeResult.status, ValidationStatus.fail);
    });

    test('ignores design copy by default but compares it in strict '
        'mode', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
          text: 'Product Name',
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
        ),
      ]);

      expect(_failures(_run(_context(spec, snapshot))), isEmpty);

      final strict = _run(
        _context(
          spec,
          snapshot,
          tolerances: const FigmaTolerances(text: TextComparisonMode.strict),
        ),
      );

      expect(
        _failures(strict).map((r) => r.validatorId),
        contains(contains('text')),
      );
    });

    test('reports a mapping pointing at a deleted layer as an error, not '
        'a failure of the app', () {
      final spec = _spec(
        [
          _design(
            'product.name',
            type: FigmaElementType.text,
            rect: _rect(20, 400, 300, 28),
          ),
        ],
        unmatched: ['1410:9999'],
      );

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
        ),
      ]);

      final results = _run(_context(spec, snapshot));
      final stale = results.firstWhere(
        (r) => r.status == ValidationStatus.error,
      );

      expect(stale.message, contains('1410:9999'));
    });

    test('detects a vertical ordering inversion', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
        ),
        _design(
          'product.price',
          type: FigmaElementType.text,
          rect: _rect(20, 450, 100, 24),
        ),
      ]);

      // The app renders the price above the name.
      final snapshot = _snapshot([
        UiNode(
          testId: 'product.price',
          type: 'Text',
          text: '2,999',
          bounds: _rect(20, 400, 100, 24),
        ),
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 450, 300, 28),
        ),
      ]);

      final results = _run(
        _context(
          spec,
          snapshot,
          // Widen geometry so ordering is the only thing under test.
          tolerances: const FigmaTolerances(positionPx: 200),
        ),
      );

      final ordering = results.firstWhere(
        (r) => r.validatorId.contains('order'),
      );

      expect(ordering.status, ValidationStatus.fail);
      expect(ordering.message, contains('product.name'));
      expect(ordering.message, contains('product.price'));
    });

    test('compares typography when the app reported a text style', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
          typography: const FigmaTypography(
            fontFamily: 'Inter',
            fontSize: 20,
            fontWeight: 600,
          ),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
          properties: const {'fontSize': 14.0, 'fontWeight': 600},
        ),
      ]);

      final results = _run(_context(spec, snapshot));
      final typography = results.firstWhere(
        (r) => r.validatorId.contains('typography'),
      );

      expect(typography.status, ValidationStatus.fail);
      expect(typography.message, contains('20'));
      expect(typography.message, contains('14'));
    });

    test('skips typography rather than failing it when the app reported '
        'no text style', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
          typography: const FigmaTypography(
            fontFamily: 'Inter',
            fontSize: 20,
            fontWeight: 600,
          ),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
        ),
      ]);

      final results = _run(_context(spec, snapshot));
      final typography = results.firstWhere(
        (r) => r.validatorId.contains('typography'),
      );

      expect(typography.status, ValidationStatus.skip);
    });

    test('compares colour within a channel tolerance', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
          fill: '#1a1a1aff',
        ),
      ]);

      final near = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
          properties: const {'color': '#1c1c1cff'},
        ),
      ]);

      expect(_failures(_run(_context(spec, near))), isEmpty);

      final far = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
          properties: const {'color': '#ff0000ff'},
        ),
      ]);

      final results = _run(_context(spec, far));
      final colour = results.firstWhere(
        (r) => r.validatorId.contains('colour'),
      );

      expect(colour.status, ValidationStatus.fail);
      expect(colour.message, contains('#ff0000ff'));
    });

    test('reports an ambiguous test id as an error rather than picking one', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
        ),
      ]);

      final snapshot = _snapshot(
        [
          UiNode(
            testId: 'product.name',
            type: 'Text',
            text: 'Nike Air Max',
            bounds: _rect(20, 400, 300, 28),
          ),
        ],
        duplicates: {'product.name'},
      );

      final results = _run(_context(spec, snapshot));

      // An error, not a failure. The application may be perfectly
      // correct; what is broken is the comparison's ability to say
      // which element the design node refers to. Both still block the
      // pass, but only one of them accuses the app.
      final result = _resultFor(results, 'product.name');

      expect(result.status, ValidationStatus.error);
      expect(result.validatorId, 'figma-identity');
    });

    test('stays quiet about extra elements unless asked', () {
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
        ),
      ]);

      final snapshot = _snapshot([
        UiNode(
          testId: 'product.name',
          type: 'Text',
          text: 'Nike Air Max',
          bounds: _rect(20, 400, 300, 28),
        ),
        UiNode(
          testId: 'debug.banner',
          type: 'Text',
          text: 'DEBUG',
          bounds: _rect(0, 0, 50, 20),
        ),
      ]);

      expect(_failures(_run(_context(spec, snapshot))), isEmpty);

      final strict = _run(
        _context(
          spec,
          snapshot,
          tolerances: const FigmaTolerances(reportUnexpected: true),
        ),
      );

      expect(
        _failures(strict).map((r) => r.elementId),
        contains('debug.banner'),
      );
    });

    test('skips geometry, but checks everything else, when the app did '
        'not report a viewport', () {
      // An older SDK. The root bounds are NOT an acceptable substitute:
      // projecting against them scales every coordinate wrongly and
      // reports a correct layout as misplaced.
      final spec = _spec([
        _design(
          'product.name',
          type: FigmaElementType.text,
          rect: _rect(20, 400, 300, 28),
        ),
      ]);

      final session = ScreenSession(
        screenId: _screen,
        enteredAt: DateTime.utc(2026, 9, 11),
      )..uiSnapshot = UiSnapshot(
          screenId: _screen,
          capturedAt: DateTime.utc(2026, 9, 11),
          devicePixelRatio: 3,
          root: UiNode(
            type: 'Root',
            bounds: _rect(0, 0, 200, 400),
            children: [
              UiNode(
                testId: 'product.name',
                type: 'Text',
                text: 'Nike Air Max',
                bounds: _rect(999, 999, 1, 1),
              ),
            ],
          ),
        );

      final results = _run(
        ValidationContext(session: session, figmaSpec: spec),
      );

      // Wildly wrong bounds, yet no geometry failure: it was not judged.
      expect(_failures(results), isEmpty);

      final skipped = results.firstWhere(
        (r) => r.status == ValidationStatus.skip,
      );
      expect(skipped.message, contains('viewport'));

      // Presence and type still ran.
      expect(
        results.where((r) => r.status == ValidationStatus.pass),
        isNotEmpty,
      );
    });

    test('skips, rather than passing, when no design is configured', () {
      final session = ScreenSession(
        screenId: _screen,
        enteredAt: DateTime.utc(2026, 9, 11),
      )..uiSnapshot = _snapshot([]);

      final results =
          _run(ValidationContext(session: session, figmaSpec: null));

      expect(results.single.status, ValidationStatus.skip);
    });

    test('errors when there is a design but no captured tree', () {
      final session = ScreenSession(
        screenId: _screen,
        enteredAt: DateTime.utc(2026, 9, 11),
      );

      final results = _run(
        ValidationContext(
          session: session,
          figmaSpec: _spec([
            _design(
              'product.name',
              type: FigmaElementType.text,
              rect: _rect(20, 400, 300, 28),
            ),
          ]),
        ),
      );

      expect(results.single.status, ValidationStatus.error);
    });

    test('skips when the design has no mapped elements, because an '
        'unmapped design can say nothing about the app', () {
      final spec = _spec([
        const FigmaElement(
          nodeId: '913:4',
          figmaName: 'Rectangle 91',
          type: FigmaElementType.shape,
          rect: LogicalRect(x: 0, y: 0, width: 8, height: 8),
        ),
      ]);

      final results = _run(_context(spec, _snapshot([])));

      expect(results.single.status, ValidationStatus.skip);
      expect(results.single.message, contains('mapping'));
    });
  });
}

/// Added in Phase 12, from a device measurement: a right-aligned total
/// whose right edge was 0.9px from the design reported x as 50.8px out,
/// because the design frame's font measured the same string 51px wider.
void textAlignmentTests() {
  FigmaScreenSpec design(String align, LogicalRect rect) => FigmaScreenSpec(
        screen: '/s',
        nodeId: 'n',
        figmaName: 'Frame',
        width: 400,
        height: 800,
        elements: [
          FigmaElement(
            nodeId: '1',
            figmaName: 'amount',
            semanticId: 'amount',
            type: FigmaElementType.text,
            rect: rect,
            text: 'Rs 0',
            typography: FigmaTypography(
              fontFamily: 'Roboto',
              fontSize: 14,
              fontWeight: 400,
              textAlign: align,
            ),
          ),
        ],
      );

  UiSnapshot screen(LogicalRect rect) => UiSnapshot(
        screenId: '/s',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 2,
        viewport: const LogicalRect(x: 0, y: 0, width: 400, height: 800),
        root: UiNode(
          type: 'Root',
          bounds: const LogicalRect(x: 0, y: 0, width: 400, height: 800),
          children: [
            UiNode(
              testId: 'amount',
              type: 'Text',
              text: 'Rs 4,129',
              bounds: rect,
              properties: const {
                'fontSize': 14.0,
                'fontWeight': 400,
                'fontFamily': 'Roboto',
              },
            ),
          ],
        ),
      );

  List<ValidationResult> run(
    FigmaScreenSpec spec,
    UiSnapshot snapshot, {
    TextAnchor anchor = TextAnchor.left,
  }) {
    final session = ScreenSession(
      screenId: '/s',
      enteredAt: DateTime.utc(2026),
    )..uiSnapshot = snapshot;
    return const FigmaStructureValidator().validate(
      ValidationContext(
        session: session,
        figmaSpec: spec,
        figmaTolerances: FigmaTolerances(textAnchor: anchor),
      ),
    );
  }

  ValidationResult geometry(List<ValidationResult> results) =>
      results.firstWhere((r) => r.validatorId == 'figma-geometry');

  group('a right-aligned text node', () {
    test('is judged on its right edge, not its x', () {
      // Design box 260..370. Rendered box 310..370: same right edge, a
      // width the font decided. That is a correct screen.
      final results = run(
        design('RIGHT', const LogicalRect(x: 260, y: 100, width: 110, height: 20)),
        screen(const LogicalRect(x: 310, y: 100, width: 60, height: 20)),
        anchor: TextAnchor.right,
      );

      expect(geometry(results).status, ValidationStatus.pass);
    });

    test('still fails when the anchored edge really moved', () {
      // The honest-skip must not become a blanket excuse.
      final results = run(
        design('RIGHT', const LogicalRect(x: 260, y: 100, width: 110, height: 20)),
        screen(const LogicalRect(x: 280, y: 100, width: 60, height: 20)),
        anchor: TextAnchor.right,
      );

      final result = geometry(results);
      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('horizontal trailing inset'));
    });
  });

  group('a centred text node', () {
    test('is judged on its centre', () {
      final results = run(
        design('CENTER', const LogicalRect(x: 145, y: 100, width: 110, height: 20)),
        screen(const LogicalRect(x: 170, y: 100, width: 60, height: 20)),
        anchor: TextAnchor.centre,
      );

      expect(geometry(results).status, ValidationStatus.pass);
    });
  });

  group('a left-aligned text node', () {
    test('is judged on its x, as before', () {
      final results = run(
        design('LEFT', const LogicalRect(x: 20, y: 100, width: 110, height: 20)),
        screen(const LogicalRect(x: 20, y: 100, width: 60, height: 20)),
      );

      expect(geometry(results).status, ValidationStatus.pass);
    });

    test('a left-aligned node that moved still fails on x', () {
      final results = run(
        design('LEFT', const LogicalRect(x: 20, y: 100, width: 110, height: 20)),
        screen(const LogicalRect(x: 60, y: 100, width: 60, height: 20)),
      );

      final result = geometry(results);
      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('horizontal leading inset'));
    });
  });

  test('a CENTER-aligned design node is still judged on x by default', () {
    // The lesson of the regression this setting exists for: Figma's
    // textAlign is about the glyphs inside the box, and the example
    // application has a left-positioned total whose design node says
    // CENTER. Inferring from it reported a pixel-perfect element as
    // 5.7px out.
    final results = run(
      design('CENTER', const LogicalRect(x: 20, y: 100, width: 110, height: 20)),
      screen(const LogicalRect(x: 20, y: 100, width: 60, height: 20)),
    );

    expect(geometry(results).status, ValidationStatus.pass);
  });

  test('when text sizes are compared, x is compared as usual', () {
    // With checkTextSize on, the two boxes are the same size and every
    // edge agrees, so there is nothing to choose between them.
    final session = ScreenSession(
      screenId: '/s',
      enteredAt: DateTime.utc(2026),
    )..uiSnapshot =
        screen(const LogicalRect(x: 310, y: 100, width: 60, height: 20));

    final results = const FigmaStructureValidator().validate(
      ValidationContext(
        session: session,
        figmaSpec:
            design('RIGHT', const LogicalRect(x: 260, y: 100, width: 110, height: 20)),
        figmaTolerances: const FigmaTolerances(
          checkTextSize: true,
          textAnchor: TextAnchor.right,
        ),
      ),
    );

    final result = geometry(results);
    expect(result.status, ValidationStatus.fail);
    expect(result.message, contains('horizontal leading inset'));
  });
}
