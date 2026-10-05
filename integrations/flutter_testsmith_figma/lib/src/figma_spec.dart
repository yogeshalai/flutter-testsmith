import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'layout_semantics.dart';

/// The kinds of Figma node worth comparing against a Flutter screen.
enum FigmaElementType {
  text('TEXT'),
  image('IMAGE'),
  shape('SHAPE'),
  container('CONTAINER'),
  instance('INSTANCE'),
  vector('VECTOR');

  const FigmaElementType(this.wire);

  final String wire;

  static FigmaElementType fromWire(String wire) => values.firstWhere(
        (t) => t.wire == wire,
        orElse: () => FigmaElementType.shape,
      );
}

/// Type, size and weight of a text node.
@immutable
class FigmaTypography {
  const FigmaTypography({
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    this.lineHeight,
    this.letterSpacing,
    this.textAlign,
  });

  final String fontFamily;
  final double fontSize;
  final int fontWeight;
  final double? lineHeight;
  final double? letterSpacing;
  final String? textAlign;

  Map<String, Object?> toJson() => {
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'fontWeight': fontWeight,
        if (lineHeight != null) 'lineHeight': lineHeight,
        if (letterSpacing != null) 'letterSpacing': letterSpacing,
        if (textAlign != null) 'textAlign': textAlign,
      };

  factory FigmaTypography.fromJson(Map<String, Object?> json) =>
      FigmaTypography(
        fontFamily: json.required<String>('fontFamily'),
        fontSize: json.required<num>('fontSize').toDouble(),
        fontWeight: json.required<num>('fontWeight').toInt(),
        lineHeight: json.optional<num>('lineHeight')?.toDouble(),
        letterSpacing: json.optional<num>('letterSpacing')?.toDouble(),
        textAlign: json.optional<String>('textAlign'),
      );

  @override
  String toString() => '$fontFamily ${fontSize}px w$fontWeight';
}


/// Which way an auto-layout frame stacks its children.
enum FigmaLayoutDirection {
  horizontal('HORIZONTAL'),
  vertical('VERTICAL');

  const FigmaLayoutDirection(this.wire);

  final String wire;

  static FigmaLayoutDirection? fromWire(Object? wire) {
    for (final direction in values) {
      if (direction.wire == wire) return direction;
    }
    return null;
  }
}

