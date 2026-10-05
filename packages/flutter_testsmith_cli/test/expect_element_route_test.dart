// `expectElement` said "on the screen" and measured "in the tree".
//
// Flutter keeps a covered route built, so after a dialog or a push the
// tree still holds the screen underneath. The assertion's own wording
// was already "is not on the screen" / "is on the screen and should not
// be", but `snapshot.find` is a depth-first search over the whole tree.
// Three consequences, all wrong in the same direction:
//
//   * `present: true` passed for an element nobody can see;
//   * `present: false` failed for an element that is genuinely gone from
//     the screen and merely still built;
//   * `enabled`/`text` were read off a screen the user navigated away
//     from - and because the covered route is pushed first, a plain
//     depth-first search returns the *covered* copy even when the top
//     route carries the same id.
//
// The subject of every `expectElement` is the element on the screen the
// user is looking at. These tests pin that.
import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/flow_executor.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const LogicalRect _box = LogicalRect(x: 0, y: 0, width: 120, height: 40);

UiNode _node(
  String type, {
  String? testId,
  int? routeIndex,
  bool? enabled,
  String? text,
  bool visible = true,
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: testId,
      type: type,
      enabled: enabled,
      text: text,
      visible: visible,
      bounds: visible ? _box : const LogicalRect(x: 0, y: 0, width: 0, height: 0),
      properties: {'routeIndex': ?routeIndex},
      children: children,
    );

UiSnapshot _snapshot(List<UiNode> children) => UiSnapshot(
      screenId: '/top',
      capturedAt: DateTime.utc(2026, 9, 16),
      devicePixelRatio: 2,
      root: _node('Scaffold', children: children),
    );

/// The home screen, with a dialog pushed over it.
UiSnapshot _withDialog() => _snapshot([
      _node('ElevatedButton',
          testId: 'home.open_cart', routeIndex: 1, enabled: true),
      _node('Text', testId: 'home.badge', routeIndex: 1, text: 'Cart (3)'),
      _node('AlertDialog', testId: 'dialog.confirm', routeIndex: 2),
    ]);

String? _problem(ExpectElementStep step, UiSnapshot snapshot) =>
    elementAssertionProblem(step, snapshot);

void main() {
  group('present: true means present on the screen', () {
    test('an element on the topmost route satisfies it', () {
      expect(
        _problem(
          const ExpectElementStep(elementId: 'dialog.confirm', present: true),
          _withDialog(),
        ),
        isNull,
      );
    });

    test('an element only on a covered route does not', () {
      expect(
        _problem(
          const ExpectElementStep(elementId: 'home.open_cart', present: true),
          _withDialog(),
        ),
        isNotNull,
      );
    });

    test('a bare assertion means present, and behaves the same way', () {
      // `expectElement: {id: x}` with no arguments asserts existence.
      expect(
        _problem(
          const ExpectElementStep(elementId: 'home.open_cart'),
          _withDialog(),
        ),
        isNotNull,
      );
    });

    test('the diagnostic says it is covered rather than missing', () {
      // "not on the screen" about an element plainly listed in the tree
      // sends a reader hunting for a typo. Naming the routes points at
      // the dialog that is actually in the way.
      final problem = _problem(
        const ExpectElementStep(elementId: 'home.open_cart', present: true),
        _withDialog(),
      );

      expect(problem, contains('route'));
      expect(problem, contains('1'));
      expect(problem, contains('2'));
    });
  });

  group('present: false means absent from the screen', () {
    test('an element that was navigated away from satisfies it', () {
      // The behaviour change with teeth: this used to fail, because the
      // covered screen is still built.
      expect(
        _problem(
          const ExpectElementStep(elementId: 'home.open_cart', present: false),
          _withDialog(),
        ),
        isNull,
      );
    });

    test('an element on the topmost route does not satisfy it', () {
      expect(
        _problem(
          const ExpectElementStep(elementId: 'dialog.confirm', present: false),
          _withDialog(),
        ),
        isNotNull,
      );
    });

    test('an element absent from the tree entirely satisfies it', () {
      expect(
        _problem(
          const ExpectElementStep(elementId: 'never.existed', present: false),
          _withDialog(),
        ),
        isNull,
      );
    });
  });

  group('state is read from the screen, never from underneath it', () {
    test('enabled is not read off a covered element', () {
      expect(
        _problem(
          const ExpectElementStep(elementId: 'home.open_cart', enabled: true),
          _withDialog(),
        ),
        isNotNull,
        reason: 'it is enabled, but on a screen the user cannot see',
      );
    });

    test('text is not read off a covered element', () {
      expect(
        _problem(
          const ExpectElementStep(elementId: 'home.badge', text: 'Cart (3)'),
          _withDialog(),
        ),
        isNotNull,
      );
    });

    test('a shared id resolves to the copy on screen, not the buried one', () {
      // Both routes carry `cta`. The covered route was pushed first, so
      // a depth-first search reaches it first and would assert about the
      // wrong one.
      final snapshot = _snapshot([
        _node('ElevatedButton',
            testId: 'cta', routeIndex: 1, enabled: false),
        _node('OutlinedButton',
            testId: 'cta', routeIndex: 2, enabled: true),
      ]);

      expect(
        _problem(
          const ExpectElementStep(elementId: 'cta', enabled: true),
          snapshot,
        ),
        isNull,
      );
    });
  });

  group('the listed ids are the ones a reader can actually see', () {
    test('a covered route\'s ids are not offered as alternatives', () {
      final problem = _problem(
        const ExpectElementStep(elementId: 'typo'),
        _withDialog(),
      );

      expect(problem, contains('dialog.confirm'));
      expect(problem, isNot(contains('home.open_cart')),
          reason: 'suggesting an id on a covered screen is a false lead');
    });
  });

  group('ambiguity is judged the same way the action resolver judges it', () {
    test('two candidates on the visible route are refused, not guessed', () {
      // Silently asserting about whichever copy a depth-first search
      // reached first is a verdict with no defensible basis.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 2, enabled: true),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2, enabled: false),
      ]);

      final problem = _problem(
        const ExpectElementStep(elementId: 'cta', enabled: true),
        snapshot,
      );

      expect(problem, isNotNull);
      expect(problem, contains('2'));
    });

    test('a copy on a covered route does not make the visible one '
        'ambiguous', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1, enabled: false),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2, enabled: true),
      ]);

      expect(
        _problem(
          const ExpectElementStep(elementId: 'cta', enabled: true),
          snapshot,
        ),
        isNull,
      );
    });

    test('present: false is not satisfied by an ambiguous screen', () {
      // Two of them are on screen; "absent" is plainly false.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 2),
        _node('OutlinedButton', testId: 'cta', routeIndex: 2),
      ]);

      expect(
        _problem(
          const ExpectElementStep(elementId: 'cta', present: false),
          snapshot,
        ),
        isNotNull,
      );
    });
  });

  group('a screen with one route behaves exactly as before', () {
    test('present passes', () {
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', routeIndex: 1, enabled: false),
      ]);

      expect(
        _problem(const ExpectElementStep(elementId: 'cta'), snapshot),
        isNull,
      );
      expect(
        _problem(
          const ExpectElementStep(elementId: 'cta', enabled: false),
          snapshot,
        ),
        isNull,
      );
    });

    test('a tree recording no routes at all behaves exactly as before', () {
      // The graceful fallback, again: an older SDK must not make every
      // assertion fail.
      final snapshot = _snapshot([
        _node('ElevatedButton', testId: 'cta', enabled: true),
      ]);

      expect(
        _problem(
          const ExpectElementStep(elementId: 'cta', enabled: true),
          snapshot,
        ),
        isNull,
      );
      expect(
        _problem(
          const ExpectElementStep(elementId: 'cta', present: false),
          snapshot,
        ),
        isNotNull,
      );
    });

    test('app chrome outside the navigator is on the screen', () {
      final snapshot = _snapshot([
        _node('IconButton', testId: 'app.menu', enabled: true),
        _node('AlertDialog', testId: 'dialog.confirm', routeIndex: 2),
      ]);

      expect(
        _problem(
          const ExpectElementStep(elementId: 'app.menu', enabled: true),
          snapshot,
        ),
        isNull,
      );
    });
  });
}
