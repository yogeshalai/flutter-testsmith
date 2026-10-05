import 'package:flutter/widgets.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../session/test_session.dart';

/// Derives a stable screen id from a route.
typedef ScreenIdResolver = String Function(Route<dynamic> route);

/// The default resolution: the route's name, or an obviously synthetic
/// marker.
///
/// The marker is deliberately ugly. An unnamed route has no stable
/// identifier, and a plausible-looking fallback would let an unstable id
/// pass unnoticed into reports and mappings. See ARCHITECTURE 9.3.
String defaultScreenIdResolver(Route<dynamic> route) {
  final name = route.settings.name;
  if (name != null && name.isNotEmpty && !_isUnstable(name)) return name;
  return '<unnamed:${route.runtimeType}>';
}

/// Whether a route name is an identity rather than a name.
///
/// A name made only of digits is not a screen id anybody wrote. It is
/// an object hash, and it changes every run.
///
/// Measured against a real external application: go_router names the
/// route it builds for a `StatefulShellRoute` with exactly that, and two
/// consecutive runs of the same flow reported `100338058` and then
/// `720295915`. Trusting it would let an id that *looks* stable into
/// mappings, baselines and reports, where it would silently bind to
/// nothing on the next run.
///
/// The loud marker is the better answer. It is obviously not an id, so
/// it gets noticed and fixed - by naming the route - instead of quietly
/// rotting.
bool _isUnstable(String name) =>
    name.length > 3 && int.tryParse(name) != null;

/// Reports navigation to the [TestSession].
///
/// Attach through `MaterialApp(navigatorObservers: [...])`. When [session]
/// is null the observer is inert, so an application can wire it
/// unconditionally and let the SDK's gating decide whether anything is
/// recorded.
class TestNavigatorObserver extends NavigatorObserver {
  TestNavigatorObserver({
    required this.session,
    this.resolveScreenId = defaultScreenIdResolver,
  });

  final TestSession? session;
  final ScreenIdResolver resolveScreenId;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final session = this.session;
    if (session == null) return;
    session.enterScreen(
      ScreenEnterPayload(
        screenId: resolveScreenId(route),
        routeName: route.settings.name,
        previousScreenId:
            previousRoute == null ? null : resolveScreenId(previousRoute),
      ),
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final session = this.session;
    if (session == null) return;
    session.exitScreen(
      ScreenExitPayload(
        screenId: resolveScreenId(route),
        nextScreenId:
            previousRoute == null ? null : resolveScreenId(previousRoute),
      ),
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final session = this.session;
    if (session == null || newRoute == null) return;

    final newId = resolveScreenId(newRoute);

    // A replace is a departure and an arrival. Emitting both keeps the
    // screen history a continuous chain, which the engine's session
    // correlation depends on.
    if (oldRoute != null) {
      session.exitScreen(
        ScreenExitPayload(
          screenId: resolveScreenId(oldRoute),
          nextScreenId: newId,
        ),
      );
    }

    session.enterScreen(
      ScreenEnterPayload(
        screenId: newId,
        routeName: newRoute.settings.name,
        previousScreenId:
            oldRoute == null ? null : resolveScreenId(oldRoute),
      ),
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final session = this.session;
    if (session == null) return;
    session.exitScreen(
      ScreenExitPayload(
        screenId: resolveScreenId(route),
        nextScreenId:
            previousRoute == null ? null : resolveScreenId(previousRoute),
      ),
    );
  }
}
