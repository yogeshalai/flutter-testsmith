import 'package:meta/meta.dart';

import 'json.dart';

/// A rectangle in Flutter **logical** pixels.
///
/// Logical is the only unit that crosses the wire. Converting to the
/// device's physical pixels is the engine's job, and must use the pixel
/// ratio from the same read that produced these bounds - see risk R3b.
@immutable
class LogicalRect {
  const LogicalRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  double get centreX => x + width / 2;
  double get centreY => y + height / 2;

  /// Whether the rectangle has no area.
  ///
  /// A widget laid out to zero size is present in the tree but cannot
  /// receive a tap. Treating it as tappable produces a silent no-op, so
  /// callers check this and report a useful error instead.
  bool get isEmpty => width <= 0 || height <= 0;

  Map<String, Object?> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  factory LogicalRect.fromJson(Map<String, Object?> json) => LogicalRect(
        x: json.requiredDouble('x'),
        y: json.requiredDouble('y'),
        width: json.requiredDouble('width'),
        height: json.requiredDouble('height'),
      );

  @override
  bool operator ==(Object other) =>
      other is LogicalRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() =>
      'LogicalRect($x, $y, ${width}x$height)';
}
