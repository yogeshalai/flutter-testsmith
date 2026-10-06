import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

/// A point in device physical pixels, as `adb shell input` expects.
@immutable
class PhysicalPoint {
  const PhysicalPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is PhysicalPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'PhysicalPoint($x, $y)';
}

/// The single place logical and physical pixels are converted.
///
/// Flutter reports geometry in logical pixels; `adb shell input` and
/// device screenshots use physical pixels. Doing this arithmetic ad hoc at
/// call sites is prohibited, because a missed conversion produces taps that
/// land somewhere plausible but wrong, and geometry assertions that fail for
/// no visible reason.
///
/// The development device has a ratio of 1.875, which makes any such
/// mistake immediately obvious rather than hiding behind a clean 2x.
/// See ADR-0006 and risk R3.
@immutable
class CoordinateSpace {
  CoordinateSpace({required this.devicePixelRatio}) {
    if (devicePixelRatio <= 0) {
      throw ArgumentError.value(
        devicePixelRatio,
        'devicePixelRatio',
        'Must be greater than zero; a zero ratio would collapse every '
            'coordinate onto the origin',
      );
    }
  }

  final double devicePixelRatio;

  int toPhysical(double logical) => (logical * devicePixelRatio).round();

  double toLogical(int physical) => physical / devicePixelRatio;

  /// The physical point at the centre of a logical rectangle - where a tap
  /// on that element should land.
  PhysicalPoint centreOf(LogicalRect rect) =>
      PhysicalPoint(toPhysical(rect.centreX), toPhysical(rect.centreY));
}
