import 'package:meta/meta.dart';

/// Which edge of its parent an element's position is fixed to.
///
/// This is the heart of projecting a design onto a device. A design
/// coordinate is not a scalable quantity: `x = 329` does not mean "82% of
/// the way across", it means "20px in from the right", and those are the
/// same number only on the width the design was drawn at.
///
/// Figma states the anchor outright, in two different places depending on
/// how the parent lays out, and this enum is the union of both.
enum FigmaAnchor {
  /// Pinned to the leading edge: left, or top. A fixed leading inset.
  start('start'),

  /// Pinned to the trailing edge: right, or bottom. A fixed trailing
  /// inset.
  end('end'),

  /// Centred. The offset from the parent's centre is fixed.
  centre('centre'),

  /// Pinned to both edges, so both insets are fixed and the size gives.
  stretch('stretch'),

  /// Position and size are a proportion of the parent. Figma's `SCALE`.
  proportional('proportional'),

  /// The design does not say. Nothing is inferred from this; a
  /// comparison that needs it reports that it could not be made.
  unknown('unknown');

  const FigmaAnchor(this.wire);

  final String wire;

  static FigmaAnchor fromWire(Object? wire) {
    for (final anchor in values) {
      if (anchor.wire == wire) return anchor;
    }
    return FigmaAnchor.unknown;
  }
}

/// What determines an element's length on one axis.
enum FigmaSizing {
  /// A number the designer typed. A length, which does not scale.
  fixed('fixed'),

  /// Determined by the element's own content.
  ///
  /// Not a design length at all. Two text engines produce two different
  /// boxes from one string, so comparing a hugged dimension compares
  /// font metrics rather than layout.
  hug('hug'),

  /// Determined by the parent: the parent's extent less this element's
  /// insets.
  fill('fill'),

  /// A proportion of the parent. Figma's `SCALE` constraint.
  proportional('proportional'),

  /// The design does not say.
  unknown('unknown');

  const FigmaSizing(this.wire);

  final String wire;

  static FigmaSizing fromWire(Object? wire) {
    for (final sizing in values) {
      if (sizing.wire == wire) return sizing;
    }
    return FigmaSizing.unknown;
  }
}

/// How one element behaves on one axis when its parent resizes.
@immutable
class FigmaAxisLayout {
  const FigmaAxisLayout({required this.anchor, required this.sizing});

  static const FigmaAxisLayout unknown = FigmaAxisLayout(
    anchor: FigmaAnchor.unknown,
    sizing: FigmaSizing.unknown,
  );

  final FigmaAnchor anchor;
  final FigmaSizing sizing;

  Map<String, Object?> toJson() => {
        'anchor': anchor.wire,
        'sizing': sizing.wire,
      };

  factory FigmaAxisLayout.fromJson(Map<String, Object?> json) =>
      FigmaAxisLayout(
        anchor: FigmaAnchor.fromWire(json['anchor']),
        sizing: FigmaSizing.fromWire(json['sizing']),
      );

  @override
  bool operator ==(Object other) =>
      other is FigmaAxisLayout &&
      other.anchor == anchor &&
      other.sizing == sizing;

  @override
  int get hashCode => Object.hash(anchor, sizing);

  @override
  String toString() => '${anchor.wire}/${sizing.wire}';
}

/// Reads Figma's own resize semantics off a node and its parent.
///
/// Two mechanisms, because Figma has two:
///
/// * **Auto-layout.** A child of an auto-layout frame is positioned by
///   the parent's alignment, not by its own `constraints` - Figma leaves
///   those at their default and ignores them. The main axis comes from
///   `primaryAxisAlignItems`, the cross axis from the child's
///   `layoutAlign` or, failing that, the parent's
///   `counterAxisAlignItems`.
/// * **Absolute positioning.** A child of a plain frame is positioned by
///   its own `constraints`, which is then authoritative.
///
/// Getting this the wrong way round is the trap: every node in the real
/// Login frame reports `constraints: LEFT/TOP`, including the one the
/// designer pinned to the right-hand edge. Reading constraints there
/// would produce a confident, wrong answer.
abstract final class FigmaLayoutSemantics {
  /// The horizontal and vertical behaviour of [node] inside [parent].
  ///
  /// [parent] is null for the frame's own children, whose parent is the
  /// frame itself - passed as [frame].
  static ({FigmaAxisLayout horizontal, FigmaAxisLayout vertical}) of(
    Map<String, Object?> node,
    Map<String, Object?> parent,
  ) {
    final layoutMode = parent['layoutMode'];
    if (layoutMode == 'HORIZONTAL' || layoutMode == 'VERTICAL') {
      final horizontalIsMain = layoutMode == 'HORIZONTAL';
      final main = _mainAxis(node, parent);
      final cross = _crossAxis(node, parent);
      return (
        horizontal: horizontalIsMain ? main : cross,
        vertical: horizontalIsMain ? cross : main,
      );
    }

    return (
      horizontal: _fromConstraint(
        node,
        (node['constraints'] as Map?)?['horizontal'],
        const {
          'LEFT': FigmaAnchor.start,
          'RIGHT': FigmaAnchor.end,
          'CENTER': FigmaAnchor.centre,
          'LEFT_RIGHT': FigmaAnchor.stretch,
          'SCALE': FigmaAnchor.proportional,
        },
      ),
      vertical: _fromConstraint(
        node,
        (node['constraints'] as Map?)?['vertical'],
        const {
          'TOP': FigmaAnchor.start,
          'BOTTOM': FigmaAnchor.end,
          'CENTER': FigmaAnchor.centre,
          'TOP_BOTTOM': FigmaAnchor.stretch,
          'SCALE': FigmaAnchor.proportional,
        },
      ),
    );
  }

