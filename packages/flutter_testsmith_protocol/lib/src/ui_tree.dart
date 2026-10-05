import 'package:meta/meta.dart';

import 'geometry.dart';
import 'json.dart';

/// One retained node of the semantic UI tree.
///
/// Built by walking the element tree for type, test id and geometry, then
/// enriching from the semantics tree for label and state. Neither source
/// alone supplies all of these; see ADR-0005.
@immutable
class UiNode {
  const UiNode({
    required this.type,
    required this.bounds,
    this.testId,
    this.text,
    this.label,
    this.enabled,
    this.visible = true,
    this.properties = const {},
    this.children = const [],
  });

  /// Stable semantic id, when the element carries one.
  final String? testId;

  /// The Flutter widget type, from the element tree.
  final String type;

  /// Rendered text, for text-bearing widgets.
  final String? text;

  /// Accessible label, from the semantics tree.
  final String? label;

  /// Null when the widget has no notion of being enabled.
  ///
  /// Distinct from `false`: reporting a Text as disabled would be a lie a
  /// business rule could act on.
  final bool? enabled;

  final bool visible;

  final LogicalRect bounds;

  /// Type-specific extras, kept open so new widget types need no protocol
  /// change.
  final Map<String, Object?> properties;

  final List<UiNode> children;

  int get nodeCount =>
      1 + children.fold(0, (sum, child) => sum + child.nodeCount);

  Set<String> get testIds => {
        ?testId,
        for (final child in children) ...child.testIds,
      };

  /// Which route's subtree this node was captured in, if any.
  ///
  /// One-based and in traversal order, so the highest value on a screen
  /// is the topmost route. Null means the node sits outside every route
  /// - app-level chrome around the navigator - which is an absence
  /// rather than a route zero.
  ///
  /// Read from the property bag rather than stored as a field, because
  /// that is where the SDK puts it and inventing a second spelling would
  /// mean two things to keep in step.
  int? get routeIndex => switch (properties['routeIndex']) {
        final int index => index,
        _ => null,
      };

  /// Depth-first search for a descendant (or this node) with [id].
  UiNode? findByTestId(String id) {
    if (testId == id) return this;
    for (final child in children) {
      final found = child.findByTestId(id);
      if (found != null) return found;
    }
    return null;
  }

