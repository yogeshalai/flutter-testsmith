// "Tap dispatched" is not "the action took effect".
//
// `pointFor` proved the target existed, had area, was visible and was
// inside the viewport - and then never asked whether the application
// would accept the tap at all. A control the application has explicitly
// disabled reports `enabled: false` in the very snapshot the point is
// computed from, and the tap was dispatched anyway: adb exited 0, the
// step reported success, and the run failed several steps later on an
// `expectScreen` that blamed a navigation for a button nobody could
// press.
//
// Actionability is a *precondition* of a meaningful tap, so it belongs
// here rather than in each flow's assertions. The rule is deliberately
// one-sided: only a target the application unambiguously reports as
// disabled is refused. Unknown stays unknown and is tapped, because a
// refusal built on a guess would fail correct flows.
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

const LogicalRect _button = LogicalRect(x: 100, y: 200, width: 120, height: 40);
const LogicalRect _screen = LogicalRect(x: 0, y: 0, width: 400, height: 800);

UiNode _node(
  String type, {
  String? testId,
  bool? enabled,
  bool visible = true,
  LogicalRect bounds = _button,
  List<UiNode> children = const [],
}) =>
    UiNode(
      testId: testId,
      type: type,
      enabled: enabled,
      visible: visible,
      bounds: bounds,
      children: children,
    );

UiSnapshot _snapshotOf(List<UiNode> children) => UiSnapshot(
      screenId: '/secure-login',
      capturedAt: DateTime.utc(2026, 9, 16),
      devicePixelRatio: 2,
      viewport: _screen,
      root: _node('Scaffold', bounds: _screen, children: children),
    );

/// One screen carrying a single target.
UiSnapshot _snapshot(UiNode target) => _snapshotOf([target]);

/// Serves a fresh snapshot per capture, and counts the captures.
class _Screen {
  _Screen(this._frames);

  final List<UiSnapshot> _frames;
  int reads = 0;

  Future<UiSnapshot> capture() async {
    final frame = _frames[reads < _frames.length ? reads : _frames.length - 1];
    reads++;
    return frame;
  }
}

