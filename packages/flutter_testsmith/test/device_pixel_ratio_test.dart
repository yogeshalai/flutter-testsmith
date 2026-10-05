import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  group('resolveDevicePixelRatio', () {
    test('prefers the implicit view', () {
      expect(
        resolveDevicePixelRatio(implicitViewRatio: 1.875, viewRatios: [3]),
        1.875,
      );
    });

    test('falls back to the first real view when there is no implicit one', () {
      // Multi-window and some embedder configurations have no implicit
      // view, and 1.0 is a plausible-looking wrong answer there.
      expect(
        resolveDevicePixelRatio(implicitViewRatio: null, viewRatios: [1.875]),
        1.875,
      );
    });

    test('ignores an implicit view reporting an unset ratio', () {
      // A view that exists but has not been sized yet reports 0. Treating
      // that as authoritative is how the first attempt at this went wrong.
      expect(
        resolveDevicePixelRatio(implicitViewRatio: 0, viewRatios: [1.875]),
        1.875,
      );
    });

    test('returns an invalid ratio rather than guessing when nothing is known',
        () {
      // 0 is rejected downstream by CoordinateSpace with a clear error.
      // Returning a plausible 1.0 instead would silently mis-place every
      // tap on any device that is not actually 1.0 - which is what
      // happened on the real device.
      expect(
        resolveDevicePixelRatio(implicitViewRatio: null, viewRatios: []),
        0,
      );
    });

    test('skips unsized views to find a sized one', () {
      expect(
        resolveDevicePixelRatio(
          implicitViewRatio: null,
          viewRatios: [0, 0, 2.75],
        ),
        2.75,
      );
    });
  });
}