  /// The nearest node in this subtree satisfying [predicate], this node
  /// included.
  ///
  /// Breadth-first, so "nearest" is by depth and the answer does not
  /// depend on sibling order at different levels. A wrapper that carries
  /// a test id often does not carry the thing being looked for - a
  /// `TestId` around a styled field sits two levels above the
  /// `TextField` that actually holds the text - and searching from the
  /// wrapper is how that is reached without leaving its subtree.
  UiNode? nearestWhere(bool Function(UiNode node) predicate) {
    final queue = <UiNode>[this];
    while (queue.isNotEmpty) {
      final node = queue.removeAt(0);
      if (predicate(node)) return node;
      queue.addAll(node.children);
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        if (testId != null) 'testId': testId,
        'type': type,
        if (text != null) 'text': text,
        if (label != null) 'label': label,
        if (enabled != null) 'enabled': enabled,
        'visible': visible,
        'bounds': bounds.toJson(),
        if (properties.isNotEmpty) 'properties': properties,
        if (children.isNotEmpty)
          'children': [for (final child in children) child.toJson()],
      };

  factory UiNode.fromJson(Map<String, Object?> json) => UiNode(
        testId: json.optional<String>('testId'),
        type: json.required<String>('type'),
        text: json.optional<String>('text'),
        label: json.optional<String>('label'),
        enabled: json.optional<bool>('enabled'),
        visible: json.optional<bool>('visible') ?? true,
        bounds: LogicalRect.fromJson(json.requiredMap('bounds')),
        properties: json.mapOrEmpty('properties'),
        children: [
          for (final raw
              in json.optional<List<Object?>>('children') ?? const [])
            UiNode.fromJson((raw! as Map<Object?, Object?>).cast()),
        ],
      );

  @override
  String toString() =>
      'UiNode($type${testId == null ? '' : ' #$testId'}, $bounds)';
}

/// A device's safe-area inset, in logical pixels.
///
/// Reported with a capture rather than assumed. There is no universal
/// status-bar height: the phone this platform was first run against
/// reports 24, a notched one reports more, a tablet less. A comparison
/// that assumed one would be wrong by the difference on every device
/// that is not the one the assumption came from.
@immutable
class LogicalInsets {
  const LogicalInsets({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  static const LogicalInsets zero = LogicalInsets();

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

  factory LogicalInsets.fromJson(Map<String, Object?> json) => LogicalInsets(
        left: (json['left'] as num?)?.toDouble() ?? 0,
        top: (json['top'] as num?)?.toDouble() ?? 0,
        right: (json['right'] as num?)?.toDouble() ?? 0,
        bottom: (json['bottom'] as num?)?.toDouble() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is LogicalInsets &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'l$left t$top r$right b$bottom';
}

/// One capture of a screen's UI tree.
@immutable
class UiSnapshot {
  const UiSnapshot({
    required this.screenId,
    required this.capturedAt,
    required this.devicePixelRatio,
    required this.root,
    this.viewport,
    this.safeArea,
    this.totalElementsWalked = 0,
    this.duplicateTestIds = const {},
  });

  final String screenId;
  final DateTime capturedAt;

  /// The ratio current **at capture**, so bounds can be converted against
  /// the value that was true when they were measured. See risk R3b.
  final double devicePixelRatio;

  final UiNode root;

  /// The display area the app was laid out in, in logical pixels.
  ///
  /// Reported separately because [root] cannot stand in for it: the
  /// synthetic root is the *union of the retained nodes*, so it is
  /// smaller than the display on a screen whose content stops short of
  /// the edges, and larger on one that overflows. Anything projecting a
  /// design onto the screen needs the real viewport.
  ///
  /// Null when the app is on an SDK that predates this field. Callers
  /// must say so rather than falling back to [root] bounds, which is
  /// the mistake this field exists to prevent.
  final LogicalRect? viewport;

  /// The device's safe-area inset at capture, in logical pixels.
  ///
  /// Null when the app is on an SDK that predates this field. A caller
  /// must say so rather than substituting a guess.
  final LogicalInsets? safeArea;

  /// How many elements the walk visited before filtering.
  ///
  /// Reported so the cost of the filter is visible: a retained count far
  /// below this is the filter working, and a retained count close to it
  /// means the retention rules are too loose.
  final int totalElementsWalked;

  /// Ids that appear on more than one element.
  ///
  /// Two elements sharing an id makes every assertion about that id
  /// ambiguous, so it is surfaced as a defect in the application's test
  /// ids rather than resolved by picking the first match. See ADR-0004.
  final Set<String> duplicateTestIds;

  bool get hasAmbiguousIds => duplicateTestIds.isNotEmpty;

  int get retainedNodeCount => root.nodeCount;

  UiNode? find(String testId) => root.findByTestId(testId);

  /// The highest [UiNode.routeIndex] anywhere in the tree, or null when
  /// the capture records no routes at all.
  ///
  /// Flutter keeps a covered route built - `maintainState` defaults to
  /// true - so after a push the tree still holds every widget of the
  /// screen underneath, at its old bounds, reporting `visible: true`.
  /// The index is how a reader tells "on screen" from "still in the
  /// tree", and the highest one is the route the user is looking at.
  int? get topRouteIndex {
    int? highest;
    void walk(UiNode node) {
      final index = node.routeIndex;
      if (index != null && (highest == null || index > highest!)) {
        highest = index;
      }
      node.children.forEach(walk);
    }

    walk(root);
    return highest;
  }

  /// The element carrying [testId] **on the screen the user can see**.
  ///
  /// Not the same as [find], which is a depth-first search over the whole
  /// tree and therefore reaches a covered route *first*: the covered
  /// route was pushed earlier, so it sits earlier in the tree. An id
  /// carried by both the screen underneath and the one on top resolves
  /// to the buried copy, which is the opposite of what a reader means.
  ///
  /// Null when the id exists only on a covered route. That is the
  /// distinction the whole thing is for - "still built" is not "on
  /// screen" - so a caller that wants the old behaviour should say
  /// [find] and mean it.
  UiNode? findOnTopRoute(String testId) {
    final candidates = nodesOnTopRoute(testId);
    return candidates.isEmpty ? null : candidates.first;
  }

  /// Every element carrying [testId] on the screen the user can see, in
  /// traversal order.
  ///
  /// This is what "ambiguous" has to be counted over. The SDK's
  /// [duplicateTestIds] is a fact about the whole retained tree, and
  /// Flutter keeps a covered route built - so navigating from a screen
  /// carrying `cta` to another screen carrying `cta` makes that id
  /// duplicated for the rest of the session, while exactly one of them
  /// can be touched. A resolver that refused on the whole-tree fact
  /// refused a target that had only one possible meaning.
  ///
  /// Both duplicates on one screen still come back as two, which is the
  /// case that genuinely has no single answer.
  List<UiNode> nodesOnTopRoute(String testId) {
    final topmost = topRouteIndex;
    final found = <UiNode>[];
    void walk(UiNode node) {
      if (node.testId == testId && _isOnRoute(node, topmost)) found.add(node);
      node.children.forEach(walk);
    }

    walk(root);
    return found;
  }

  /// Every test id on the screen the user can see.
  ///
  /// What a "no such element" diagnostic should offer as alternatives.
  /// Listing an id that is merely still built sends a reader looking for
  /// a typo on a screen they have already left.
  Set<String> get topRouteTestIds {
    final topmost = topRouteIndex;
    final found = <String>{};
    void walk(UiNode node) {
      final id = node.testId;
      if (id != null && _isOnRoute(node, topmost)) found.add(id);
      node.children.forEach(walk);
    }

    walk(root);
    return found;
  }

  /// Whether [node] belongs to the route the user is looking at.
  ///
  /// Two absences are deliberately **kept** rather than refused:
  ///
  /// * a capture with no indices at all - an older SDK, or a Flutter
  ///   that renamed the private route-scope widget - would otherwise
  ///   make every element on every screen unreachable;
  /// * a node with no index of its own, which is app-level chrome
  ///   outside the navigator and is genuinely on screen.
  ///
  /// Not knowing where something is is not a reason to act as though it
  /// were hidden.
  bool isOnTopRoute(UiNode node) => _isOnRoute(node, topRouteIndex);

  /// The rule itself, against an already-computed topmost route.
  ///
  /// Separate only so a walk over the tree does not recompute the
  /// topmost route once per node.
  static bool _isOnRoute(UiNode node, int? topmost) {
    if (topmost == null) return true;
    final index = node.routeIndex;
    if (index == null) return true;
    return index >= topmost;
  }

  Map<String, Object?> toJson() => {
        'screenId': screenId,
        'capturedAt': formatUtcTimestamp(capturedAt),
        'devicePixelRatio': devicePixelRatio,
        if (viewport != null) 'viewport': viewport!.toJson(),
        if (safeArea != null) 'safeArea': safeArea!.toJson(),
        'totalElementsWalked': totalElementsWalked,
        if (duplicateTestIds.isNotEmpty)
          'duplicateTestIds': duplicateTestIds.toList(),
        'root': root.toJson(),
      };

  factory UiSnapshot.fromJson(Map<String, Object?> json) => UiSnapshot(
        screenId: json.required<String>('screenId'),
        capturedAt: json.requiredUtcTimestamp('capturedAt'),
        devicePixelRatio: json.requiredDouble('devicePixelRatio'),
        viewport: json['viewport'] == null
            ? null
            : LogicalRect.fromJson(json.requiredMap('viewport')),
        safeArea: json['safeArea'] == null
            ? null
            : LogicalInsets.fromJson(json.requiredMap('safeArea')),
        totalElementsWalked: json.optional<int>('totalElementsWalked') ?? 0,
        duplicateTestIds:
            (json.optional<List<Object?>>('duplicateTestIds') ?? const [])
                .cast<String>()
                .toSet(),
        root: UiNode.fromJson(json.requiredMap('root')),
      );

  @override
  String toString() => 'UiSnapshot($screenId, $retainedNodeCount nodes of '
      '$totalElementsWalked elements, dpr $devicePixelRatio)';
}