void main() {
  group('a target the application has disabled is refused, not tapped', () {
    test('a disabled button is refused', () {
      final snapshot = _snapshot(
        _node('ElevatedButton', testId: 'login.continue', enabled: false),
      );

      expect(
        () => ElementLocator(snapshot).pointFor('login.continue'),
        throwsA(isA<ElementNotTappableException>()),
      );
    });

    test('the refusal says the application disabled it', () {
      final snapshot = _snapshot(
        _node('ElevatedButton', testId: 'login.continue', enabled: false),
      );

      expect(
        () => ElementLocator(snapshot).pointFor('login.continue'),
        throwsA(
          isA<ElementNotTappableException>().having(
            (e) => e.reason,
            'reason',
            contains('disabled'),
          ),
        ),
      );
    });

    test('the refusal names the element and its type', () {
      final snapshot = _snapshot(
        _node('ElevatedButton', testId: 'login.continue', enabled: false),
      );

      try {
        ElementLocator(snapshot).pointFor('login.continue');
        fail('a disabled target was tapped');
      } on ElementNotTappableException catch (error) {
        expect(error.testId, 'login.continue');
        expect('$error', contains('ElevatedButton'));
      }
    });
  });

  group('everything that is not a definite "disabled" is still tapped', () {
    test('an enabled button is tapped at its centre', () {
      final snapshot = _snapshot(
        _node('ElevatedButton', testId: 'login.continue', enabled: true),
      );

      // Centre (160, 220) logical, at a device pixel ratio of 2.
      expect(
        ElementLocator(snapshot).pointFor('login.continue'),
        const PhysicalPoint(320, 440),
      );
    });

    test('a widget with no notion of being enabled is tapped', () {
      // A Container reports null - "no such notion". Refusing that would
      // refuse most of the tappable surface of any application.
      final snapshot = _snapshot(_node('Container', testId: 'banner'));

      expect(ElementLocator(snapshot).pointFor('banner'), isNotNull);
    });

    test('descendants that disagree are not evidence of disabled', () {
      // Two interactive descendants, one of each. There is no single
      // answer, so there is nothing to refuse on - and guessing either
      // way would either block a working flow or claim a check that was
      // never made.
      final snapshot = _snapshot(
        _node('TestId', testId: 'row', children: [
          _node('InkWell', enabled: true),
          _node('IconButton', enabled: false),
        ]),
      );

      expect(ElementLocator(snapshot).pointFor('row'), isNotNull);
    });

    test('an invisible disabled descendant does not refuse the target', () {
      // A hidden node is not on screen, so it does not speak for the
      // subtree. Same rule the property reader already applies.
      final snapshot = _snapshot(
        _node('TestId', testId: 'cta', children: [
          _node('InkWell', enabled: true),
          _node(
            'IconButton',
            enabled: false,
            visible: false,
            bounds: const LogicalRect(x: 0, y: 0, width: 0, height: 0),
          ),
        ]),
      );

      expect(ElementLocator(snapshot).pointFor('cta'), isNotNull);
    });
  });

  group('the test id names a wrapper, which is the ordinary shape', () {
    test('a wrapper over a disabled button is refused', () {
      // `TestId(login.continue) > AppSizedBox > ElevatedButton`. The
      // wrapper carries no `enabled` of its own - no wrapper does - so
      // reading the node alone reported "no such notion" and tapped.
      final snapshot = _snapshot(
        _node('TestId', testId: 'login.continue', children: [
          _node('AppSizedBox', children: [
            _node('ElevatedButton', enabled: false),
          ]),
        ]),
      );

      expect(
        () => ElementLocator(snapshot).pointFor('login.continue'),
        throwsA(isA<ElementNotTappableException>()),
      );
    });

    test('a wrapper over an enabled button is tapped', () {
      final snapshot = _snapshot(
        _node('TestId', testId: 'login.continue', children: [
          _node('AppSizedBox', children: [
            _node('InkWell', enabled: true),
          ]),
        ]),
      );

      expect(ElementLocator(snapshot).pointFor('login.continue'), isNotNull);
    });

    test('the point is still the wrapper\'s centre, not the descendant\'s',
        () {
      // Resolution reads state from the subtree; it does not move the
      // tap. The wrapper is what the author named and what has the
      // bounds the author can see.
      final snapshot = _snapshot(
        _node('TestId', testId: 'cta', children: [
          _node(
            'InkWell',
            enabled: true,
            bounds: const LogicalRect(x: 110, y: 205, width: 10, height: 10),
          ),
        ]),
      );

      expect(
        ElementLocator(snapshot).pointFor('cta'),
        const PhysicalPoint(320, 440),
      );
    });
  });

  group('nothing outside the target\'s own subtree is consulted', () {
    test('a disabled sibling does not refuse the target', () {
      final snapshot = _snapshotOf([
        _node('TestId', testId: 'cta', children: [
          _node('InkWell', enabled: true),
        ]),
        _node('ElevatedButton', testId: 'other', enabled: false),
      ]);

      expect(ElementLocator(snapshot).pointFor('cta'), isNotNull);
    });

    test('a disabled ancestor does not refuse the target', () {
      final snapshot = _snapshot(
        _node('AbsorbPointer', testId: 'form', enabled: false, children: [
          _node('ElevatedButton', testId: 'inner', enabled: true),
        ]),
      );

      expect(ElementLocator(snapshot).pointFor('inner'), isNotNull);
    });
  });

  group('the existing refusals keep their own words', () {
    test('an absent element is still "not found", not "disabled"', () {
      final snapshot = _snapshot(
        _node('ElevatedButton', testId: 'present', enabled: false),
      );

      expect(
        () => ElementLocator(snapshot).pointFor('absent'),
        throwsA(isA<ElementNotFoundException>()),
      );
    });

    test('zero area is still reported as area, not as disabled', () {
      final snapshot = _snapshot(
        _node(
          'ElevatedButton',
          testId: 'collapsed',
          enabled: false,
          bounds: const LogicalRect(x: 0, y: 0, width: 0, height: 0),
        ),
      );

      expect(
        () => ElementLocator(snapshot).pointFor('collapsed'),
        throwsA(
          isA<ElementNotTappableException>().having(
            (e) => e.reason,
            'reason',
            contains('zero area'),
          ),
        ),
      );
    });

    test('not visible is still reported as visibility', () {
      final snapshot = _snapshot(
        _node(
          'ElevatedButton',
          testId: 'hidden',
          enabled: false,
          visible: false,
        ),
      );

      expect(
        () => ElementLocator(snapshot).pointFor('hidden'),
        throwsA(
          isA<ElementNotTappableException>().having(
            (e) => e.reason,
            'reason',
            contains('not visible'),
          ),
        ),
      );
    });
  });

  group('the waiter turns the gate into a bounded wait', () {
    test('a control that becomes enabled is waited for, then tapped',
        () async {
      // The ordinary shape of a form: the submit button enables once the
      // field validates. Without the gate this raced - the tap was
      // dispatched at whatever the button happened to be. With it, the
      // waiter polls the condition it already polls for layout.
      final screen = _Screen([
        _snapshot(_node('ElevatedButton', testId: 'submit', enabled: false)),
        _snapshot(_node('ElevatedButton', testId: 'submit', enabled: false)),
        _snapshot(_node('ElevatedButton', testId: 'submit', enabled: true)),
      ]);

      final point = await const ElementWaiter(
        timeout: Duration(seconds: 5),
        pollInterval: Duration(milliseconds: 1),
      ).pointWhenTappable('submit', screen.capture);

      expect(point, const PhysicalPoint(320, 440));
      expect(screen.reads, 3);
    });

    test('an enabled control is tapped on the first capture', () async {
      final screen = _Screen([
        _snapshot(_node('ElevatedButton', testId: 'submit', enabled: true)),
      ]);

      await const ElementWaiter(timeout: Duration(seconds: 5))
          .pointWhenTappable('submit', screen.capture);

      expect(screen.reads, 1, reason: 'it waited when it did not need to');
    });

    test('a control disabled throughout is refused, naming why', () async {
      final screen = _Screen([
        _snapshot(_node('ElevatedButton', testId: 'submit', enabled: false)),
      ]);

      await expectLater(
        const ElementWaiter(
          timeout: Duration(milliseconds: 40),
          pollInterval: Duration(milliseconds: 1),
        ).pointWhenTappable('submit', screen.capture),
        throwsA(
          isA<ElementNotTappableException>()
              .having((e) => e.testId, 'testId', 'submit')
              .having((e) => e.reason, 'reason', contains('disabled')),
        ),
      );
    });

    test('the wait is bounded by the declared timeout', () async {
      final screen = _Screen([
        _snapshot(_node('ElevatedButton', testId: 'submit', enabled: false)),
      ]);
      final watch = Stopwatch()..start();

      await const ElementWaiter(
        timeout: Duration(milliseconds: 60),
        pollInterval: Duration(milliseconds: 1),
      ).pointWhenTappable('submit', screen.capture).then<void>(
            (_) => fail('a disabled target was tapped'),
            onError: (Object _) {},
          );
      watch.stop();

      expect(watch.elapsed.inMilliseconds, greaterThanOrEqualTo(50));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'polling was unbounded');
    });
  });
}
