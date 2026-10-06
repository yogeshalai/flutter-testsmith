// DEF-E05-05 - `verify.element` was read once, racing the screen's render.
//
// Measured on a Samsung SM-M127G against an external application: the
// application reached /home and the login request answered 200, but the
// dashboard loads its own content after the route event, so `home.body`
// was not yet in the tree when verification read it once. The run
// reported AUTHENTICATED_STATE_NOT_REACHED on a session that was
// genuinely established - on BOTH the login path and the
// already-authenticated path, which is why no auth-file declaration
// could have fixed it.
//
// The fix is a presence wait on the canonical waiter. These tests pin
// the primitive: it returns as soon as the element appears, it respects
// its deadline, and it never sleeps blindly.
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

UiSnapshot _snapshot({required bool withBody}) => UiSnapshot(
      screenId: '/home',
      capturedAt: DateTime.utc(2026, 9, 16),
      devicePixelRatio: 1.875,
      root: UiNode(
        type: 'Scaffold',
        visible: true,
        bounds: const LogicalRect(x: 0, y: 0, width: 384, height: 805),
        children: [
          if (withBody)
            const UiNode(
              testId: 'home.body',
              type: 'Column',
              visible: true,
              bounds: LogicalRect(x: 0, y: 0, width: 384, height: 700),
            ),
        ],
      ),
    );

/// Renders the element only after [afterReads] captures, and counts them.
class _Screen {
  _Screen({this.afterReads = 0});

  final int afterReads;
  int reads = 0;

  Future<UiSnapshot> capture() async {
    final withBody = reads >= afterReads;
    reads++;
    return _snapshot(withBody: withBody);
  }
}

void main() {
  test('an element already present returns at once', () async {
    final screen = _Screen();
    final found = await const ElementWaiter(timeout: Duration(seconds: 5))
        .awaitPresent('home.body', screen.capture);

    expect(found, isTrue);
    expect(screen.reads, 1, reason: 'it waited when it did not need to');
  });

  test('an element that renders after the route event is still found',
      () async {
    // The real shape: /home arrives, the dashboard loads, home.body
    // appears a few captures later.
    final screen = _Screen(afterReads: 3);
    final found = await const ElementWaiter(
      timeout: Duration(seconds: 5),
      pollInterval: Duration(milliseconds: 1),
    ).awaitPresent('home.body', screen.capture);

    expect(found, isTrue);
    expect(screen.reads, greaterThan(1));
  });

  test('it returns the moment the element appears, not at the deadline',
      () async {
    final screen = _Screen(afterReads: 2);
    final watch = Stopwatch()..start();
    await const ElementWaiter(
      timeout: Duration(seconds: 30),
      pollInterval: Duration(milliseconds: 1),
    ).awaitPresent('home.body', screen.capture);
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'it waited out the timeout instead of returning early');
  });

  test('an element that never appears is reported absent, not thrown',
      () async {
    final screen = _Screen(afterReads: 1 << 30);
    final found = await const ElementWaiter(
      timeout: Duration(milliseconds: 40),
      pollInterval: Duration(milliseconds: 1),
    ).awaitPresent('home.body', screen.capture);

    expect(found, isFalse);
  });

  test('the configured timeout is respected, and bounded', () async {
    final screen = _Screen(afterReads: 1 << 30);
    final watch = Stopwatch()..start();
    await const ElementWaiter(
      timeout: Duration(milliseconds: 60),
      pollInterval: Duration(milliseconds: 1),
    ).awaitPresent('home.body', screen.capture);
    watch.stop();

    expect(watch.elapsed.inMilliseconds, greaterThanOrEqualTo(50));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'polling was unbounded');
  });

  test('presence is not tappability', () async {
    // A page body has area here, but the point of awaitPresent is that it
    // asks only whether the element is in the tree - pointWhenTappable is
    // the other question, and answering it would make a non-tappable
    // body fail a check about whether the screen rendered.
    final screen = _Screen();
    expect(
      await const ElementWaiter(timeout: Duration(seconds: 1))
          .awaitPresent('home.body', screen.capture),
      isTrue,
    );
    expect(
      await const ElementWaiter(
        timeout: Duration(milliseconds: 20),
        pollInterval: Duration(milliseconds: 1),
      ).awaitPresent('home.absent', screen.capture),
      isFalse,
    );
  });
}
