import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

/// Maps a Figma frame's coordinate space onto the device's.
///
/// The two spaces never agree. A design is authored at one width - 402pt
/// in the frame this was built against - and the app runs at whatever
/// logical width the device reports. Comparing raw coordinates would
/// report every element on the screen as misplaced.
///
/// Scaling is **by width**, because that is how designs are actually
/// authored: a layout is drawn to a canvas width and is expected to
/// stretch vertically. Scaling by height instead would make a long
/// scrolling frame shrink every horizontal measurement.
@immutable
class DesignProjection {
  const DesignProjection._({
    required this.scale,
    required this.originDx,
    required this.originDy,
    required this.designAspect,
    required this.screenAspect,
  });

  factory DesignProjection.fitWidth({
    required double designWidth,
    required double designHeight,
    required double screenWidth,
    required double screenHeight,
    double originDx = 0,
    double originDy = 0,
  }) {
    void positive(double value, String name) {
      if (value <= 0 || !value.isFinite) {
        throw ArgumentError.value(value, name, 'must be a positive size');
      }
    }

    positive(designWidth, 'designWidth');
    positive(designHeight, 'designHeight');
    positive(screenWidth, 'screenWidth');
    positive(screenHeight, 'screenHeight');

    return DesignProjection._(
      scale: screenWidth / designWidth,
      originDx: originDx,
      originDy: originDy,
      designAspect: designHeight / designWidth,
      screenAspect: screenHeight / screenWidth,
    );
  }

  /// Device logical pixels per design pixel.
  final double scale;

  /// Shifts the projected origin, for a design drawn without the status
  /// bar and app chrome the device actually has.
  final double originDx;
  final double originDy;

  /// Height over width, for each space.
  final double designAspect;
  final double screenAspect;

  LogicalRect project(LogicalRect design) => LogicalRect(
        x: design.x * scale + originDx,
        y: design.y * scale + originDy,
        width: design.width * scale,
        height: design.height * scale,
      );

  /// How differently shaped the two spaces are, as a fraction.
  double get aspectDelta =>
      (screenAspect - designAspect).abs() / designAspect;

  /// Whether a vertical position may honestly be compared.
  ///
  /// A 402x1198 design frame against an 874pt viewport is not a
  /// misplaced layout, it is a scrolling page photographed whole. Width
  /// scaling cannot reconcile the two, so vertical checks are reported
  /// as skipped rather than failed - claiming a failure here would train
  /// people to widen tolerances until nothing is checked at all.
  bool verticalComparable(double threshold) => aspectDelta <= threshold;

  @override
  String toString() => 'DesignProjection(x${scale.toStringAsFixed(3)}, '
      'aspect delta ${(aspectDelta * 100).toStringAsFixed(1)}%)';
}
