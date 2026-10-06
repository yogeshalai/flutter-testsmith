import 'package:meta/meta.dart';
import 'package:flutter_testsmith/protocol.dart';

import '../device/coordinates.dart';
import '../validation/validators.dart';

/// No element in the captured tree carries the requested id.
@immutable
class ElementNotFoundException implements Exception {
  const ElementNotFoundException({
    required this.testId,
    required this.available,
  });

  final String testId;
  final List<String> available;

  @override
  String toString() {
    // Naming what *is* present usually reveals the typo at a glance,
    // which a bare "not found" never does.
    final ids = available.isEmpty
        ? 'the captured tree has no test ids at all'
        : 'available ids: ${available.join(', ')}';
    return 'ElementNotFoundException: no element with test id "$testId". '
        'On this screen, $ids.';
  }
}

/// The element exists but cannot receive a tap.
@immutable
class ElementNotTappableException implements Exception {
  const ElementNotTappableException({
    required this.testId,
    required this.reason,
  });

  final String testId;
  final String reason;

  @override
  String toString() =>
      'ElementNotTappableException: "$testId" cannot be tapped: $reason';
}

/// More than one element carries the id.
@immutable
class AmbiguousElementException implements Exception {
  const AmbiguousElementException(
    this.testId, {
    this.candidates,
    this.routeIndex,
  });

  final String testId;

  /// How many elements on the visible route carry the id.
  ///
  /// Null when the capture recorded no routes, so the only evidence was
  /// the snapshot's own `duplicateTestIds` - which says *that* the id is
  /// duplicated, not how many copies a reader could have meant.
  final int? candidates;

  /// The route those candidates are on, when the capture records routes.
  final int? routeIndex;

  @override
  String toString() {
    final measured = candidates == null
        ? '"$testId" appears on more than one element'
        : '"$testId" matches $candidates elements'
            '${routeIndex == null ? '' : ' on route $routeIndex'}';
    return 'AmbiguousElementException: $measured, so an assertion or tap '
        'on it has no single meaning. Give each element a distinct test '
        'id.';
  }
}

/// Turns a semantic element id into somewhere to tap.
///
/// This is the layer that gives element awareness to a coordinate-only
/// device controller: tests stay semantic while the input stays real. See
/// ADR-0006.
///
/// The conversion deliberately uses the pixel ratio recorded **in this
/// snapshot**, so bounds and ratio always come from the same read. Using a
/// ratio captured at attach is the R3b bug.
class ElementLocator {
  ElementLocator(this.snapshot)
      : _space = CoordinateSpace(
          devicePixelRatio: snapshot.devicePixelRatio,
        );

  final UiSnapshot snapshot;
  final CoordinateSpace _space;

  /// Every test id on the screen the user can see.
  ///
  /// What a "no such element" message should offer as alternatives.
  /// Naming an id that is merely still built - Flutter keeps a covered
  /// route alive - sends a reader hunting for a typo on a screen the
  /// flow has already left. A capture that records no routes lists
  /// everything, exactly as it always did.
  List<String> get availableIds => snapshot.topRouteTestIds.toList();

  /// Whether [testId] is on the screen the user can see.
  ///
  /// Not "is it in the tree": a covered route stays built, so the tree
  /// answers yes about screens the flow has already left.
  bool contains(String testId) => snapshot.findOnTopRoute(testId) != null;

  /// The one element [testId] can mean on the current screen.
  ///
  /// Ambiguity is counted among the candidates a tap could actually land
  /// on - those on the visible route - rather than over the whole
  /// retained tree. The snapshot's `duplicateTestIds` remains exactly
  /// what it says: a fact about every element captured, which is the
  /// right thing for `testsmith inspect` to report as an application defect
  /// and the wrong thing to refuse an unambiguous target on. Navigating
  /// A -> B where both carry `cta` flags `cta` for the rest of the
  /// session, while only one of them can be touched.
  ///
  /// When the capture records **no** routes at all - an older SDK, or a
  /// Flutter that renamed the private route-scope widget - there is no
  /// better evidence than that whole-tree fact, so it decides, exactly
  /// as it always did.
  UiNode nodeFor(String testId) {
    final onTop = snapshot.nodesOnTopRoute(testId);
    final routesKnown = snapshot.topRouteIndex != null;

    if (onTop.length > 1) {
      throw AmbiguousElementException(
        testId,
        candidates: onTop.length,
        routeIndex: snapshot.topRouteIndex,
      );
    }
    if (!routesKnown &&
        onTop.isNotEmpty &&
        snapshot.duplicateTestIds.contains(testId)) {
      throw AmbiguousElementException(testId);
    }
    if (onTop.length == 1) return onTop.single;

    // Nothing on the visible route. Hand back whatever the tree holds so
    // the caller's own check can tell "buried under a dialog" from "not
    // there at all" - two disappointments that send a reader to
    // completely different places.
    final anywhere = snapshot.find(testId);
    if (anywhere == null) {
      throw ElementNotFoundException(
        testId: testId,
        available: availableIds,
      );
    }
    return anywhere;
  }

