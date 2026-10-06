import 'package:flutter_testsmith/figma.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// The comparisons E-02 added: hierarchy, spacing, opacity, corner
/// radius, non-text fill, ambiguity-as-error, and coverage.
///
/// The design frame here is 400x800 and the viewport is 400x800, so the
/// projection is 1:1 and every number below is readable as written.
const _screen = '/login';

LogicalRect _rect(double x, double y, double w, double h) =>
    LogicalRect(x: x, y: y, width: w, height: h);

FigmaElement _design(
  String semanticId, {
  required FigmaElementType type,
  required LogicalRect rect,
  String? parentNodeId,
  String? fill,
  double opacity = 1,
  double? cornerRadius,
  FigmaLayout? layout,
}) =>
    FigmaElement(
      nodeId: 'n:$semanticId',
      figmaName: 'Layer $semanticId',
      parentNodeId: parentNodeId,
      semanticId: semanticId,
      type: type,
      rect: rect,
      fill: fill,
      opacity: opacity,
      cornerRadius: cornerRadius,
      layout: layout,
    );

FigmaScreenSpec _spec(
  List<FigmaElement> elements, {
  int totalNodesWalked = 0,
}) =>
    FigmaScreenSpec(
      screen: _screen,
      nodeId: '909:1',
      figmaName: 'Login',
      width: 400,
      height: 800,
      elements: elements,
      totalNodesWalked:
          totalNodesWalked == 0 ? elements.length : totalNodesWalked,
    );

