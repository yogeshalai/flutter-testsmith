import 'package:flutter_testsmith/figma.dart';
import 'package:meta/meta.dart';

/// One axis of a box: where it starts, and how long it is.
@immutable
class AxisSpan {
  const AxisSpan({required this.start, required this.size});

  final double start;
  final double size;

  double get end => start + size;
  double get centre => start + size / 2;

  @override
  String toString() => '$start..$end ($size)';
}

/// What a projection could and could not say about one axis.
///
/// Position and size are answered separately, because a design routinely
/// determines one and not the other: a hugged button has a real
/// left-hand inset and a content-determined width, and refusing to
/// compare either because one is unknown would throw away a real check.
@immutable
class AxisProjection {
  const AxisProjection({
    this.positionLabel,
    this.expectedPosition,
    this.actualPosition,
    this.positionSkip,
    this.expectedSize,
    this.actualSize,
    this.sizeSkip,
  });

  /// What the compared position *is*: a leading inset, a trailing inset
  /// or an offset from the centre. Named so a failure message can say
  /// which distance disagrees rather than quoting a raw coordinate that
  /// means nothing on its own.
  final String? positionLabel;

  final double? expectedPosition;
  final double? actualPosition;

  /// Why the position was not compared. Null when it was.
  final String? positionSkip;

  final double? expectedSize;
  final double? actualSize;

  /// Why the size was not compared. Null when it was.
  final String? sizeSkip;

  bool get comparesPosition => expectedPosition != null;
  bool get comparesSize => expectedSize != null;
}

/// Projects a design axis onto a device axis using the anchor the design
/// declares.
///
/// The model in one sentence: **a design coordinate is not a scalable
/// quantity — it is an inset from an anchor, and a length is a length.**
///
/// The previous model multiplied every coordinate by
/// `viewportWidth / designWidth`. That is only correct if a design is a
/// picture to be resized, and a design is not: it is a layout. A 20px
/// gutter is 20px on a narrower screen, a 48px button is 48px tall, and
/// an element pinned 20px from the right edge stays 20px from the right
/// edge. Scaling them produces an error proportional to the distance
/// from the origin, which is exactly what the real device run showed —
/// 5.6px near the top of the screen and 63.6px at the bottom.
///
/// Figma states the anchor outright, so nothing here is inferred:
///
/// * for a child of an auto-layout frame, from the parent's
///   `primaryAxisAlignItems` / `counterAxisAlignItems` and the child's
///   `layoutAlign`,
/// * for an absolutely positioned child, from its own `constraints`.
///
/// Where the design states nothing usable, this returns a skip with a
/// reason. It never guesses, and it never falls back to scaling.
@immutable
class AnchorProjection {
  const AnchorProjection({
    this.designLeadingInset,
    this.deviceLeadingInset,
  });

  /// The safe-area inset the *design* assumes on this axis, when a
  /// screen declares one.
  ///
  /// Figma publishes no safe-area metadata: a frame is 874pt tall and
  /// says nothing about how much of that the designer intended as status
  /// bar. So this is declared per screen, or not at all — and when it is
  /// not, the comparison runs unadjusted and the report states the
  /// device's inset so a reader can see the cause of any offset.
  ///
  /// Inventing a value here would be worse than useless. There is no
  /// universal status-bar height, and a wrong constant would move every
  /// top-anchored element on every screen by the error.
  final double? designLeadingInset;

  /// The device's own inset on this axis, as the SDK reported it.
  final double? deviceLeadingInset;

  AxisProjection project({
    required FigmaAxisLayout layout,
    required AxisSpan design,
    required AxisSpan designReference,
    required AxisSpan device,
    required AxisSpan deviceReference,
  }) {
    // Content space: both sides measured from below their own inset,
    // when both are known. Applied to the reference rather than to the
    // element, because it shifts the origin every inset is measured
    // from.
    final designRef = _inset(designReference, designLeadingInset);
    final deviceRef = _inset(deviceReference, deviceLeadingInset);

    final size = _size(
      sizing: layout.sizing,
      design: design,
      designReference: designRef,
      deviceReference: deviceRef,
    );

    final position = _position(
      anchor: layout.anchor,
      design: design,
      designReference: designRef,
      device: device,
      deviceReference: deviceRef,
    );

    return AxisProjection(
      positionLabel: position.label,
      expectedPosition: position.expected,
      actualPosition: position.actual,
      positionSkip: position.skip,
      expectedSize: size.expected,
      actualSize: size.expected == null ? null : device.size,
      sizeSkip: size.skip,
    );
  }

