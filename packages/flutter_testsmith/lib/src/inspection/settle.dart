import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// Whether a screen has stopped changing, and if not, what is still
/// moving.
///
/// Capturing before a screen settles produces a snapshot of a
/// transition: measured on a device, a tree taken two seconds after a
/// tap contained *both* screens, the outgoing one at negative x. Nothing
/// was wrong with the capture - the screen really was in that state -
/// but validating against it would compare a composite that matches no
/// design. See risk R4b.
///
/// This is a heuristic, never a `sleep`. A timeout names every condition
/// that never became true, because "not settled" alone sends the author
/// guessing.
@immutable
class SettleState {
  const SettleState({
    required this.sinceLastFrame,
    required this.inFlightRequests,
    required this.transientCallbacks,
    required this.quietPeriod,
    this.animations = const [],
    this.topRouteIndex,
  });

  /// How long since the last frame was rendered.
  final Duration sinceLastFrame;

  /// Requests issued and not yet answered.
  final int inFlightRequests;

  /// Running animations, as scheduled transient frame callbacks.
  final int transientCallbacks;

  /// How long the UI must be quiet before it counts as settled.
  final Duration quietPeriod;

  /// Which animations are running, not merely how many.
  ///
  /// Reported, never judged. Whether a running animation is acceptable
  /// depends on what the screen declared, and declarations live with
  /// the tests rather than inside the application - so the SDK hands
  /// over the inventory and the engine decides. See STOP-2.
  final List<AnimationActivity> animations;

  /// The topmost route, so the engine can ignore what is behind it.
  final int? topRouteIndex;

  bool get isSettled => blockers.isEmpty;

  /// Every reason this screen is not ready, not just the first.
  List<String> get blockers => [
        if (sinceLastFrame < quietPeriod)
          'frames still rendering (last was '
              '${sinceLastFrame.inMilliseconds}ms ago, need '
              '${quietPeriod.inMilliseconds}ms of quiet)',
        if (inFlightRequests > 0)
          '$inFlightRequests request${inFlightRequests == 1 ? '' : 's'} '
              'still in flight',
        if (transientCallbacks > 0)
          '$transientCallbacks animation'
              '${transientCallbacks == 1 ? '' : 's'} running',
      ];

  Map<String, Object?> toJson() => {
        'sinceLastFrameMs': sinceLastFrame.inMilliseconds,
        'inFlightRequests': inFlightRequests,
        'transientCallbacks': transientCallbacks,
        'quietPeriodMs': quietPeriod.inMilliseconds,
        'isSettled': isSettled,
        'blockers': blockers,
        if (animations.isNotEmpty)
          'animations': [for (final a in animations) a.toJson()],
        if (topRouteIndex != null) 'topRouteIndex': topRouteIndex,
      };

  factory SettleState.fromJson(Map<String, Object?> json) => SettleState(
        sinceLastFrame:
            Duration(milliseconds: (json['sinceLastFrameMs']! as num).toInt()),
        inFlightRequests: (json['inFlightRequests']! as num).toInt(),
        transientCallbacks: (json['transientCallbacks']! as num).toInt(),
        quietPeriod:
            Duration(milliseconds: (json['quietPeriodMs']! as num).toInt()),
        // Absent from an older SDK, which reported a count and nothing
        // else. An empty inventory then means "cannot say", and the
        // engine treats an undeclarable animation as unexpected.
        animations: [
          for (final a in (json['animations'] as List?) ?? const [])
            AnimationActivity.fromJson((a as Map).cast<String, Object?>()),
        ],
        topRouteIndex: (json['topRouteIndex'] as num?)?.toInt(),
      );

  @override
  String toString() => isSettled
      ? 'SettleState(settled)'
      : 'SettleState(${blockers.join('; ')})';
}
