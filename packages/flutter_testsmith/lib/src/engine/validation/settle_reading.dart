import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'quiescence.dart';

/// One reading of what a screen is doing, as the application reported it.
///
/// The engine's view of `ext.mytest.settle`. The SDK has its own class
/// for the same payload; this one exists because the engine must never
/// link Flutter, and because the *decision* belongs out here anyway -
/// the application says what is moving, the test configuration says what
/// is acceptable.
@immutable
final class SettleReading {
  const SettleReading({
    required this.sinceLastFrame,
    required this.inFlightRequests,
    required this.transientCallbacks,
    required this.quietPeriod,
    this.animations = const [],
    this.topRouteIndex,
  });

  final Duration sinceLastFrame;
  final int inFlightRequests;

  /// Flutter's own count of running animations.
  ///
  /// Kept alongside [animations] rather than replaced by it, and the
  /// two are cross-checked. See [unattributed].
  final int transientCallbacks;

  final Duration quietPeriod;

  /// Which animations are running, named.
  final List<AnimationActivity> animations;

  /// The topmost route, so animations behind it can be discounted.
  final int? topRouteIndex;

  /// Animations Flutter counted that the inventory could not name.
  ///
  /// Should always be zero: a widget-driven animation runs on a ticker
  /// the inspector can find, and `animation_inventory_test.dart`
  /// measures that the two numbers agree. It is carried anyway, because
  /// the one thing a declared exception must never do is let an
  /// unnamed animation through - a frame callback scheduled directly on
  /// the binding, or an SDK too old to send an inventory at all, would
  /// otherwise look like a quiet screen.
  int get unattributed {
    final difference = transientCallbacks - animations.length;
    return difference > 0 ? difference : 0;
  }

  /// What this reading means for a screen with [policy].
  QuiescenceVerdict against(QuiescencePolicy policy) =>
      const QuiescenceEvaluator().evaluate(
        animations: animations,
        policy: policy,
        inFlightRequests: inFlightRequests,
        sinceLastFrame: sinceLastFrame,
        quietPeriod: quietPeriod,
        topRouteIndex: topRouteIndex,
        unattributed: unattributed,
      );

  factory SettleReading.fromJson(Map<String, Object?> json) => SettleReading(
        sinceLastFrame: Duration(
          milliseconds: (json['sinceLastFrameMs'] as num?)?.toInt() ?? 0,
        ),
        inFlightRequests: (json['inFlightRequests'] as num?)?.toInt() ?? 0,
        transientCallbacks: (json['transientCallbacks'] as num?)?.toInt() ?? 0,
        quietPeriod: Duration(
          milliseconds: (json['quietPeriodMs'] as num?)?.toInt() ?? 0,
        ),
        animations: [
          for (final animation in (json['animations'] as List?) ?? const [])
            AnimationActivity.fromJson(
              (animation as Map).cast<String, Object?>(),
            ),
        ],
        topRouteIndex: (json['topRouteIndex'] as num?)?.toInt(),
      );

  @override
  String toString() => 'SettleReading(${animations.length} animations, '
      '$inFlightRequests in flight)';
}
