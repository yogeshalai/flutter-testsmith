// The subtree search behind delivery verification.
//
// A test id names a wrapper far more often than it names the field: in
// a measured external login screen `TestId(login.mobile_field)` sits above
// `AppSizedBox`, which sits above the `TextField` that actually holds
// the text. Reading only the node the id names found nothing, so a
// credential's delivery was never actually verified.
import 'package:test/test.dart';
import 'package:flutter_testsmith/protocol.dart';

const LogicalRect _rect = LogicalRect(x: 0, y: 0, width: 100, height: 40);

UiNode _node(
  String type, {
  String? testId,
  String? text,
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: testId,
      type: type,
      text: text,
      visible: true,
      bounds: _rect,
      children: children,
    );

void main() {
  test('a node that itself bears the text is returned unchanged', () {
    final field = _node('TextField', testId: 'login.pin', text: 'abc');
    expect(field.nearestWhere((n) => n.text != null), same(field));
  });

  test('the measured shape: TestId -> AppSizedBox -> TextField', () {
    final tree = _node('TestId', testId: 'login.mobile_field', children: [
      _node('AppSizedBox', children: [
        _node('TextField', text: '9000000001'),
      ]),
    ]);

    final bearer = tree.nearestWhere((n) => n.text != null);
    expect(bearer?.text, '9000000001');
    expect(bearer?.type, 'TextField');
  });

  test('an obscured field under wrappers is reached', () {
    final tree = _node('TestId', testId: 'secure_login.pin_field', children: [
      _node('AppSizedBox', children: [
        _node('TextField', children: [
          _node('EditableText', text: '[REDACTED]:6'),
        ]),
      ]),
    ]);

    expect(tree.nearestWhere((n) => n.text != null)?.text, '[REDACTED]:6');
  });

  test('the nearest bearer wins, not the deepest', () {
    final tree = _node('TestId', testId: 'field', children: [
      _node('Wrapper', text: 'near', children: [
        _node('Inner', text: 'far'),
      ]),
    ]);

    expect(tree.nearestWhere((n) => n.text != null)?.text, 'near');
  });

  test('breadth-first: a shallow bearer beats a deeper one in an earlier '
      'branch', () {
    final tree = _node('TestId', testId: 'field', children: [
      _node('BranchA', children: [
        _node('Deep', text: 'deep'),
      ]),
      _node('BranchB', text: 'shallow'),
    ]);

    // BranchB is at depth 1; Deep is at depth 2. Depth decides, so the
    // answer does not depend on which branch was visited first.
    expect(tree.nearestWhere((n) => n.text != null)?.text, 'shallow');
  });

  test('nothing outside the subtree is reachable', () {
    final target = _node('TestId', testId: 'field', children: [
      _node('AppSizedBox'),
    ]);
    final sibling = _node('Other', testId: 'other', text: 'not mine');
    final screen = _node('Scaffold', children: [target, sibling]);

    // Searching from the target must not see the sibling's text, even
    // though both hang off the same screen.
    expect(target.nearestWhere((n) => n.text != null), isNull);
    expect(screen.nearestWhere((n) => n.text != null)?.text, 'not mine');
  });

  test('a subtree with no text at all reports nothing', () {
    final tree = _node('TestId', testId: 'field', children: [
      _node('AppSizedBox', children: [_node('DecoratedBox')]),
    ]);
    expect(tree.nearestWhere((n) => n.text != null), isNull);
  });

  test('an empty obscured field is a bearer, not an absence', () {
    final tree = _node('TestId', testId: 'field', children: [
      _node('TextField', text: ''),
    ]);
    expect(tree.nearestWhere((n) => n.text != null)?.text, '');
  });
}
