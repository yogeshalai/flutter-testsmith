import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'figma_client.dart';
import 'figma_spec.dart';
import 'layout_semantics.dart';
import 'node_mapping.dart';

/// Turns Figma's node JSON into a comparable specification.
///
/// Three things the real API makes necessary, none of which are obvious
/// from the documentation:
///
/// 1. `absoluteBoundingBox` is in **canvas** coordinates. The frame this
///    was built against sits at x = -118574, so everything is
///    re-expressed relative to the frame's own origin.
/// 2. Colours arrive as 0..1 floats, and a layer's `opacity` is separate
///    from the colour's alpha. Both are folded into one `#rrggbbaa`.
/// 3. Most nodes are vector paths inside icon groups. They are dropped,
///    or a frame of a dozen visible things reports two hundred elements.
class FigmaNormaliser {
  const FigmaNormaliser();

  /// Node types that never carry meaning worth comparing.
  static const Set<String> _skippedTypes = {'VECTOR', 'BOOLEAN_OPERATION'};

  FigmaScreenSpec normalise(
    Map<String, Object?> response, {
    required String nodeId,
    required String screen,
    FigmaNodeMapping? mapping,
  }) {
    final nodes = response['nodes'];
    if (nodes is! Map) {
      throw FigmaException(
        'Figma response has no "nodes". Got keys: ${response.keys.join(', ')}',
      );
    }
    final entry = nodes[nodeId];
    if (entry is! Map) {
      throw FigmaException(
        'Figma response does not contain node "$nodeId". '
        'It has: ${nodes.keys.join(', ')}',
      );
    }
    final rawDocument = entry['document'];
    if (rawDocument is! Map) {
      throw const FigmaException('Figma node has no document');
    }
    final document = rawDocument.cast<String, Object?>();

    final frame = _box(document);
    if (frame == null) {
      throw const FigmaException('Figma frame has no bounding box');
    }

    final elements = <FigmaElement>[];
    var walked = 0;

    // The nearest *kept* ancestor, not the raw parent. A node whose
    // parent was pruned as a vector would otherwise point at a node the
    // spec does not contain, and every hierarchy question about it would
    // answer "no ancestor" instead of the truth.
    //
    // [clip] is the innermost clipping ancestor's box, or null when
    // nothing above this node clips. It is *not* the frame by default:
    // clamping every box to the frame would invent a clip Figma does not
    // apply, and a design that deliberately bleeds past its frame would
    // be reported as though it did not.
    void visit(
      Map<String, Object?> node,
      Map<String, Object?> parent,
      String? keptParentId,
      LogicalRect? clip,
    ) {
      walked++;
      final type = '${node['type']}';

      var parentForChildren = keptParentId;

      if (!_skippedTypes.contains(type)) {
        final element = _element(node, parent, frame, mapping, keptParentId,
            clip);
        if (element != null) {
          elements.add(element);
          parentForChildren = element.nodeId;
        }
      }

      final clipForChildren =
          node['clipsContent'] == true ? (_box(node) ?? clip) : clip;

      // Descend even through skipped nodes: a group holding a vector
      // may also hold a label.
      for (final child in (node['children'] as List?) ?? const []) {
        if (child is Map) {
          visit(child.cast<String, Object?>(), node, parentForChildren,
              clipForChildren);
        }
      }
    }

    final frameClip = document['clipsContent'] == true ? frame : null;
    for (final child in (document['children'] as List?) ?? const []) {
      if (child is Map) {
        visit(child.cast<String, Object?>(), document, null, frameClip);
      }
    }

    final seen = {for (final e in elements) e.nodeId};
    final unmatched = [
      for (final id in (mapping?.entries.keys ?? const <String>[]))
        if (!seen.contains(id)) id,
    ]..sort();

    return FigmaScreenSpec(
      screen: screen,
      nodeId: nodeId,
      figmaName: '${document['name']}',
      width: frame.width,
      height: frame.height,
      clipsContent: document['clipsContent'] == true,
      elements: elements,
      totalNodesWalked: walked,
      unmatchedMappings: unmatched,
    );
  }

  FigmaElement? _element(
    Map<String, Object?> node,
    Map<String, Object?> parent,
    LogicalRect frame,
    FigmaNodeMapping? mapping,
    String? parentNodeId,
    LogicalRect? clip,
  ) {
    final box = _box(node);
    // No geometry, or laid out to nothing: not comparable against a
    // rendered screen.
    if (box == null || box.width <= 0 || box.height <= 0) return null;

    final visible = _intersect(box, clip);
    // Entirely outside the clip: on the canvas, but not on the screen.
    if (visible == null) return null;

    final wasClipped = visible.width != box.width || visible.height != box.height
        || visible.x != box.x || visible.y != box.y;

    final id = '${node['id']}';
    final characters = node['characters'] as String?;
    final semantics = FigmaLayoutSemantics.of(node, parent);

    LogicalRect relative(LogicalRect r) => LogicalRect(
          // Frame-relative. See the class comment.
          x: r.x - frame.x,
          y: r.y - frame.y,
          width: r.width,
          height: r.height,
        );

    return FigmaElement(
      nodeId: id,
      figmaName: '${node['name']}',
      parentNodeId: parentNodeId,
      semanticId: mapping?.semanticIdFor(id),
      type: _typeOf(node),
      horizontal: semantics.horizontal,
      vertical: semantics.vertical,
      unclippedRect: wasClipped ? relative(box) : null,
      rect: relative(visible),
      text: characters,
      typography: _typography(node),
      fill: _firstFill(node),
      cornerRadius: (node['cornerRadius'] as num?)?.toDouble(),
      opacity: (node['opacity'] as num?)?.toDouble() ?? 1,
      // Figma omits `visible` when the layer is visible, which is the
      // overwhelming majority of nodes.
      visible: node['visible'] as bool? ?? true,
      layout: _layout(node),
    );
  }

