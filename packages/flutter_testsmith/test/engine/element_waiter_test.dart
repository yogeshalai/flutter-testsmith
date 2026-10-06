import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

UiSnapshot _snapshot(List<UiNode> children) => UiSnapshot(
      screenId: '/home',
      capturedAt: DateTime.utc(2026),
      devicePixelRatio: 2,
      viewport: const LogicalRect(x: 0, y: 0, width: 100, height: 200),
      root: UiNode(
        type: 'Root',
        bounds: const LogicalRect(x: 0, y: 0, width: 100, height: 200),
        children: children,
      ),
    );

UiNode _button({required bool laidOut}) => UiNode(
      testId: 'home.open_product',
      type: 'FilledButton',
      bounds: laidOut
          ? const LogicalRect(x: 10, y: 20, width: 80, height: 40)
          : const LogicalRect(x: 0, y: 0, width: 0, height: 0),
    );

void main() {
  const waiter = ElementWaiter(
    timeout: Duration(milliseconds: 600),
    pollInterval: Duration(milliseconds: 20),
  );

  test('taps immediately when the element is already laid out', () async {
    var captures = 0;

    final point = await waiter.pointWhenTappable(
      'home.open_product',
      () async {
        captures++;
        return _snapshot([_button(laidOut: true)]);
      },
    );

    expect(captures, 1);
    expect(point.x, 100); // centre 50 logical x 2
  });

  test('waits for an element that has not been laid out yet', () async {
    // The cold-start case: the tree has the button, but it has no area
    // because the first frame has not settled. Capturing once and
    // failing turns a slow launch into a test failure.
    var captures = 0;

    final point = await waiter.pointWhenTappable(
      'home.open_product',
      () async {
        captures++;
        return _snapshot([_button(laidOut: captures >= 3)]);
      },
    );

    expect(captures, 3);
    expect(point, isNotNull);
  });

  test('waits for an element that is not in the tree yet', () async {
    var captures = 0;

    await waiter.pointWhenTappable('home.open_product', () async {
      captures++;
      return captures >= 2
          ? _snapshot([_button(laidOut: true)])
          : _snapshot(const []);
    });

    expect(captures, 2);
  });

  test('gives up with the last real reason, not a generic timeout',
      () async {
    // "timed out" alone sends someone hunting. The reason the element
    // could not be tapped on the final attempt is the useful part.
    await expectLater(
      waiter.pointWhenTappable(
        'home.open_product',
        () async => _snapshot([_button(laidOut: false)]),
      ),
      throwsA(
        isA<ElementNotTappableException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('zero area'), contains('home.open_product')),
        ),
      ),
    );
  });

  test('reports an element that never appeared as not found', () async {
    await expectLater(
      waiter.pointWhenTappable(
        'home.missing',
        () async => _snapshot([_button(laidOut: true)]),
      ),
      throwsA(isA<ElementNotFoundException>()),
    );
  });

  test('does not swallow an unexpected failure', () async {
    // A transport error is not something to poll through.
    await expectLater(
      waiter.pointWhenTappable(
        'home.open_product',
        () async => throw StateError('the app went away'),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
