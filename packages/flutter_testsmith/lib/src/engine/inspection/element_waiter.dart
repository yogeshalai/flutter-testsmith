import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../device/coordinates.dart';
import 'element_locator.dart';

/// Waits for an element to become tappable, then says where to tap.
///
/// A single capture is not enough, and the reason showed up on real
/// hardware rather than in theory: on a cold start the element is in
/// the tree before it has been laid out, so its bounds are zero for a
/// moment. Capturing once and failing turns a slow launch into a test
/// failure, which is the worst kind - it fails on the machine that is
/// busiest and passes on the one running the retry.
///
/// Only the two expected conditions are polled through: the element is
/// absent, or it is present with no area. Anything else - a dead
/// transport, a crashed app - is raised at once, because retrying it
/// just delays the real error by the length of the timeout.
@immutable
class ElementWaiter {
  const ElementWaiter({
    this.timeout = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 200),
  });

  final Duration timeout;
  final Duration pollInterval;

  /// Captures until [testId] can be tapped, and returns the point.
  ///
  /// Rethrows the **last** reason rather than a generic timeout: "it
  /// has zero area" tells someone what to look at, and "timed out"
  /// sends them hunting.
  /// Captures until [testId] is in the tree, or the deadline passes.
  ///
  /// Presence only, deliberately: [pointWhenTappable] additionally
  /// requires an area to tap, which is right for a tap and wrong for a
  /// check that a screen rendered - a page body is not tappable and
  /// should not have to be.
  ///
  /// Returns a bool rather than throwing, because the caller decides
  /// what an absent element means. Bounded by [timeout] and polled at
  /// [pollInterval]: it returns the moment the element appears, so the
  /// timeout is an upper bound rather than a wait.
  Future<bool> awaitPresent(
    String testId,
    Future<UiSnapshot> Function() capture,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (ElementLocator(await capture()).contains(testId)) return true;
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<PhysicalPoint> pointWhenTappable(
    String testId,
    Future<UiSnapshot> Function() capture,
  ) async {
    final deadline = DateTime.now().add(timeout);
    Object lastFailure = ElementNotFoundException(
      testId: testId,
      available: const [],
    );

    while (true) {
      final snapshot = await capture();

      try {
        return ElementLocator(snapshot).pointFor(testId);
      } on ElementNotFoundException catch (error) {
        lastFailure = error;
      } on ElementNotTappableException catch (error) {
        lastFailure = error;
      }

      if (!DateTime.now().isBefore(deadline)) throw lastFailure;
      await Future<void>.delayed(pollInterval);
    }
  }
}
