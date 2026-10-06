import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../identity/test_id.dart';
import '../redaction.dart';
import 'retention_policy.dart';

/// Property key carrying which route a node belongs to.
///
/// One-based, in traversal order; the highest value on a screen is the
/// topmost route. Absent when the node sits outside any route.
const String kRouteIndexProperty = 'routeIndex';

/// Builds the semantic UI tree.
///
/// Walks the **element** tree for widget type, test id and geometry, then
/// enriches each retained node with what only the widget or its semantics
/// can say - text, accessible label, enabled state. Neither of Flutter's
/// two trees supplies all of that on its own; see ADR-0005.
class UiTreeInspector {
  const UiTreeInspector({
    this.policy = const UiRetentionPolicy.defaults(),
  });

  final UiRetentionPolicy policy;

  UiSnapshot capture({
    required Element root,
    required String screenId,
    required double devicePixelRatio,
  }) {
    // The display area, which the synthetic root cannot describe: that
    // root is the union of the retained nodes, so it is smaller than
    // the screen whenever content stops short of the edges.
    final renderObject = root.renderObject;
    final viewport = renderObject is RenderView
        ? LogicalRect(
            x: 0,
            y: 0,
            width: renderObject.size.width,
            height: renderObject.size.height,
          )
        : null;

    // The device's own inset, read from the view rather than assumed.
    // `FlutterView.padding` is in *physical* pixels; every other
    // measurement in a snapshot is logical, so it is converted here
    // rather than leaving two units in one object.
    final safeArea = renderObject is RenderView
        ? () {
            final padding = renderObject.flutterView.padding;
            final ratio = renderObject.flutterView.devicePixelRatio;
            return LogicalInsets(
              left: padding.left / ratio,
              top: padding.top / ratio,
              right: padding.right / ratio,
              bottom: padding.bottom / ratio,
            );
          }()
        : null;

    var walked = 0;
    final seenIds = <String>{};
    final duplicates = <String>{};

    // Which route's subtree the walk is currently inside.
    //
    // Flutter keeps a covered route built (`maintainState` defaults to
    // true), so the element tree on screen B still contains every widget
    // of screen A, with real bounds and `visible: true`. Measured:
    // pushing a second route and capturing reported *both* routes' test
    // ids, and Phase 12 saw `home.open_cart` named among the
    // worst-differing elements while the app was on `/product/details`.
    //
    // `_ModalScopeStatus` is the widget Flutter wraps each route's
    // subtree in, and the overlay builds entries bottom-first, so the
    // highest index is the topmost route. Matched by type name because
    // the class is private - the same way the retention policy already
    // recognises widget types. If a future Flutter renames it, every
    // node simply carries index 0 and behaviour returns to what it was.
    var routeScopes = 0;

    /// Returns the retained nodes produced by [element] and its subtree.
    ///
    /// Returns a list rather than a node because a dropped element must
    /// hand its children upward: dropping a node must never drop its
    /// subtree.
    List<UiNode> visit(Element element) {
      walked++;

      final entersRoute = _isRouteScope(element);
      if (entersRoute) routeScopes++;
      final routeIndex = routeScopes;

      final children = <UiNode>[];
      element.visitChildren((child) => children.addAll(visit(child)));

      final testId = resolveTestId(element);
      if (testId != null && !seenIds.add(testId)) {
        duplicates.add(testId);
      }

      final type = element.widget.runtimeType.toString();
      final bounds = _boundsOf(element);

      final keep = testId != null ||
          policy.isInterestingType(type) ||
          _carriesSemanticData(element);

      // An element with no geometry has no meaningful place in a spatial
      // tree, and reporting a zero rect invites a tap that silently does
      // nothing.
      if (!keep || bounds == null) return children;

      final text = _textOf(element);

      return [
        UiNode(
          testId: testId,
          type: type,
          text: text,
          label: _labelOf(element),
          enabled: _enabledOf(element),
          visible: !bounds.isEmpty,
          bounds: bounds,
          properties: {
            ..._textStyleOf(element),
            ..._visualOf(element),
            if (routeIndex > 0) kRouteIndexProperty: routeIndex,
          },
          children: _withoutEchoes(children, text, bounds),
        ),
      ];
    }

    final roots = visit(root);

    return UiSnapshot(
      screenId: screenId,
      capturedAt: DateTime.now().toUtc(),
      devicePixelRatio: devicePixelRatio,
      viewport: viewport,
      safeArea: safeArea,
      totalElementsWalked: walked,
      duplicateTestIds: duplicates,
      // A screen can legitimately produce several top-level retained
      // nodes (overlays, dialogs). They are gathered under a synthetic
      // root so the snapshot always has a single entry point.
      root: roots.length == 1
          ? roots.single
          : UiNode(
              type: 'Root',
              bounds: _unionOf(roots),
              children: roots,
            ),
    );
  }

  /// Whether [element] begins a route's subtree.
  static bool _isRouteScope(Element element) =>
      element.widget.runtimeType.toString().startsWith('_ModalScopeStatus');

  static LogicalRect? _boundsOf(Element element) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    if (!renderObject.attached) return null;