  /// The axis the parent stacks along.
  ///
  /// `SPACE_BETWEEN` is deliberately [FigmaAnchor.unknown]: where a child
  /// lands then depends on how many siblings there are and how wide each
  /// one turned out, which is not a property of the child.
  static FigmaAxisLayout _mainAxis(
    Map<String, Object?> node,
    Map<String, Object?> parent,
  ) {
    final anchor = switch (parent['primaryAxisAlignItems']) {
      'CENTER' => FigmaAnchor.centre,
      'MAX' => FigmaAnchor.end,
      'SPACE_BETWEEN' => FigmaAnchor.unknown,
      // Absent is Figma's MIN.
      _ => FigmaAnchor.start,
    };
    return FigmaAxisLayout(
      anchor: anchor,
      sizing: _sizing(node, main: true, parent: parent),
    );
  }

  static FigmaAxisLayout _crossAxis(
    Map<String, Object?> node,
    Map<String, Object?> parent,
  ) {
    // The child's own layoutAlign wins; INHERIT defers to the parent.
    final own = node['layoutAlign'];
    final anchor = switch (own) {
      'STRETCH' => FigmaAnchor.stretch,
      'MIN' => FigmaAnchor.start,
      'CENTER' => FigmaAnchor.centre,
      'MAX' => FigmaAnchor.end,
      _ => switch (parent['counterAxisAlignItems']) {
          'CENTER' => FigmaAnchor.centre,
          'MAX' => FigmaAnchor.end,
          // BASELINE aligns text baselines, which says nothing about the
          // box, so nothing is claimed about it.
          'BASELINE' => FigmaAnchor.unknown,
          _ => FigmaAnchor.start,
        },
    };
    return FigmaAxisLayout(
      anchor: anchor,
      sizing: _sizing(node, main: false, parent: parent),
    );
  }

  static FigmaSizing _sizing(
    Map<String, Object?> node, {
    required bool main,
    required Map<String, Object?> parent,
  }) {
    final horizontalIsMain = parent['layoutMode'] == 'HORIZONTAL';
    final key = (main == horizontalIsMain)
        ? 'layoutSizingHorizontal'
        : 'layoutSizingVertical';
    return switch (node[key]) {
      'FIXED' => FigmaSizing.fixed,
      'HUG' => FigmaSizing.hug,
      'FILL' => FigmaSizing.fill,
      // Older files predate layoutSizing. STRETCH and a non-zero
      // layoutGrow are the previous spellings of FILL.
      _ => node['layoutAlign'] == 'STRETCH' ||
              ((node['layoutGrow'] as num?) ?? 0) > 0
          ? FigmaSizing.fill
          : FigmaSizing.unknown,
    };
  }

  /// A constraint gives the anchor and the sizing together: pinning both
  /// edges stretches, `SCALE` is proportional, and anything else keeps
  /// the length the designer drew.
  static FigmaAxisLayout _fromConstraint(
    Map<String, Object?> node,
    Object? value,
    Map<String, FigmaAnchor> anchors,
  ) {
    final anchor = anchors[value];
    if (anchor == null) return FigmaAxisLayout.unknown;

    return FigmaAxisLayout(
      anchor: anchor,
      sizing: switch (anchor) {
        FigmaAnchor.stretch => FigmaSizing.fill,
        FigmaAnchor.proportional => FigmaSizing.proportional,
        _ => FigmaSizing.fixed,
      },
    );
  }
}