UiNode _node(
  String? testId, {
  required String type,
  required LogicalRect bounds,
  Map<String, Object?> properties = const {},
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: testId,
      type: type,
      bounds: bounds,
      properties: properties,
      children: children,
    );

UiSnapshot _snapshot(
  List<UiNode> children, {
  Set<String> duplicates = const {},
}) =>
    UiSnapshot(
      screenId: _screen,
      capturedAt: DateTime.utc(2026, 9, 13),
      devicePixelRatio: 3,
      totalElementsWalked: 300,
      duplicateTestIds: duplicates,
      viewport: _rect(0, 0, 400, 800),
      root: UiNode(
        type: 'Root',
        bounds: _rect(0, 0, 400, 800),
        children: children,
      ),
    );

List<ValidationResult> _run(
  FigmaScreenSpec spec,
  UiSnapshot snapshot, {
  FigmaTolerances? tolerances,
}) {
  final session = ScreenSession(
    screenId: _screen,
    enteredAt: DateTime.utc(2026, 9, 13),
  )..uiSnapshot = snapshot;

  return const FigmaStructureValidator().validate(
    ValidationContext(
      session: session,
      figmaSpec: spec,
      figmaTolerances: tolerances,
    ),
  );
}

ValidationResult _by(List<ValidationResult> results, String validatorId) =>
    results.firstWhere((r) => r.validatorId == validatorId);

Iterable<ValidationResult> _allBy(
  List<ValidationResult> results,
  String validatorId,
) =>
    results.where((r) => r.validatorId == validatorId);

void main() {
  group('ambiguous identity', () {
    test('is an error, not a failure', () {
      // A duplicated test id means the comparison has no single
      // subject. That is not the application being wrong, it is the
      // comparison being unable to run - and reporting it as a failure
      // would put a tooling problem in the same bucket as a defect.
      final results = _run(
        _spec([
          _design(
            'login.continue',
            type: FigmaElementType.text,
            rect: _rect(40, 484, 322, 48),
          ),
        ]),
        _snapshot(
          [
            _node('login.continue',
                type: 'Text', bounds: _rect(40, 484, 322, 48)),
            _node('login.continue',
                type: 'Text', bounds: _rect(40, 600, 322, 48)),
          ],
          duplicates: {'login.continue'},
        ),
      );

      final ambiguous = _by(results, 'figma-identity');

      expect(ambiguous.status, ValidationStatus.error);
      expect(ambiguous.elementId, 'login.continue');
      expect(ambiguous.message, contains('more than one'));
    });

    test('does not guess which of the two was meant', () {
      final results = _run(
        _spec([
          _design(
            'login.continue',
            type: FigmaElementType.text,
            rect: _rect(40, 484, 322, 48),
          ),
        ]),
        _snapshot(
          [
            // The first is a perfect match. A validator that resolved
            // the ambiguity by taking it would report a clean pass.
            _node('login.continue',
                type: 'Text', bounds: _rect(40, 484, 322, 48)),
            _node('login.continue',
                type: 'Text', bounds: _rect(0, 0, 1, 1)),
          ],
          duplicates: {'login.continue'},
        ),
      );

      expect(_allBy(results, 'figma-geometry'), isEmpty);
      // No comparison produced a verdict about this id. `figma-coverage`
      // is excluded because it is a denominator rather than a judgement.
      expect(
        results.where((r) =>
            r.validatorId != 'figma-coverage' &&
            r.status == ValidationStatus.pass),
        isEmpty,
      );
    });
  });

  group('hierarchy', () {
    FigmaScreenSpec nested() => _spec([
          _design('login.card',
              type: FigmaElementType.container, rect: _rect(20, 322, 362, 341)),
          _design('login.continue',
              type: FigmaElementType.text,
              rect: _rect(40, 484, 322, 48),
              parentNodeId: 'n:login.card'),
        ]);

    test('passes when the design ancestry holds on the screen', () {
      final results = _run(
        nested(),
        _snapshot([
          _node('login.card', type: 'Column', bounds: _rect(20, 322, 362, 341),
              children: [
                _node('login.continue',
                    type: 'Text', bounds: _rect(40, 484, 322, 48)),
              ]),
        ]),
      );

      expect(_by(results, 'figma-hierarchy').status, ValidationStatus.pass);
    });

    test('fails when a designed child is not inside its designed parent', () {
      final results = _run(
        nested(),
        _snapshot([
          _node('login.card', type: 'Column', bounds: _rect(20, 322, 362, 341)),
          // Same geometry, wrong place in the tree.
          _node('login.continue',
              type: 'Text', bounds: _rect(40, 484, 322, 48)),
        ]),
      );

      final hierarchy = _by(results, 'figma-hierarchy');

      expect(hierarchy.status, ValidationStatus.fail);
      expect(hierarchy.message, contains('login.continue'));
      expect(hierarchy.message, contains('login.card'));
    });

    test('asserts nothing about siblings', () {
      // Figma siblings nested inside one another in Flutter is an
      // implementation detail, not a defect: Flutter trees are far
      // deeper than design trees and wrappers are everywhere.
      final results = _run(
        _spec([
          _design('a',
              type: FigmaElementType.text, rect: _rect(0, 0, 100, 20)),
          _design('b',
              type: FigmaElementType.text, rect: _rect(0, 40, 100, 20)),
        ]),
        _snapshot([
          _node('a', type: 'Text', bounds: _rect(0, 0, 100, 20), children: [
            _node('b', type: 'Text', bounds: _rect(0, 40, 100, 20)),
          ]),
        ]),
      );

      expect(
        _allBy(results, 'figma-hierarchy')
            .where((r) => r.status == ValidationStatus.fail),
        isEmpty,
      );
    });
  });

  group('spacing', () {
    test('compares the gap between adjacent mapped siblings', () {
      final results = _run(
        _spec([
          _design('card',
              type: FigmaElementType.container,
              rect: _rect(20, 100, 360, 200),
              layout: const FigmaLayout(
                direction: FigmaLayoutDirection.vertical,
                itemSpacing: 20,
              )),
          _design('first',
              type: FigmaElementType.text,
              rect: _rect(40, 120, 320, 40),
              parentNodeId: 'n:card'),
          _design('second',
              type: FigmaElementType.text,
              rect: _rect(40, 180, 320, 40),
              parentNodeId: 'n:card'),
        ]),
        _snapshot([
          _node('card', type: 'Column', bounds: _rect(20, 100, 360, 200),
              children: [
                _node('first', type: 'Text', bounds: _rect(40, 120, 320, 40)),
                // Gap of 20, exactly as designed.
                _node('second', type: 'Text', bounds: _rect(40, 180, 320, 40)),
              ]),
        ]),
      );

      expect(_by(results, 'figma-spacing').status, ValidationStatus.pass);
    });

    test('fails when the gap is wrong', () {
      final results = _run(
        _spec([
          _design('card',
              type: FigmaElementType.container,
              rect: _rect(20, 100, 360, 200),
              layout: const FigmaLayout(
                direction: FigmaLayoutDirection.vertical,
                itemSpacing: 20,
              )),
          _design('first',
              type: FigmaElementType.text,
              rect: _rect(40, 120, 320, 40),
              parentNodeId: 'n:card'),
          _design('second',
              type: FigmaElementType.text,
              rect: _rect(40, 180, 320, 40),
              parentNodeId: 'n:card'),
        ]),
        _snapshot([
          _node('card', type: 'Column', bounds: _rect(20, 100, 360, 200),
              children: [
                _node('first', type: 'Text', bounds: _rect(40, 120, 320, 40)),
                // Gap of 40 where the design says 20.
                _node('second', type: 'Text', bounds: _rect(40, 200, 320, 40)),
              ]),
        ]),
      );

      final spacing = _by(results, 'figma-spacing');

      expect(spacing.status, ValidationStatus.fail);
      expect(spacing.message, contains('20'));
      expect(spacing.message, contains('40'));
    });

    test('compares declared padding against the measured content inset', () {
      final results = _run(
        _spec([
          _design('card',
              type: FigmaElementType.container,
              rect: _rect(20, 100, 360, 200),
              layout: const FigmaLayout(
                direction: FigmaLayoutDirection.vertical,
                itemSpacing: 0,
                padding: FigmaEdgeInsets(
                  left: 20,
                  top: 24,
                  right: 20,
                  bottom: 24,
                ),
              )),
          // The single child sits exactly inside that padding, so the
          // design is self-consistent and the padding is comparable.
          _design('only',
              type: FigmaElementType.text,
              rect: _rect(40, 124, 320, 152),
              parentNodeId: 'n:card'),
        ]),
        _snapshot([
          _node('card', type: 'Column', bounds: _rect(20, 100, 360, 200),
              children: [
                _node('only', type: 'Text', bounds: _rect(40, 124, 320, 152)),
              ]),
        ]),
      );

      expect(_by(results, 'figma-padding').status, ValidationStatus.pass);
    });

    test('fails when the padding on one side is wrong', () {
      final results = _run(
        _spec([
          _design('card',
              type: FigmaElementType.container,
              rect: _rect(20, 100, 360, 200),
              layout: const FigmaLayout(
                direction: FigmaLayoutDirection.vertical,
                itemSpacing: 0,
                padding: FigmaEdgeInsets(
                  left: 20,
                  top: 24,
                  right: 20,
                  bottom: 24,
                ),
              )),
          _design('only',
              type: FigmaElementType.text,
              rect: _rect(40, 124, 320, 152),
              parentNodeId: 'n:card'),
        ]),
        _snapshot([
          _node('card', type: 'Column', bounds: _rect(20, 100, 360, 200),
              children: [
                // Left inset of 60, not 20.
                _node('only', type: 'Text', bounds: _rect(80, 124, 280, 152)),
              ]),
        ]),
      );

      final padding = _by(results, 'figma-padding');

      expect(padding.status, ValidationStatus.fail);
      expect(padding.message, contains('left'));
    });

    test('measures both sides from the same set of children', () {
      // Partial mapping is the normal case: a frame has four children
      // and a mapping names two. The design inset must then be measured
      // from those two - and so must the Flutter inset, or the two
      // numbers describe different content boxes and the comparison is
      // meaningless.
      //
      // Here the card holds an unmapped full-bleed divider that runs to
      // its left edge. The design measures its left padding from the two
      // mapped children and gets 20; measuring Flutter from *all* its
      // children gets 0, and the application is reported as wrong when
      // it is not.
      final results = _run(
        _spec([
          _design('card',
              type: FigmaElementType.container,
              rect: _rect(20, 322, 362, 341),
              layout: const FigmaLayout(
                direction: FigmaLayoutDirection.vertical,
                itemSpacing: 20,
                padding: FigmaEdgeInsets(
                  left: 20,
                  top: 24,
                  right: 20,
                  bottom: 24,
                ),
              )),
          // In the design too, and unmapped in both: it runs the full
          // width of the card, flush to its left edge.
          FigmaElement(
            nodeId: 'n:bleed',
            figmaName: 'Divider',
            parentNodeId: 'n:card',
            type: FigmaElementType.shape,
            rect: _rect(20, 346, 362, 1),
          ),
          _design('divider',
              type: FigmaElementType.container,
              rect: _rect(44, 552, 314, 19),
              parentNodeId: 'n:card'),
          _design('google',
              type: FigmaElementType.container,
              rect: _rect(40, 591, 322, 48),
              parentNodeId: 'n:card'),
        ]),
        _snapshot([
          _node('card', type: 'Column', bounds: _rect(20, 322, 362, 341),
              children: [
                // Unmapped, and flush to the card's left and right
                // edges - so it is in neither side's mapped set.
                _node(null, type: 'Divider', bounds: _rect(20, 346, 362, 1)),
                _node('divider',
                    type: 'Row', bounds: _rect(44, 552, 314, 19)),
                _node('google',
                    type: 'ElevatedButton', bounds: _rect(40, 591, 322, 48)),
              ]),
        ]),
      );

      final padding =
          results.where((r) => r.validatorId == 'figma-padding').toList();

      // Left, right and bottom agree and are compared; top is skipped
      // because the design does not hug there.
      expect(
        padding.where((r) => r.status == ValidationStatus.fail),
        isEmpty,
        reason: padding.map((r) => r.message).join(' | '),
      );
      expect(
        padding.firstWhere((r) => r.status == ValidationStatus.skip).message,
        contains('top'),
      );
    });

    test('skips a side the design does not hug', () {
      // The design declares 24px of top padding but its child starts
      // 100px down, so the frame is not hugging and the declaration and
      // the measurement are not describing the same distance. Comparing
      // them would fail an application that is correct.
      final results = _run(
        _spec([
          _design('card',
              type: FigmaElementType.container,
              rect: _rect(20, 100, 360, 200),
              layout: const FigmaLayout(
                direction: FigmaLayoutDirection.vertical,
                itemSpacing: 0,
                padding: FigmaEdgeInsets(top: 24),
              )),
          _design('only',
              type: FigmaElementType.text,
              rect: _rect(20, 200, 360, 100),
              parentNodeId: 'n:card'),
        ]),
        _snapshot([
          _node('card', type: 'Column', bounds: _rect(20, 100, 360, 200),
              children: [
                _node('only', type: 'Text', bounds: _rect(20, 200, 360, 100)),
              ]),
        ]),
      );

      final padding = _by(results, 'figma-padding');

      expect(padding.status, ValidationStatus.skip);
      expect(padding.message, contains('hug'));
    });
  });

  group('opacity', () {
    test('passes when the app reports the design opacity', () {
      final results = _run(
        _spec([
          _design('login.background',
              type: FigmaElementType.image,
              rect: _rect(0, 0, 400, 800),
              opacity: 0.2),
        ]),
        _snapshot([
          _node('login.background',
              type: 'Image',
              bounds: _rect(0, 0, 400, 800),
              properties: {'opacity': 0.2}),
        ]),
      );

      expect(_by(results, 'figma-opacity').status, ValidationStatus.pass);
    });

    test('fails when the app is more opaque than the design', () {
      final results = _run(
        _spec([
          _design('login.background',
              type: FigmaElementType.image,
              rect: _rect(0, 0, 400, 800),
              opacity: 0.2),
        ]),
        _snapshot([
          _node('login.background',
              type: 'Image',
              bounds: _rect(0, 0, 400, 800),
              properties: {'opacity': 1.0}),
        ]),
      );

      expect(_by(results, 'figma-opacity').status, ValidationStatus.fail);
    });

    test('skips when the app reported none', () {
      final results = _run(
        _spec([
          _design('login.background',
              type: FigmaElementType.image,
              rect: _rect(0, 0, 400, 800),
              opacity: 0.2),
        ]),
        _snapshot([
          _node('login.background',
              type: 'Image', bounds: _rect(0, 0, 400, 800)),
        ]),
      );

      final opacity = _by(results, 'figma-opacity');

      expect(opacity.status, ValidationStatus.skip);
      expect(opacity.message, contains('reported no opacity'));
    });

    test('is not compared at all when the design is fully opaque', () {
      // Every node is opaque unless it says otherwise. Emitting a
      // result for all of them would bury the ones that matter.
      final results = _run(
        _spec([
          _design('plain',
              type: FigmaElementType.shape, rect: _rect(0, 0, 10, 10)),
        ]),
        _snapshot([
          _node('plain', type: 'Container', bounds: _rect(0, 0, 10, 10)),
        ]),
      );

      expect(_allBy(results, 'figma-opacity'), isEmpty);
    });
  });

  group('corner radius', () {
    test('compares a radius the app reports', () {
      final results = _run(
        _spec([
          _design('login.button',
              type: FigmaElementType.shape,
              rect: _rect(40, 484, 322, 48),
              cornerRadius: 12),
        ]),
        _snapshot([
          _node('login.button',
              type: 'DecoratedBox',
              bounds: _rect(40, 484, 322, 48),
              properties: {'cornerRadius': 12.0}),
        ]),
      );

      expect(_by(results, 'figma-radius').status, ValidationStatus.pass);
    });

    test('fails on a different radius', () {
      final results = _run(
        _spec([
          _design('login.button',
              type: FigmaElementType.shape,
              rect: _rect(40, 484, 322, 48),
              cornerRadius: 12),
        ]),
        _snapshot([
          _node('login.button',
              type: 'DecoratedBox',
              bounds: _rect(40, 484, 322, 48),
              properties: {'cornerRadius': 4.0}),
        ]),
      );

      final radius = _by(results, 'figma-radius');

      expect(radius.status, ValidationStatus.fail);
      expect(radius.message, contains('12'));
      expect(radius.message, contains('4'));
    });

    test('skips, naming the fix, when the app reported none', () {
      final results = _run(
        _spec([
          _design('login.button',
              type: FigmaElementType.shape,
              rect: _rect(40, 484, 322, 48),
              cornerRadius: 12),
        ]),
        _snapshot([
          _node('login.button',
              type: 'Container', bounds: _rect(40, 484, 322, 48)),
        ]),
      );

      final radius = _by(results, 'figma-radius');

      expect(radius.status, ValidationStatus.skip);
      expect(radius.message, contains('corner radius'));
    });
  });

  group('non-text fill', () {
    test('compares a shape fill the app reports', () {
      final results = _run(
        _spec([
          _design('login.button',
              type: FigmaElementType.shape,
              rect: _rect(40, 484, 322, 48),
              fill: '#c2185bff'),
        ]),
        _snapshot([
          _node('login.button',
              type: 'DecoratedBox',
              bounds: _rect(40, 484, 322, 48),
              properties: {'fill': '#c2185bff'}),
        ]),
      );

      expect(_by(results, 'figma-colour').status, ValidationStatus.pass);
    });

    test('reads a container fill, not the colour of the text inside it', () {
      // Measured against the real application. The design node for the
      // Continue button is the 322x48 frame, filled near-white; the
      // Flutter node with that id contains a Text painted near-black.
      // Descending to the text reported the button as #1a1a1ae6 against
      // a design of #fffaf5ff - a 229-channel difference invented
      // entirely by the comparison.
      //
      // Which side to read is decided by the *design*: a TEXT node means
      // the colour of the glyphs, anything else means the fill behind
      // them.
      final results = _run(
        _spec([
          _design('login.continue_button',
              type: FigmaElementType.container,
              rect: _rect(40, 484, 322, 48),
              fill: '#fffaf5ff'),
        ]),
        _snapshot([
          _node('login.continue_button',
              type: 'AppButton',
              bounds: _rect(40, 484, 322, 48),
              properties: {'fill': '#fffaf5ff'},
              children: [
                UiNode(
                  type: 'Text',
                  text: 'Continue',
                  bounds: _rect(160, 499, 66, 18),
                  properties: const {'color': '#1a1a1ae6'},
                ),
              ]),
        ]),
      );

      final colour = _by(results, 'figma-colour');

      expect(
        colour.status,
        ValidationStatus.pass,
        reason: colour.message,
      );
    });

    test('still reads the text colour for a TEXT node', () {
      // The other side of the same rule, so the fix cannot be "always
      // use fill".
      final results = _run(
        _spec([
          _design('login.welcome_title',
              type: FigmaElementType.text,
              rect: _rect(40, 346, 322, 28),
              fill: '#353535ff'),
        ]),
        _snapshot([
          _node('login.welcome_title',
              type: 'Text',
              bounds: _rect(40, 346, 322, 28),
              properties: {'color': '#353535ff'}),
        ]),
      );

      expect(_by(results, 'figma-colour').status, ValidationStatus.pass);
    });

    test('fails on a different shape fill', () {
      final results = _run(
        _spec([
          _design('login.button',
              type: FigmaElementType.shape,
              rect: _rect(40, 484, 322, 48),
              fill: '#c2185bff'),
        ]),
        _snapshot([
          _node('login.button',
              type: 'DecoratedBox',
              bounds: _rect(40, 484, 322, 48),
              properties: {'fill': '#1a1a1aff'}),
        ]),
      );

      expect(_by(results, 'figma-colour').status, ValidationStatus.fail);
    });
  });

  group('coverage', () {
    test('states every denominator, so a pass cannot be read as total', () {
      final results = _run(
        _spec(
          [
            _design('a',
                type: FigmaElementType.text, rect: _rect(0, 0, 10, 10)),
            _design('b',
                type: FigmaElementType.text, rect: _rect(0, 20, 10, 10)),
            // Comparable, but no mapping binds it.
            FigmaElement(
              nodeId: 'n:unmapped',
              figmaName: 'Rectangle 91',
              type: FigmaElementType.shape,
              rect: _rect(0, 40, 10, 10),
            ),
          ],
          totalNodesWalked: 181,
        ),
        _snapshot([
          _node('a', type: 'Text', bounds: _rect(0, 0, 10, 10)),
          _node('b', type: 'Text', bounds: _rect(0, 20, 10, 10)),
        ]),
      );

      final coverage = _by(results, 'figma-coverage');

      expect(coverage.status, ValidationStatus.pass);
      expect(coverage.message, contains('181'));
      expect(coverage.message, contains('mapped elements only'));
    });

    test('reports the counts as machine-readable facts', () {
      final results = _run(
        _spec(
          [
            _design('a',
                type: FigmaElementType.text, rect: _rect(0, 0, 10, 10)),
            FigmaElement(
              nodeId: 'n:unmapped',
              figmaName: 'Rectangle 91',
              type: FigmaElementType.shape,
              rect: _rect(0, 40, 10, 10),
            ),
          ],
          totalNodesWalked: 181,
        ),
        _snapshot([
          _node('a', type: 'Text', bounds: _rect(0, 0, 10, 10)),
        ]),
      );

      final facts = _by(results, 'figma-coverage').facts;

      expect(facts['totalNodes'], 181);
      expect(facts['comparableNodes'], 2);
      expect(facts['mappedNodes'], 1);
      expect(facts['comparedNodes'], 1);
      expect(facts['unmappedNodes'], 1);
      expect(facts['verdictScope'], 'mapped elements only');
    });

    test('counts a node it could not compare as not compared', () {
      final results = _run(
        _spec(
          [
            _design('present',
                type: FigmaElementType.text, rect: _rect(0, 0, 10, 10)),
            _design('missing',
                type: FigmaElementType.text, rect: _rect(0, 20, 10, 10)),
          ],
          totalNodesWalked: 181,
        ),
        _snapshot([
          _node('present', type: 'Text', bounds: _rect(0, 0, 10, 10)),
        ]),
      );

      final facts = _by(results, 'figma-coverage').facts;

      expect(facts['mappedNodes'], 2);
      expect(facts['comparedNodes'], 1);
    });

    test('carries the pass, fail and error counts of the comparison', () {
      final results = _run(
        _spec(
          [
            _design('present',
                type: FigmaElementType.text, rect: _rect(0, 0, 10, 10)),
            _design('missing',
                type: FigmaElementType.text, rect: _rect(0, 20, 10, 10)),
          ],
          totalNodesWalked: 181,
        ),
        _snapshot([
          _node('present', type: 'Text', bounds: _rect(0, 0, 10, 10)),
        ]),
      );

      final facts = _by(results, 'figma-coverage').facts;

      expect(facts['failed'], 1);
      expect((facts['passed']! as int), greaterThan(0));
      expect(facts['errored'], 0);
    });
  });
}