/// Padding, in the design's own logical pixels.
@immutable
class FigmaEdgeInsets {
  const FigmaEdgeInsets({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  static const FigmaEdgeInsets zero = FigmaEdgeInsets();

  final double left;
  final double top;
  final double right;
  final double bottom;

  bool get isZero => left == 0 && top == 0 && right == 0 && bottom == 0;

  Map<String, Object?> toJson() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };

  factory FigmaEdgeInsets.fromJson(Map<String, Object?> json) =>
      FigmaEdgeInsets(
        left: json.optional<num>('left')?.toDouble() ?? 0,
        top: json.optional<num>('top')?.toDouble() ?? 0,
        right: json.optional<num>('right')?.toDouble() ?? 0,
        bottom: json.optional<num>('bottom')?.toDouble() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is FigmaEdgeInsets &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'l$left t$top r$right b$bottom';
}

/// What an auto-layout frame declares about its own spacing.
///
/// Only auto-layout frames carry this. A frame laid out by absolute
/// position says nothing about spacing, and inventing a number for it
/// would be guessing.
@immutable
class FigmaLayout {
  const FigmaLayout({
    required this.direction,
    required this.itemSpacing,
    this.padding = FigmaEdgeInsets.zero,
  });

  final FigmaLayoutDirection direction;

  /// The gap Figma puts between adjacent children.
  final double itemSpacing;

  final FigmaEdgeInsets padding;

  Map<String, Object?> toJson() => {
        'direction': direction.wire,
        'itemSpacing': itemSpacing,
        if (!padding.isZero) 'padding': padding.toJson(),
      };

  factory FigmaLayout.fromJson(Map<String, Object?> json) {
    final padding = json.optionalMap('padding');
    return FigmaLayout(
      direction: FigmaLayoutDirection.fromWire(json['direction']) ??
          FigmaLayoutDirection.vertical,
      itemSpacing: json.optional<num>('itemSpacing')?.toDouble() ?? 0,
      padding: padding == null
          ? FigmaEdgeInsets.zero
          : FigmaEdgeInsets.fromJson(padding),
    );
  }

  @override
  String toString() =>
      '${direction.wire} gap $itemSpacing${padding.isZero ? '' : ' pad $padding'}';
}

/// One element of a design, normalised.
@immutable
class FigmaElement {
  const FigmaElement({
    required this.nodeId,
    required this.figmaName,
    required this.type,
    required this.rect,
    this.parentNodeId,
    this.semanticId,
    this.text,
    this.typography,
    this.fill,
    this.cornerRadius,
    this.opacity = 1,
    this.visible = true,
    this.layout,
    this.horizontal = FigmaAxisLayout.unknown,
    this.vertical = FigmaAxisLayout.unknown,
    this.unclippedRect,
  });

  /// The Figma node id. Stable across renames, unlike the layer name.
  final String nodeId;

  /// The layer name, kept as a hint for a human writing a mapping.
  ///
  /// Not usable as an identifier: real files are full of
  /// `Frame 42980` and `Rectangle 91`.
  final String figmaName;

  /// The node this one sits inside, or null for a direct child of the
  /// frame.
  ///
  /// The hierarchy is stored as an adjacency list rather than as nested
  /// children: the spec is written to disk and read back by the engine,
  /// and a flat list with parent pointers serialises without duplicating
  /// the tree. [FigmaScreenSpec.childrenOf] reconstructs it.
  final String? parentNodeId;

  /// Assigned by the mapping file, never inferred from [figmaName].
  final String? semanticId;

  final FigmaElementType type;

  /// Frame-relative, in Figma's own logical pixels.
  final LogicalRect rect;

  final String? text;
  final FigmaTypography? typography;

  /// `#rrggbbaa`, with any layer opacity already folded into the alpha.
  final String? fill;

  final double? cornerRadius;

  /// The node's own opacity, 0..1.
  ///
  /// Separate from [fill]: Figma's node opacity and a fill entry's own
  /// opacity are different things, and so are Flutter's `Opacity` widget
  /// and a decoration colour. Folding either into the other would report
  /// a value that is on neither side.
  final double opacity;

  /// Figma's `visible`. A hidden layer is carried rather than dropped,
  /// so a design that hides something can say so.
  final bool visible;

  /// Auto-layout spacing, when this node is an auto-layout frame.
  final FigmaLayout? layout;

  /// How this element behaves horizontally when its parent resizes.
  final FigmaAxisLayout horizontal;

  /// How this element behaves vertically when its parent resizes.
  final FigmaAxisLayout vertical;

  /// The box before a clipping ancestor cut it down, when one did.
  ///
  /// Null when nothing was clipped. Kept so a report can say that the
  /// design overflows rather than silently comparing against a box the
  /// designer never drew.
  final LogicalRect? unclippedRect;

  Map<String, Object?> toJson() => {
        'nodeId': nodeId,
        'figmaName': figmaName,
        if (parentNodeId != null) 'parentNodeId': parentNodeId,
        if (semanticId != null) 'semanticId': semanticId,
        'type': type.wire,
        'rect': rect.toJson(),
        if (text != null) 'text': text,
        if (typography != null) 'typography': typography!.toJson(),
        if (fill != null) 'fill': fill,
        if (cornerRadius != null) 'cornerRadius': cornerRadius,
        if (opacity != 1) 'opacity': opacity,
        if (!visible) 'visible': visible,
        if (layout != null) 'layout': layout!.toJson(),
        'horizontal': horizontal.toJson(),
        'vertical': vertical.toJson(),
        if (unclippedRect != null) 'unclippedRect': unclippedRect!.toJson(),
      };

  factory FigmaElement.fromJson(Map<String, Object?> json) {
    final typography = json.optionalMap('typography');
    final layout = json.optionalMap('layout');
    final horizontal = json.optionalMap('horizontal');
    final vertical = json.optionalMap('vertical');
    final unclipped = json.optionalMap('unclippedRect');

    return FigmaElement(
      nodeId: json.required<String>('nodeId'),
      figmaName: json.required<String>('figmaName'),
      parentNodeId: json.optional<String>('parentNodeId'),
      semanticId: json.optional<String>('semanticId'),
      type: FigmaElementType.fromWire(json.required<String>('type')),
      rect: _rect(json.requiredMap('rect'), 'rect'),
      text: json.optional<String>('text'),
      typography:
          typography == null ? null : FigmaTypography.fromJson(typography),
      fill: json.optional<String>('fill'),
      cornerRadius: json.optional<num>('cornerRadius')?.toDouble(),
      opacity: json.optional<num>('opacity')?.toDouble() ?? 1,
      visible: json.optional<bool>('visible') ?? true,
      layout: layout == null ? null : FigmaLayout.fromJson(layout),
      horizontal: horizontal == null
          ? FigmaAxisLayout.unknown
          : FigmaAxisLayout.fromJson(horizontal),
      vertical: vertical == null
          ? FigmaAxisLayout.unknown
          : FigmaAxisLayout.fromJson(vertical),
      unclippedRect:
          unclipped == null ? null : _rect(unclipped, 'unclippedRect'),
    );
  }

  @override
  String toString() =>
      'FigmaElement($figmaName${semanticId == null ? '' : ' #$semanticId'}, '
      '${type.wire}, $rect)';
}

/// How much of a design a comparison can actually speak about.
///
/// This exists because "8 of 8 checks passed" is a true sentence that
/// invites a false conclusion. A frame holds hundreds of nodes; a
/// mapping binds a handful; the verdict covers the handful. Making the
/// denominators explicit is the difference between a report that informs
/// and one that reassures.
@immutable
class FigmaCoverage {
  const FigmaCoverage({
    required this.totalNodes,
    required this.comparableNodes,
    required this.mappedNodes,
  });

  /// Every node inside the frame.
  ///
  /// The frame itself is excluded: it is the screen, not an element on
  /// it.
  final int totalNodes;

  /// Nodes that survived normalisation - they have geometry and are not
  /// vector paths. Only these could ever be compared.
  final int comparableNodes;

  /// Comparable nodes a mapping bound to a semantic id. Only these are
  /// compared.
  final int mappedNodes;

  /// Nodes normalisation dropped: vector paths inside icon groups, and
  /// nodes laid out to nothing. Never comparable, by construction.
  int get decorativeNodes => totalNodes - comparableNodes;

  /// Comparable nodes no mapping names. Not compared, and not a defect -
  /// but not covered either.
  int get unmappedNodes => comparableNodes - mappedNodes;

  /// Mapped as a fraction of what could be mapped, 0..1.
  double get mappedFraction =>
      comparableNodes == 0 ? 0 : mappedNodes / comparableNodes;

  Map<String, Object?> toJson() => {
        'totalNodes': totalNodes,
        'comparableNodes': comparableNodes,
        'decorativeNodes': decorativeNodes,
        'mappedNodes': mappedNodes,
        'unmappedNodes': unmappedNodes,
        'mappedFraction': double.parse(mappedFraction.toStringAsFixed(4)),
      };

  factory FigmaCoverage.fromJson(Map<String, Object?> json) => FigmaCoverage(
        totalNodes: json.optional<num>('totalNodes')?.toInt() ?? 0,
        comparableNodes: json.optional<num>('comparableNodes')?.toInt() ?? 0,
        mappedNodes: json.optional<num>('mappedNodes')?.toInt() ?? 0,
      );

  @override
  String toString() => '$mappedNodes mapped of $comparableNodes comparable '
      '($totalNodes nodes in the frame)';
}

/// A design frame, normalised into something comparable with a screen.
class FigmaScreenSpec {
  FigmaScreenSpec({
    required this.screen,
    required this.nodeId,
    required this.figmaName,
    required this.width,
    required this.height,
    required this.elements,
    this.totalNodesWalked = 0,
    this.unmatchedMappings = const [],
    this.clipsContent = false,
  });

  /// The application screen this design describes.
  final String screen;

  final String nodeId;
  final String figmaName;
  final double width;
  final double height;

  /// Whether the frame clips what overflows it.
  ///
  /// Figma's own `clipsContent`. Only when this is true is an
  /// overflowing element actually invisible past the frame edge, so only
  /// then is clipping the right thing to compare against.
  final bool clipsContent;

  final List<FigmaElement> elements;

  /// How many nodes the walk saw before filtering.
  final int totalNodesWalked;

  /// Mapped node ids that are not in this frame.
  ///
  /// Surfaced rather than ignored: a mapping pointing at a deleted layer
  /// is a stale file, and silence would let it rot.
  final List<String> unmatchedMappings;

  /// Every element, indexed by node id. Built once; the spec is
  /// immutable and a comparison asks for ancestry many times.
  late final Map<String, FigmaElement> _byNodeId = {
    for (final element in elements) element.nodeId: element,
  };

  late final Map<String, List<FigmaElement>> _childrenByParent = () {
    final map = <String, List<FigmaElement>>{};
    for (final element in elements) {
      final parent = element.parentNodeId;
      if (parent == null) continue;
      (map[parent] ??= <FigmaElement>[]).add(element);
    }
    return map;
  }();

  FigmaElement? byNodeId(String nodeId) => _byNodeId[nodeId];

  /// What fraction of this design a comparison can speak about.
  late final FigmaCoverage coverage = FigmaCoverage(
    totalNodes: totalNodesWalked,
    comparableNodes: elements.length,
    mappedNodes: mapped.length,
  );

  /// The elements directly inside [nodeId], in the design's own order.
  ///
  /// Only elements the normaliser kept: a node whose every child was a
  /// pruned vector path reports none.
  List<FigmaElement> childrenOf(String nodeId) =>
      List.unmodifiable(_childrenByParent[nodeId] ?? const <FigmaElement>[]);

  /// The chain of enclosing elements, nearest first.
  ///
  /// Stops at the frame, which is not itself an element.
  List<FigmaElement> ancestryOf(String nodeId) {
    final chain = <FigmaElement>[];
    // A malformed spec could in principle describe a cycle. Bounding the
    // walk by the element count makes that a truncated answer rather
    // than a hung run.
    var current = _byNodeId[nodeId]?.parentNodeId;
    while (current != null && chain.length <= elements.length) {
      final parent = _byNodeId[current];
      if (parent == null) break;
      chain.add(parent);
      current = parent.parentNodeId;
    }
    return chain;
  }

  /// Whether [ancestor] encloses [descendant] in the design.
  ///
  /// A node is not its own ancestor, and siblings are not ancestors of
  /// one another.
  bool isAncestor({required String ancestor, required String descendant}) {
    for (final element in ancestryOf(descendant)) {
      if (element.nodeId == ancestor) return true;
    }
    return false;
  }

  FigmaElement? bySemanticId(String id) {
    for (final element in elements) {
      if (element.semanticId == id) return element;
    }
    return null;
  }

  FigmaElement? byFigmaName(String name) {
    for (final element in elements) {
      if (element.figmaName == name) return element;
    }
    return null;
  }

  /// Elements a mapping has given a semantic id, which are the only ones
  /// structural comparison can speak about.
  List<FigmaElement> get mapped =>
      [for (final e in elements) if (e.semanticId != null) e];

  Map<String, Object?> toJson() => {
        'screen': screen,
        'nodeId': nodeId,
        'figmaName': figmaName,
        'width': width,
        'height': height,
        'totalNodesWalked': totalNodesWalked,
        if (clipsContent) 'clipsContent': clipsContent,
        if (unmatchedMappings.isNotEmpty)
          'unmatchedMappings': unmatchedMappings,
        'elements': [for (final e in elements) e.toJson()],
      };

  factory FigmaScreenSpec.fromJson(Map<String, Object?> json) {
    final unmatched = json.optionalList('unmatchedMappings');

    return FigmaScreenSpec(
      screen: json.required<String>('screen'),
      nodeId: json.required<String>('nodeId'),
      figmaName: json.required<String>('figmaName'),
      width: json.required<num>('width').toDouble(),
      height: json.required<num>('height').toDouble(),
      totalNodesWalked: json.optional<num>('totalNodesWalked')?.toInt() ?? 0,
      clipsContent: json.optional<bool>('clipsContent') ?? false,
      unmatchedMappings: unmatched == null
          ? const []
          : _strings(unmatched, 'unmatchedMappings'),
      elements: [
        for (final (index, raw) in json.requiredList('elements').indexed)
          _element(raw, index),
      ],
    );
  }

  @override
  String toString() =>
      'FigmaScreenSpec($figmaName, ${elements.length} of $totalNodesWalked '
      'nodes, ${mapped.length} mapped)';
}

/// Field readers that fail with the field's name rather than a cast error.
///
/// A spec on disk is a *project* file. `testsmith figma pull` writes it,
/// but it is also hand-authored - the example application's Checkout
/// spec is one - edited, and left behind by older versions of this tool.
/// The CLI's `loadFigmaSpecs` already says what happens to one that will
/// not read: report it and skip it, because a file describing no screen
/// takes nothing away from another. It catches `FormatException` to do
/// that, which is what `jsonDecode` raises.
///
/// Reading the schema with `!` and `as` raised a `TypeError` instead,
/// which is not a `FormatException` and not an `Exception` at all, so
/// `{"a": 1}` in `<app>/figma` ended `run`, `suite run` and `preflight`
/// with an unhandled exception and exit 255.
///
/// The shape is `flutter_testsmith_protocol`'s `JsonMapReader`, which
/// answers the same question for the wire format, and every other parser
/// in this package already raises `FormatException`. It is copied rather
/// than shared because that one is deliberately not exported and raises
/// the protocol's own exception; what a reader of a *project* file must
/// throw is the type its loader already catches.
extension _SpecJson on Map<String, Object?> {
  /// [field], or a [FormatException] naming it.
  ///
  /// An explicit null reads as absent. `toJson` never writes one, so a
  /// null here is a hand edit and it is the same news either way.
  T required<T>(String field) {
    final value = this[field];
    if (value == null) {
      throw FormatException('"$field" is required');
    }
    if (value is! T) {
      throw FormatException(
        '"$field" should be $T but was ${value.runtimeType}',
      );
    }
    // Cast rather than relying on promotion: the null check above has
    // already promoted `value` to `Object`, and `T` is not a subtype of
    // that for every `T` this is called with.
    return value as T;
  }

  /// [field] when it is there, and null when it is not.
  ///
  /// A value of the wrong type is still refused: a field somebody meant
  /// to set and mistyped is a mistake, not an omission.
  T? optional<T>(String field) {
    final value = this[field];
    if (value == null) return null;
    if (value is! T) {
      throw FormatException(
        '"$field" should be $T or absent but was ${value.runtimeType}',
      );
    }
    return value as T;
  }

  Map<String, Object?> requiredMap(String field) {
    final value = this[field];
    if (value == null) {
      throw FormatException('"$field" is required');
    }
    return _object(value, '"$field"');
  }

  Map<String, Object?>? optionalMap(String field) {
    final value = this[field];
    return value == null ? null : _object(value, '"$field"');
  }

  List<Object?> requiredList(String field) {
    final value = this[field];
    if (value == null) {
      throw FormatException('"$field" is required');
    }
    return _list(value, '"$field"');
  }

  List<Object?>? optionalList(String field) {
    final value = this[field];
    return value == null ? null : _list(value, '"$field"');
  }
}

/// [value] as a JSON object, or a [FormatException] naming [what].
///
/// Taken as `Map` rather than `Map<String, Object?>` because a decoded
/// document hands back `Map<String, dynamic>` and a hand-written literal
/// can be anything at all.
Map<String, Object?> _object(Object? value, String what) {
  if (value is! Map) {
    throw FormatException(
      '$what should be an object but was ${value.runtimeType}',
    );
  }
  return value.cast<String, Object?>();
}

/// [value] as a JSON list, or a [FormatException] naming [what].
List<Object?> _list(Object? value, String what) {
  if (value is! List) {
    throw FormatException(
      '$what should be a list but was ${value.runtimeType}',
    );
  }
  return value;
}

/// A [LogicalRect] from [json], reported as a problem with [field].
///
/// The rectangle's shape belongs to `flutter_testsmith_protocol` and is
/// read there: a second definition of x, y, width and height here would
/// be a second answer to one question. What that one raises is
/// `ProtocolFormatException`, which is not a `FormatException` and so
/// would escape the loader exactly as the cast errors did. Only the type
/// and the field name are added; the message is the protocol's own.
LogicalRect _rect(Map<String, Object?> json, String field) {
  try {
    return LogicalRect.fromJson(json);
  } on ProtocolFormatException catch (error) {
    throw FormatException('"$field": ${error.message}');
  }
}

/// One entry of `elements`, saying which entry when it will not read.
///
/// A spec holds hundreds of them, so "a nodeId is required" without an
/// index is a sentence that sends somebody reading the whole file.
FigmaElement _element(Object? raw, int index) {
  final where = 'elements[$index]';
  final json = _object(raw, where);
  try {
    return FigmaElement.fromJson(json);
  } on FormatException catch (error) {
    throw FormatException('$where: ${error.message}');
  }
}

/// Every entry of [raw] as a string, saying which one is not.
List<String> _strings(List<Object?> raw, String field) {
  final values = <String>[];
  for (final (index, value) in raw.indexed) {
    if (value is! String) {
      throw FormatException(
        '$field[$index] should be a String but was ${value.runtimeType}',
      );
    }
    values.add(value);
  }
  return values;
}