  /// Where a tap on [testId] should land, in device physical pixels.
  PhysicalPoint pointFor(String testId) {
    final node = nodeFor(testId);

    // The element belongs to a screen something else is drawn over.
    //
    // First of the refusals, because it is the only one that says the
    // measurements below describe the wrong screen. A covered route
    // reports real bounds and `visible: true` - Flutter keeps it built -
    // so every other check here passes and the tap is dispatched at
    // coordinates the route on top now owns.
    //
    // The engine already drew this line three times: quiescence ignores
    // animations below the top route, the visual validator excludes
    // their pixels, and the property reader will not read text across
    // routes. The action path, which is the one that touches the
    // device, consulted none of them.
    if (!snapshot.isOnTopRoute(node)) {
      throw ElementNotTappableException(
        testId: testId,
        reason: 'it belongs to route ${node.routeIndex}, and route '
            '${snapshot.topRouteIndex} is on top. It is present as a '
            '${node.type} with bounds ${node.bounds} and reports itself '
            'visible, because Flutter keeps a covered route built - but '
            'those are the coordinates of a screen something else is now '
            'drawn over, so a tap there would land on whatever is in '
            'front. Dismiss what is on top, or address the element that '
            'is.',
      );
    }

    // Order matters less than the message. The SDK derives `visible`
    // from whether the bounds have area, so a zero-sized element would
    // otherwise always report the vague "not visible" and never the
    // measurement that explains it.
    if (node.bounds.isEmpty) {
      throw ElementNotTappableException(
        testId: testId,
        reason: 'it has zero area (${node.bounds.width} x '
            '${node.bounds.height} at ${node.bounds.x},${node.bounds.y}), so '
            'a tap would silently do nothing. The element is in the tree as '
            'a ${node.type}, so this is a layout state rather than a '
            'missing widget - it may not have been laid out yet.',
      );
    }
    if (!node.visible) {
      throw ElementNotTappableException(
        testId: testId,
        reason: 'it is present as a ${node.type} with bounds '
            '${node.bounds}, but is marked not visible',
      );
    }

    // Laid out below the fold. Found on a device in Phase 12: the Add
    // to Cart button sits at the foot of a 1198pt page, the tap was
    // dispatched to a y outside the screen, and Android delivered it to
    // nothing at all. The run then failed several steps later, on an
    // `expectScreen` that had no idea why it was still where it was.
    //
    // A tap that cannot land must say so where it happens. The platform
    // has no scroll step yet, so this is a refusal rather than a
    // recovery - but a refusal that names the measurement beats a
    // silent no-op by a wide margin.
    final viewport = snapshot.viewport;
    if (viewport != null) {
      final centreY = node.bounds.y + node.bounds.height / 2;
      final centreX = node.bounds.x + node.bounds.width / 2;
      final outside = centreY < viewport.y ||
          centreY > viewport.y + viewport.height ||
          centreX < viewport.x ||
          centreX > viewport.x + viewport.width;

      if (outside) {
        throw ElementNotTappableException(
          testId: testId,
          reason: 'its centre is at '
              '(${centreX.toStringAsFixed(1)}, '
              '${centreY.toStringAsFixed(1)}) and the viewport is '
              '${viewport.width.toStringAsFixed(0)}x'
              '${viewport.height.toStringAsFixed(0)}, so it is off '
              'screen and a tap there would land on nothing. Scroll it '
              'into view before tapping - the platform has no scroll '
              'step, so a flow must reach it another way.',
        );
      }
    }

    // The application has said this control does not take input.
    //
    // Last of the refusals, so the measurements above keep their own
    // words: a button with no area is a layout state, and reporting it
    // as disabled would send a reader to the wrong place.
    //
    // A tap here is not a test. Flutter delivers the pointer event and
    // a widget built with `onPressed: null` has nothing to run, so the
    // step reported success for an action that could not happen and the
    // run failed later on an assertion that blamed the consequence.
    //
    // Read through [readPropertyOf], which is where this platform
    // already resolves a property that sits below the id: a `TestId`
    // wrapper carries no `enabled` of its own - no wrapper does - so
    // reading the node alone always reported "no such notion" and this
    // gate would never have fired on a real application.
    //
    // Deliberately one-sided. Only an unambiguous `false` refuses;
    // "no such notion" and "descendants disagree" are tapped, because
    // an unchecked dimension must never become a verdict.
    if (readPropertyOf(node, 'enabled') case PropertyValue(value: false)) {
      throw ElementNotTappableException(
        testId: testId,
        reason: 'the application reports it as disabled. It is present as '
            'a ${node.type} with bounds ${node.bounds}, so a tap would be '
            'delivered and do nothing: a disabled control has no callback '
            'to run. Nothing here says the application is wrong - a '
            'control may be disabled exactly as intended, in which case '
            'the flow should assert that with `expectElement` rather than '
            'tap it.',
      );
    }

    return _space.centreOf(node.bounds);
  }
}
