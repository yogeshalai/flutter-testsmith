// `expectElement: {enabled: ...}` could not be written about a real app.
//
// The SDK derives `enabled` per widget type: a button knows, an
// `InkWell` knows, and everything else reports null - "no such notion".
// A `TestId` wrapper is one of the everything else, so on the ordinary
// shape `TestId > AppSizedBox > ElevatedButton` the assertion read the
// wrapper, got null, and failed against a button that was plainly
// enabled. The one property that could have expressed "the tap was
// refused because the control is disabled" was the one property the
// author could not assert.
//
// The platform already resolves a property that sits below the id -
// `readPropertyOf` does it for every validator, route-scoped, and
// reports disagreement as an ambiguity rather than guessing. The flow
// DSL's own assertion simply never used it.
import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/flow_executor.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const LogicalRect _box = LogicalRect(x: 0, y: 0, width: 120, height: 40);

UiNode _node(
  String type, {
  String? testId,
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
      children: children,
    );

UiSnapshot _snapshot(List<UiNode> children) => UiSnapshot(
      screenId: '/secure-login',
      capturedAt: DateTime.utc(2026, 9, 16),
      devicePixelRatio: 2,
      root: _node('Scaffold', children: children),
    );

/// The problem [step] reports on a screen holding [children], or null.
String? problemWith(ExpectElementStep step, List<UiNode> children) =>
    elementAssertionProblem(step, _snapshot(children));

void main() {
  group('enabled resolves through the wrapper the id actually names', () {
    test('a wrapper over a disabled button reports disabled', () {
      final problem = problemWith(
        const ExpectElementStep(elementId: 'login.continue', enabled: false),
        [
          _node('TestId', testId: 'login.continue', children: [
            _node('AppSizedBox', children: [
              _node('ElevatedButton', enabled: false),
            ]),
          ]),
        ],
      );

      expect(problem, isNull, reason: 'the button below the wrapper is '
          'disabled, which is exactly what was asserted');
    });

    test('a wrapper over an enabled button reports enabled', () {
      final problem = problemWith(
        const ExpectElementStep(elementId: 'login.continue', enabled: true),
        [
          _node('TestId', testId: 'login.continue', children: [
            _node('AppSizedBox', children: [
              _node('InkWell', enabled: true),
            ]),
          ]),
        ],
      );

      expect(problem, isNull);
    });

    test('a wrapper over a disabled button fails an enabled assertion', () {
      final problem = problemWith(
        const ExpectElementStep(elementId: 'login.continue', enabled: true),
        [
          _node('TestId', testId: 'login.continue', children: [
            _node('ElevatedButton', enabled: false),
          ]),
        ],
      );

      expect(problem, isNotNull);
      expect(problem, contains('false'));
    });
  });

  group('an id directly on the control keeps its existing behaviour', () {
    test('a disabled button satisfies enabled: false', () {
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'cta', enabled: false),
          [_node('ElevatedButton', testId: 'cta', enabled: false)],
        ),
        isNull,
      );
    });

    test('an enabled button fails enabled: false', () {
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'cta', enabled: false),
          [_node('ElevatedButton', testId: 'cta', enabled: true)],
        ),
        isNotNull,
      );
    });

    test('the node\'s own value wins over its descendants', () {
      // An explicit statement on the element the author named is the
      // author's answer, whatever sits underneath it.
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'cta', enabled: true),
          [
            _node('ElevatedButton', testId: 'cta', enabled: true, children: [
              _node('InkWell', enabled: false),
            ]),
          ],
        ),
        isNull,
      );
    });
  });

  group('a state that cannot be read is said, not guessed', () {
    test('descendants that disagree report the ambiguity', () {
      final problem = problemWith(
        const ExpectElementStep(elementId: 'row', enabled: true),
        [
          _node('TestId', testId: 'row', children: [
            _node('InkWell', enabled: true),
            _node('IconButton', enabled: false),
          ]),
        ],
      );

      expect(problem, isNotNull);
      expect(problem, contains('ambiguous'),
          reason: 'two descendants disagree, and a verdict either way '
              'would be a guess presented as a measurement');
    });

    test('a subtree with no notion of enabled says so', () {
      final problem = problemWith(
        const ExpectElementStep(elementId: 'banner', enabled: true),
        [
          _node('TestId', testId: 'banner', children: [_node('Container')]),
        ],
      );

      expect(problem, isNotNull);
      expect(problem, contains('banner'));
    });
  });

  group('nothing outside the target subtree is consulted', () {
    test('a disabled sibling does not answer for the target', () {
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'cta', enabled: true),
          [
            _node('TestId', testId: 'cta', children: [
              _node('InkWell', enabled: true),
            ]),
            _node('ElevatedButton', testId: 'other', enabled: false),
          ],
        ),
        isNull,
      );
    });
  });

  group('every other assertion is untouched', () {
    test('visible reads the named node alone', () {
      // Borrowing visibility from a child would be a different claim:
      // a hidden wrapper containing a visible child is still hidden.
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'cta', visible: false),
          [
            _node('TestId', testId: 'cta', visible: false, children: [
              _node('Text', text: 'Buy'),
            ]),
          ],
        ),
        isNull,
      );
    });

    test('present: false still means the element must be absent', () {
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'gone', present: false),
          [_node('Text', testId: 'here', text: 'hi')],
        ),
        isNull,
      );
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'here', present: false),
          [_node('Text', testId: 'here', text: 'hi')],
        ),
        isNotNull,
      );
    });

    test('an absent element still lists what is present', () {
      final problem = problemWith(
        const ExpectElementStep(elementId: 'absent'),
        [_node('Text', testId: 'here', text: 'hi')],
      );

      expect(problem, contains('absent'));
      expect(problem, contains('here'));
    });

    test('text still reads the named node alone', () {
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'label', text: 'Buy'),
          [_node('Text', testId: 'label', text: 'Buy')],
        ),
        isNull,
      );
    });

    test('textContains is unchanged', () {
      expect(
        problemWith(
          const ExpectElementStep(elementId: 'label', textContains: 'out of'),
          [_node('Text', testId: 'label', text: 'Sorry, out of stock')],
        ),
        isNull,
      );
    });
  });
}
