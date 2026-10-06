import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../identity/test_id.dart';

/// Names the animations that are running, so they can be declared.
///
/// The count alone - `2 animations running` - is a dead end. It says a
/// screen will never settle without saying which widget to go and look
/// at, so the only available response was to stop requiring settle at
/// all, which is exactly the blanket that must not be thrown.
///
/// ## How it finds them
///
/// Every widget-driven animation in Flutter runs on a [Ticker] created
/// through `TickerProviderStateMixin` or its single-ticker sibling, and
/// both mixins publish their tickers through `debugFillProperties`.
/// Reading them through `toDiagnosticsNode().getProperties()` is public
/// API on both sides: the property's `value` is the real `Ticker`.
///
/// ## Why the count is trustworthy
///
/// The predicate is [Ticker.isTicking], not `isActive`. A ticker that is
/// started but muted - the state Flutter puts a covered route into - is
/// active and not ticking, and schedules no frame. Measured in
/// `animation_inventory_test.dart`: the number of ticking tickers equals
/// `transientCallbackCount` exactly. That equality is what makes a
/// declared exception safe, because it means there is no unattributed
/// remainder for an undeclared animation to hide in.
class AnimationInspector {
  const AnimationInspector();

  /// Every animation ticking under [root], in traversal order.
  List<AnimationActivity> inspect(Element root) {
    final found = <AnimationActivity>[];
    final ids = <String>[];
    var routeScopes = 0;

    void visit(Element element) {
      final id = resolveTestId(element);
      if (id != null) ids.add(id);

      // Counted the same way and for the same reason as the UI tree's
      // route index, so the two agree about which screen is on top.
      final entersRoute = _isRouteScope(element);
      if (entersRoute) routeScopes++;
      final routeIndex = routeScopes;

      if (element is StatefulElement) {
        for (final ticker in _tickersOf(element.state)) {
          if (!ticker.isTicking) continue;
          found.add(
            AnimationActivity(
              owner: element.widget.runtimeType.toString(),
              elementPath: List<String>.unmodifiable(ids),
              routeIndex: routeIndex > 0 ? routeIndex : null,
              label: ticker.debugLabel,
              bounds: _boundsOf(element),
            ),
          );
        }
      }

      element.visitChildren(visit);

      if (id != null) ids.removeLast();
    }

    visit(root);
    return found;
  }

  /// The highest route index in the tree - the screen on top.
  int? topRouteIndex(Element root) {
    var routeScopes = 0;

    void visit(Element element) {
      if (_isRouteScope(element)) routeScopes++;
      element.visitChildren(visit);
    }

    visit(root);
    return routeScopes > 0 ? routeScopes : null;
  }

  /// The tickers a [State] owns, however many it has.
  ///
  /// `SingleTickerProviderStateMixin` publishes one under `ticker`;
  /// `TickerProviderStateMixin` publishes a set under `tickers`. Read
  /// through the diagnostics node rather than by calling the protected
  /// `debugFillProperties` directly - same values, public on both sides.
  Iterable<Ticker> _tickersOf(State state) sync* {
    for (final property in state.toDiagnosticsNode().getProperties()) {
      final value = property.value;
      if (value is Ticker) yield value;
      if (value is Set<Ticker>) yield* value;
    }
  }

  /// Where the animating widget is, when it has a box to be in.
  ///
  /// The only thing that identifies an animation with no semantic id.
  static LogicalRect? _boundsOf(Element element) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox ||
        !renderObject.hasSize ||
        !renderObject.attached) {
      return null;
    }
    final offset = renderObject.localToGlobal(Offset.zero);
    return LogicalRect(
      x: offset.dx,
      y: offset.dy,
      width: renderObject.size.width,
      height: renderObject.size.height,
    );
  }

  static bool _isRouteScope(Element element) =>
      element.widget.runtimeType.toString().startsWith('_ModalScopeStatus');
}