  static AxisSpan _inset(AxisSpan span, double? leading) => leading == null
      ? span
      : AxisSpan(start: span.start + leading, size: span.size - leading);

  ({double? expected, String? skip}) _size({
    required FigmaSizing sizing,
    required AxisSpan design,
    required AxisSpan designReference,
    required AxisSpan deviceReference,
  }) {
    switch (sizing) {
      case FigmaSizing.fixed:
        // A length is a length.
        return (expected: design.size, skip: null);

      case FigmaSizing.hug:
        return (
          expected: null,
          skip: 'the design sizes this to its content, so its length is '
              'whatever the text engine produced rather than something '
              'the design specifies',
        );

      case FigmaSizing.fill:
        // The parent's extent, less this element's own insets - which
        // are lengths, and so do not change.
        final leading = design.start - designReference.start;
        final trailing = designReference.end - design.end;
        final expected = deviceReference.size - leading - trailing;
        if (expected <= 0) {
          return (
            expected: null,
            skip: 'the design does not fit this viewport: its insets of '
                '${_px(leading)} and ${_px(trailing)} already exceed the '
                '${_px(deviceReference.size)} available, so the design '
                'says nothing about what should be here',
          );
        }
        return (expected: expected, skip: null);

      case FigmaSizing.proportional:
        if (designReference.size <= 0) {
          return (expected: null, skip: 'the reference has no extent');
        }
        return (
          expected: design.size * (deviceReference.size / designReference.size),
          skip: null,
        );

      case FigmaSizing.unknown:
        // The ambiguity is only ever about how a length behaves *when
        // the frame resizes*. If it did not, the length is simply the
        // length, and skipping would throw away a real check for a
        // question nobody asked.
        if (_sameExtent(designReference, deviceReference)) {
          return (expected: design.size, skip: null);
        }
        return (
          expected: null,
          skip: 'the design does not say how this length behaves when the '
              'frame resizes, and this viewport is '
              '${_px(deviceReference.size)} against the frame of '
              '${_px(designReference.size)}',
        );
    }
  }

  ({String? label, double? expected, double? actual, String? skip}) _position({
    required FigmaAnchor anchor,
    required AxisSpan design,
    required AxisSpan designReference,
    required AxisSpan device,
    required AxisSpan deviceReference,
  }) {
    switch (anchor) {
      case FigmaAnchor.start:
      case FigmaAnchor.stretch:
        return (
          label: 'leading inset',
          expected: design.start - designReference.start,
          actual: device.start - deviceReference.start,
          skip: null,
        );

      case FigmaAnchor.end:
        return (
          label: 'trailing inset',
          expected: designReference.end - design.end,
          actual: deviceReference.end - device.end,
          skip: null,
        );

      case FigmaAnchor.centre:
        return (
          label: 'centre offset',
          expected: design.centre - designReference.centre,
          actual: device.centre - deviceReference.centre,
          skip: null,
        );

      case FigmaAnchor.proportional:
        if (designReference.size <= 0) {
          return (
            label: null,
            expected: null,
            actual: null,
            skip: 'the reference has no extent',
          );
        }
        final ratio = deviceReference.size / designReference.size;
        return (
          label: 'leading inset',
          expected: (design.start - designReference.start) * ratio,
          actual: device.start - deviceReference.start,
          skip: null,
        );

      case FigmaAnchor.unknown:
        // As with an unknown sizing: with no resize every anchor gives
        // the same answer, so there is nothing to be ambiguous about.
        if (_sameExtent(designReference, deviceReference)) {
          return (
            label: 'leading inset',
            expected: design.start - designReference.start,
            actual: device.start - deviceReference.start,
            skip: null,
          );
        }
        return (
          label: null,
          expected: null,
          actual: null,
          skip: 'the design does not say which edge this element is '
              'positioned from, and this viewport is '
              '${_px(deviceReference.size)} against the frame of '
              '${_px(designReference.size)}',
        );
    }
  }

  /// Whether the reference is the same length on both sides.
  ///
  /// Sub-pixel equality, because a viewport reported as
  /// 805.3333333333334 is the same extent as one computed as 805.33.
  static bool _sameExtent(AxisSpan a, AxisSpan b) =>
      (a.size - b.size).abs() < 0.5;

  static String _px(double value) => '${value.toStringAsFixed(1)}px';
}