  /// Auto-layout spacing, for the frames that declare it.
  ///
  /// Returns null for everything else. A frame positioned absolutely
  /// makes no statement about spacing, and reporting zero for it would
  /// be indistinguishable from a frame that really does hug its
  /// children.
  static FigmaLayout? _layout(Map<String, Object?> node) {
    final direction = FigmaLayoutDirection.fromWire(node['layoutMode']);
    if (direction == null) return null;

    double side(String key) => (node[key] as num?)?.toDouble() ?? 0;

    return FigmaLayout(
      direction: direction,
      itemSpacing: side('itemSpacing'),
      padding: FigmaEdgeInsets(
        left: side('paddingLeft'),
        top: side('paddingTop'),
        right: side('paddingRight'),
        bottom: side('paddingBottom'),
      ),
    );
  }

  static FigmaElementType _typeOf(Map<String, Object?> node) {
    final type = '${node['type']}';
    if (type == 'TEXT') return FigmaElementType.text;
    if (type == 'INSTANCE' || type == 'COMPONENT') {
      return FigmaElementType.instance;
    }
    if (type == 'FRAME' || type == 'GROUP') return FigmaElementType.container;
    if (type == 'RECTANGLE') {
      // A rectangle filled with an image is an image; one filled with a
      // colour is a shape.
      final fills = (node['fills'] as List?) ?? const [];
      for (final fill in fills) {
        if (fill is Map && fill['type'] == 'IMAGE') {
          return FigmaElementType.image;
        }
      }
      return FigmaElementType.shape;
    }
    if (type == 'VECTOR') return FigmaElementType.vector;
    return FigmaElementType.shape;
  }

  /// The part of [box] inside [clip], or null when none of it is.
  static LogicalRect? _intersect(LogicalRect box, LogicalRect? clip) {
    if (clip == null) return box;
    final left = box.x > clip.x ? box.x : clip.x;
    final top = box.y > clip.y ? box.y : clip.y;
    final right = (box.x + box.width) < (clip.x + clip.width)
        ? box.x + box.width
        : clip.x + clip.width;
    final bottom = (box.y + box.height) < (clip.y + clip.height)
        ? box.y + box.height
        : clip.y + clip.height;
    if (right <= left || bottom <= top) return null;
    return LogicalRect(
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  static LogicalRect? _box(Map<String, Object?> node) {
    final raw = node['absoluteBoundingBox'];
    if (raw is! Map) return null;
    final box = raw.cast<String, Object?>();
    final x = box['x'];
    final y = box['y'];
    final width = box['width'];
    final height = box['height'];
    if (x is! num || y is! num || width is! num || height is! num) return null;
    return LogicalRect(
      x: x.toDouble(),
      y: y.toDouble(),
      width: width.toDouble(),
      height: height.toDouble(),
    );
  }

  static FigmaTypography? _typography(Map<String, Object?> node) {
    final raw = node['style'];
    if (raw is! Map) return null;
    final style = raw.cast<String, Object?>();
    final family = style['fontFamily'];
    final size = style['fontSize'];
    if (family is! String || size is! num) return null;

    return FigmaTypography(
      fontFamily: family,
      fontSize: size.toDouble(),
      fontWeight: (style['fontWeight'] as num?)?.toInt() ?? 400,
      lineHeight: (style['lineHeightPx'] as num?)?.toDouble(),
      letterSpacing: (style['letterSpacing'] as num?)?.toDouble(),
      textAlign: style['textAlignHorizontal'] as String?,
    );
  }

  /// The first visible solid fill, as `#rrggbbaa`.
  static String? _firstFill(Map<String, Object?> node) {
    for (final raw in (node['fills'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final fill = raw.cast<String, Object?>();
      if (fill['visible'] == false) continue;
      if (fill['type'] != 'SOLID') continue;

      final colour = (fill['color'] as Map?)?.cast<String, Object?>();
      if (colour == null) continue;

      // Layer opacity multiplies the colour's own alpha; reporting the
      // colour without it would describe something not on screen.
      final layerOpacity = (fill['opacity'] as num?)?.toDouble() ?? 1;
      final alpha = ((colour['a'] as num?)?.toDouble() ?? 1) * layerOpacity;

      return '#'
          '${_channel(colour['r'])}'
          '${_channel(colour['g'])}'
          '${_channel(colour['b'])}'
          '${_channel(alpha)}';
    }
    return null;
  }

  static String _channel(Object? value) {
    final fraction = (value as num?)?.toDouble() ?? 0;
    final byte = (fraction * 255).round().clamp(0, 255);
    return byte.toRadixString(16).padLeft(2, '0');
  }
}
