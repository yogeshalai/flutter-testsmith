import 'package:meta/meta.dart';

import 'geometry.dart';
import 'json.dart';

/// One animation that is running right now, named.
///
/// Flutter's `transientCallbackCount` says *how many* animations are
/// running and nothing else, which is enough to refuse to photograph a
/// screen but not enough to reason about it. A screen that shimmers for
/// ever could therefore only be given up on - and giving up meant no
/// visual regression at all on two of a real application's three
/// screens.
///
/// To declare an exception you have to be able to name the thing you are
/// excepting. This is that name.
///
/// It deliberately carries no content: a widget type, the semantic ids
/// enclosing it, and where it sits. An inventory taken on a login screen
/// must not become a second way to read a password.
@immutable
class AnimationActivity {
  const AnimationActivity({
    required this.owner,
    this.elementPath = const [],
    this.routeIndex,
    this.label,
    this.bounds,
  });

  /// The widget whose `State` owns the ticker - `AppMarqueeText`,
  /// `Shimmer`, `FadeTransition`.
  ///
  /// The widget rather than the ticker, because that is what an author
  /// can find in their own source.
  final String owner;

  /// Every semantic id enclosing it, outermost first.
  ///
  /// The whole path rather than the nearest one, so a declaration may
  /// name any honest ancestor instead of having to guess which id the
  /// platform considers closest.
  final List<String> elementPath;

  /// Which route it belongs to, counted from the bottom of the stack.
  ///
  /// Flutter mutes tickers underneath an *opaque* route, so most of the
  /// time this is the current screen's. A transparent route - a dialog,
  /// a bottom sheet - does not mute, and then this is the only thing
  /// that distinguishes the dashboard still turning underneath from
  /// something moving on the dialog itself.
  final int? routeIndex;

  /// `Ticker.debugLabel`, when the ticker carries one.
  final String? label;

  /// Where it is on screen, in logical pixels.
  ///
  /// A widget type alone identifies an animation poorly when it has no
  /// semantic id - measured on a real dashboard with four possible
  /// `CircularProgressIndicator` sites in one file, where the position
  /// was the only thing that said which one was still spinning.
  final LogicalRect? bounds;

  /// The nearest enclosing semantic id, or null when it has none.
  String? get elementId => elementPath.isEmpty ? null : elementPath.last;

  /// How to refer to this animation in a sentence.
  String get describe {
    final id = elementId;
    final where = bounds == null
        ? ''
        : ' at ${bounds!.x.round()},${bounds!.y.round()} '
            '${bounds!.width.round()}x${bounds!.height.round()}';
    return id == null
        ? '$owner$where (no semantic id)'
        : '$owner in "$id"$where';
  }

  Map<String, Object?> toJson() => {
        'owner': owner,
        if (elementPath.isNotEmpty) 'elementPath': elementPath,
        if (routeIndex != null) 'routeIndex': routeIndex,
        if (label != null) 'label': label,
        if (bounds != null) 'bounds': bounds!.toJson(),
      };

  factory AnimationActivity.fromJson(Map<String, Object?> json) =>
      AnimationActivity(
        owner: json.required<String>('owner'),
        elementPath: [
          for (final id in json.optional<List<Object?>>('elementPath') ??
              const <Object?>[])
            id.toString(),
        ],
        routeIndex: (json['routeIndex'] as num?)?.toInt(),
        label: json.optional<String>('label'),
        bounds: switch (json['bounds']) {
          final Map<Object?, Object?> raw =>
            LogicalRect.fromJson(raw.cast<String, Object?>()),
          _ => null,
        },
      );

  @override
  String toString() => 'AnimationActivity($describe)';

  @override
  bool operator ==(Object other) =>
      other is AnimationActivity &&
      other.owner == owner &&
      other.routeIndex == routeIndex &&
      other.label == label &&
      _sameIds(other.elementPath, elementPath);

  @override
  int get hashCode => Object.hash(owner, routeIndex, label, elementPath.length);

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
