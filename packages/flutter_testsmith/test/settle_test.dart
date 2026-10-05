import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  const quiet = Duration(milliseconds: 500);

  SettleState state({
    Duration sinceLastFrame = const Duration(seconds: 1),
    int inFlightRequests = 0,
    int transientCallbacks = 0,
  }) =>
      SettleState(
        sinceLastFrame: sinceLastFrame,
        inFlightRequests: inFlightRequests,
        transientCallbacks: transientCallbacks,
        quietPeriod: quiet,
      );

  group('SettleState', () {
    test('is settled when nothing is happening', () {
      expect(state().isSettled, isTrue);
      expect(state().blockers, isEmpty);
    });

    test('is unsettled while frames are still being produced', () {
      final s = state(sinceLastFrame: const Duration(milliseconds: 100));

      expect(s.isSettled, isFalse);
      expect(s.blockers.join(), contains('frames still rendering'));
    });

    test('is unsettled while a request is in flight', () {
      // A screen waiting on its data is not ready to be validated.
      final s = state(inFlightRequests: 1);

      expect(s.isSettled, isFalse);
      expect(s.blockers.join(), contains('1 request'));
    });

    test('is unsettled while an animation is running', () {
      // This is the case that produced a tree containing two screens.
      final s = state(transientCallbacks: 2);

      expect(s.isSettled, isFalse);
      expect(s.blockers.join(), contains('animation'));
    });

    test('names every blocker, not just the first', () {
      // A timeout that says only "not settled" sends the author
      // guessing; naming all of them usually shows the cause outright.
      final s = state(
        sinceLastFrame: const Duration(milliseconds: 10),
        inFlightRequests: 2,
        transientCallbacks: 1,
      );

      expect(s.blockers, hasLength(3));
    });

    test('round-trips through JSON for the RPC', () {
      final restored = SettleState.fromJson(
        state(inFlightRequests: 3).toJson(),
      );

      expect(restored.inFlightRequests, 3);
      expect(restored.isSettled, isFalse);
    });

    test('reads back the quiet period it was measured against', () {
      expect(SettleState.fromJson(state().toJson()).quietPeriod, quiet);
    });
  });
}