    final offset = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    return LogicalRect(
      x: offset.dx,
      y: offset.dy,
      width: size.width,
      height: size.height,
    );
  }

  static LogicalRect _unionOf(List<UiNode> nodes) {
    if (nodes.isEmpty) {
      return const LogicalRect(x: 0, y: 0, width: 0, height: 0);
    }
    var left = nodes.first.bounds.x;
    var top = nodes.first.bounds.y;
    var right = left + nodes.first.bounds.width;
    var bottom = top + nodes.first.bounds.height;

    for (final node in nodes.skip(1)) {
      final b = node.bounds;
      if (b.x < left) left = b.x;
      if (b.y < top) top = b.y;
      if (b.x + b.width > right) right = b.x + b.width;
      if (b.y + b.height > bottom) bottom = b.y + b.height;
    }
    return LogicalRect(
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  /// The text style the element actually painted with.
  ///
  /// Read from the [RenderParagraph], not from the widget, and that
  /// distinction is the whole point: `Text('x')` carries no style at
  /// all - the size, weight and colour come from `DefaultTextStyle` and
  /// the theme. Only the render object knows what was resolved, and a
  /// design comparison needs the resolved value, not the declared one.
  ///
  /// Empty for everything that is not text, so the property bag stays
  /// small on screens full of layout widgets.
  static Map<String, Object?> _textStyleOf(Element element) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderParagraph) return const {};

    final style = renderObject.text.style;
    if (style == null) return const {};

    return {
      if (style.fontSize != null) 'fontSize': style.fontSize,
      if (style.fontWeight != null) 'fontWeight': style.fontWeight!.value,
      if (style.fontFamily != null) 'fontFamily': style.fontFamily,
      if (style.color != null) 'color': _hexOf(style.color!),
    };
  }

  /// Opacity, fill and corner radius, for design comparison.
  ///
  /// Read from `element.renderObject` - the *same* render object the
  /// bounds come from - and from nothing else. There is no descendant
  /// search and no widget-type special case, and that is the whole
  /// design rather than an omission.
  ///
  /// A test id names one thing. The moment an inspector starts hunting
  /// downward for "the nearest Container with a decoration", the value
  /// in the report belongs to a widget nobody named, and nothing in the
  /// report says so. A comparison against a property that is not here
  /// reports that it could not read one, which is a statement someone
  /// can act on.
  ///
  /// The types below are Flutter's **render** classes, not its widgets.
  /// They are listed because each publishes the property; `ColoredBox`
  /// is absent because `_RenderColoredBox` is private and publishes
  /// nothing, not because it was overlooked.
  static Map<String, Object?> _visualOf(Element element) {
    final renderObject = element.renderObject;
    if (renderObject == null) return const {};

    final properties = <String, Object?>{};

    if (renderObject is RenderAnimatedOpacity) {
      properties['opacity'] = renderObject.opacity.value;
    } else if (renderObject is RenderOpacity) {
      properties['opacity'] = renderObject.opacity;
    }

    if (renderObject is RenderDecoratedBox) {
      _fromDecoration(renderObject.decoration, properties);
    } else if (renderObject is RenderPhysicalModel) {
      properties['fill'] = _hexOf(renderObject.color);
      _uniformRadius(renderObject.borderRadius, properties);
    }

    return properties;
  }

  static void _fromDecoration(
    Decoration decoration,
    Map<String, Object?> into,
  ) {
    if (decoration is BoxDecoration) {
      final colour = decoration.color;
      if (colour != null) into['fill'] = _hexOf(colour);
      final radius = decoration.borderRadius;
      if (radius is BorderRadius) _uniformRadius(radius, into);
      return;
    }
    if (decoration is ShapeDecoration) {
      final colour = decoration.color;
      if (colour != null) into['fill'] = _hexOf(colour);
      final shape = decoration.shape;
      if (shape is RoundedRectangleBorder) {
        final radius = shape.borderRadius;
        if (radius is BorderRadius) _uniformRadius(radius, into);
      }
    }
  }

  /// A single corner radius, reported only when every corner agrees.
  ///
  /// Figma's `cornerRadius` is one number and exists only for a uniform
  /// rounding; a box rounded at the top alone has no single value, and
  /// reporting one of its four would compare against something the
  /// design never said.
  static void _uniformRadius(
    BorderRadius? radius,
    Map<String, Object?> into,
  ) {
    if (radius == null) return;
    final corners = [
      radius.topLeft,
      radius.topRight,
      radius.bottomLeft,
      radius.bottomRight,
    ];
    final first = corners.first;
    // An elliptical corner has no single radius either.
    if (first.x != first.y) return;
    for (final corner in corners) {
      if (corner.x != first.x || corner.y != first.y) return;
    }
    if (first.x == 0) return;
    into['cornerRadius'] = first.x;
  }

  /// `#rrggbbaa`, matching the form the Figma normaliser emits so the two
  /// can be compared without either side guessing at a convention.
  static String _hexOf(Color color) {
    final argb = color.toARGB32();
    String channel(int shift) =>
        ((argb >> shift) & 0xff).toRadixString(16).padLeft(2, '0');
    return '#${channel(16)}${channel(8)}${channel(0)}${channel(24)}';
  }

  /// The text an element renders, with obscured fields redacted.
  ///
  /// The redaction is not optional and not configurable. A field the
  /// application chose to obscure on screen is a field whose contents
  /// must not leave the process, and the UI tree leaves the process:
  /// it is emitted as a `WIDGET_TREE` event and written to disk by
  /// `testsmith inspect --json`.
  ///
  /// Found in Phase 12 by reading a real capture. The example
  /// application's sign-in screen uses `obscureText: true`, the screen
  /// showed dots, and the tree carried the password in plaintext -
  /// `TextField #login.password "SEEDED_PASSWORD_c41e77b0"`. Network
  /// capture had been redacting since Phase 3; nothing had ever looked
  /// at this path.
  ///
  /// The length is kept, because "the field is empty" and "the field
  /// has something in it" is a distinction a test legitimately needs
  /// and no part of the secret.
  static String? _textOf(Element element) {
    final widget = element.widget;
    if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText();
    if (widget is RichText) return widget.text.toPlainText();

    if (widget is EditableText) {
      return _maskIfObscured(widget.controller.text, widget.obscureText);
    }
    if (widget is TextField) {
      return _maskIfObscured(widget.controller?.text, widget.obscureText);
    }
    return null;
  }

  /// `[REDACTED:n]` for an obscured field, the text itself otherwise.
  static String? _maskIfObscured(String? text, bool obscured) {
    if (!obscured || text == null) return text;
    return text.isEmpty
        ? text
        : '${RedactionPolicy.marker}:${text.length}';
  }

  static String? _labelOf(Element element) {
    final widget = element.widget;
    if (widget is Semantics) return widget.properties.label;

    // debugSemantics is populated once semantics are enabled, which the
    // SDK ensures in test mode. It is the only route to the accessible
    // label without duplicating Flutter's semantics compilation.
    final label = element.renderObject?.debugSemantics?.label;
    return (label == null || label.isEmpty) ? null : label;
  }

  /// Whether the element has a notion of being enabled, and if so what it
  /// is.
  ///
  /// Null means "no such notion". That is deliberately distinct from
  /// false: reporting a Text as disabled would be a lie a business rule
  /// could act on.
  static bool? _enabledOf(Element element) {
    final widget = element.widget;

    if (widget is ButtonStyleButton) return widget.onPressed != null;
    // A list row has its own `enabled`, and it is the ordinary way an
    // application expresses "you cannot choose this one". Without it the
    // tree reported null - "no such notion" - and a rule asserting
    // `enabled: false` on a correctly disabled row failed.
    if (widget is ListTile) return widget.enabled;
    if (widget is IconButton) return widget.onPressed != null;
    if (widget is MaterialButton) return widget.onPressed != null;
    if (widget is FloatingActionButton) return widget.onPressed != null;
    if (widget is InkWell) return widget.onTap != null;
    if (widget is TextField) return widget.enabled ?? true;
    if (widget is Checkbox) return widget.onChanged != null;
    if (widget is Radio) return widget.enabled;
    if (widget is Switch) return widget.onChanged != null;
    if (widget is Slider) return widget.onChanged != null;

    // An explicit Semantics(enabled:) is the widget's own statement.
    if (widget is Semantics) return widget.properties.enabled;

    // No fallback to debugSemantics. That reports the semantics node an
    // element *contributed to*, often an ancestor's or an aggregate, and
    // using it here made a BackButton report `disabled` while the
    // IconButton it wraps reported `enabled`. Unknown is reported as
    // unknown: a wrong `false` is a lie a business rule would act on.
    return null;
  }

  /// Whether this element itself contributes semantic information.
  ///
  /// Deliberately *not* based on `RenderObject.debugSemantics`: that
  /// reports the semantics node an element contributed to, which is
  /// frequently an ancestor's. Using it for retention kept every
  /// inherited-widget wrapper inside a labelled subtree - measured on the
  /// device as a ten-deep chain of identical empty nodes. It remains fine
  /// for *reading* a label off a node we have already decided to keep.
  static bool _carriesSemanticData(Element element) {
    final widget = element.widget;
    if (widget is! Semantics) return false;

    final properties = widget.properties;
    return (properties.identifier?.isNotEmpty ?? false) ||
        (properties.label?.isNotEmpty ?? false) ||
        (properties.value?.isNotEmpty ?? false) ||
        properties.enabled != null ||
        properties.checked != null ||
        properties.selected != null;
  }

  /// Drops a lone child that merely restates its parent.
  ///
  /// Every `Text` builds a `RichText` with the same content and the same
  /// bounds; reporting both doubles the tree and tells the reader nothing.
  /// A child with its own test id is always kept, because something is
  /// addressing it.
  static List<UiNode> _withoutEchoes(
    List<UiNode> children,
    String? parentText,
    LogicalRect parentBounds,
  ) {
    if (children.length != 1 || parentText == null) return children;

    final child = children.single;
    final echoes = child.testId == null &&
        child.text == parentText &&
        child.bounds == parentBounds &&
        child.children.isEmpty;

    return echoes ? const [] : children;
  }
}
