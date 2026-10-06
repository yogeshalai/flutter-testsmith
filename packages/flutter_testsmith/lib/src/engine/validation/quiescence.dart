import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// One animation a screen says it expects to run for ever.
///
/// Both fields are required, and that is the design rather than an
/// oversight. The element makes the exception **specific**: introduce a
/// second animation tomorrow and it is still unexpected, which is the
/// whole difference between this and a flag that says "ignore
/// animations here". The reason makes it **auditable**: a report that
/// says pixels were excluded should say who decided that and why, and
/// a declaration that is tedious to write is one nobody adds casually.
@immutable
final class PermittedAnimation {
  const PermittedAnimation({
    required this.element,
    required this.reason,
    this.widget,
    this.count,
  });

  /// The semantic id enclosing the animation.
  final String element;

  /// Only animations owned by this widget type, when given.
  ///
  /// The answer to a list. A dashboard draws a looping discount badge on
  /// every outlet card that has an offer, so there is no id that names
  /// one of them - putting the same id on each would make it ambiguous
  /// for every other check. Naming the *kind* keeps the exception
  /// specific without inventing an id per row: `Lottie` inside
  /// `home.body` is permitted, and a shimmer appearing there tomorrow
  /// still blocks.
  final String? widget;

  /// How many of them there are, when the author knows.
  ///
  /// `element` is only as tight as the id it names and `widget` narrows
  /// the kind but not the place, so a second `Lottie` added anywhere
  /// inside the declared element would be permitted without anyone
  /// noticing. That was recorded as a limitation of STOP-2 and this is
  /// what closes it.
  ///
  /// It is only defensible because the data is now a committed fixture
  /// rather than whatever the backend held this morning: two outlet
  /// cards carry an offer, so exactly two badges loop. A run against
  /// live data should leave it out, and then nothing changes.
  final int? count;

  /// Why it is expected to run for ever, in the author's words.
  final String reason;

  /// Whether this declaration covers [activity].
  bool covers(AnimationActivity activity) =>
      activity.elementPath.contains(element) &&
      (widget == null || activity.owner == widget);

  /// How the report refers to this declaration.
  String get label => widget == null ? element : '$widget in $element';

  /// What this declaration permits, for a message about miscounting.
  String get subject => widget == null ? 'animation' : '$widget animation';

  @override
  bool operator ==(Object other) =>
      other is PermittedAnimation &&
      other.element == element &&
      other.widget == widget &&
      other.count == count &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(element, widget, count, reason);

  @override
  String toString() => 'PermittedAnimation($label: $reason)';
}

/// What a screen declares about its perpetual animations.
///
/// Empty for every screen that does not mention quiescence, which is
/// why adding this changed nothing for the screens that already worked.
@immutable
final class QuiescencePolicy {
  const QuiescencePolicy({this.allow = const []});

  /// Declares nothing. Any animation at all blocks, as it always did.
  static const QuiescencePolicy none = QuiescencePolicy();

  /// The keys a `quiescence:` block may carry.
  static const Set<String> quiescenceKeys = {'allow'};

  /// The keys one `allow:` entry may carry.
  static const Set<String> allowKeys = {'element', 'widget', 'count', 'reason'};

  /// Reads a `quiescence:` block.
  ///
  /// The one parser for this block, shared by every file format that
  /// carries one. A second implementation would be a second dialect, and
  /// the two would drift on the first refusal one of them forgot.
  ///
  /// [bad] raises the caller's own format exception, so a mappings file
  /// and an auth file each report in their own words while agreeing
  /// exactly on what is legal.
  static QuiescencePolicy parse(
    Object? node, {
    required Never Function(String message) bad,
  }) {
    if (node == null) return QuiescencePolicy.none;
    if (node is! Map) {
      bad('"quiescence" must be a mapping with an "allow" list');
    }

    final raw = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );
    for (final key in raw.keys) {
      if (!quiescenceKeys.contains(key)) {
        bad('unknown quiescence key "$key". '
            'Known: ${quiescenceKeys.join(', ')}.');
      }
    }

    final allow = raw['allow'];
    if (allow == null) return QuiescencePolicy.none;
    if (allow is! List) bad('"allow" must be a list');

    final entries = <PermittedAnimation>[];
    final seen = <String>{};

    for (final item in allow) {
      if (item is! Map) {
        bad('each "allow" entry must be a mapping with an "element" and a '
            '"reason"');
      }
      final entry = item.cast<Object?, Object?>().map(
            (key, value) => MapEntry(key.toString(), value),
          );
      for (final key in entry.keys) {
        if (!allowKeys.contains(key)) {
          bad('unknown allow key "$key". Known: ${allowKeys.join(', ')}.');
        }
      }

      final element = entry['element'];
      if (element is! String || element.trim().isEmpty) {
        bad('an "element" is required on every "allow" entry: name the '
            'semantic id of the element that animates');
      }
      // The exception has to be specific, or it is the blanket flag under
      // another name: a pattern matching everything would excuse an
      // animation introduced next month without anyone noticing.
      if (element.contains('*')) {
        bad('"allow" must name one element, not a pattern - "$element" '
            'would excuse animations nobody has written yet');
      }

      final reason = entry['reason'];
      if (reason is! String || reason.trim().isEmpty) {
        bad('a "reason" is required on "$element": the report says which '
            'pixels were excluded from comparison and why, and this is the '
            'why');
      }

      final widget = entry['widget'];
      if (widget != null && (widget is! String || widget.trim().isEmpty)) {
        bad('"widget" on "$element" must be a widget type name, such as '
            '"Lottie" or "Shimmer"');
      }
      final narrowed = (widget as String?)?.trim();

      final rawCount = entry['count'];
      int? count;
      if (rawCount != null) {
        if (rawCount is! int || rawCount < 1) {
          bad('"count" on "$element" must be a whole number of animations, '
              'one or more - not "$rawCount". To forbid a widget entirely, '
              'leave the declaration out; that is what no declaration '
              'already means');
        }
        count = rawCount;
      }

      if (!seen.add('$element/${narrowed ?? ''}')) {
        bad('"$element"${narrowed == null ? '' : ' ($narrowed)'} is declared '
            'twice under "quiescence: allow"');
      }

      entries.add(
        PermittedAnimation(
          element: element,
          widget: narrowed,
          count: count,
          reason: reason.trim(),
        ),
      );
    }

    return QuiescencePolicy(allow: entries);
  }


  final List<PermittedAnimation> allow;

  bool get isEmpty => allow.isEmpty;

  /// The declaration covering [activity], or null if none does.
  ///
  /// Matches against every semantic id enclosing the animation rather
  /// than only the nearest, so an author may name any honest ancestor
  /// instead of guessing which id the platform considers closest. It is
  /// still a named element either way.
  PermittedAnimation? covering(AnimationActivity activity) {
    for (final entry in allow) {
      if (entry.covers(activity)) return entry;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is QuiescencePolicy &&
      other.allow.length == allow.length &&
      List.generate(allow.length, (i) => other.allow[i] == allow[i])
          .every((same) => same);

  @override
  int get hashCode => Object.hashAll(allow);

  @override
  String toString() => 'QuiescencePolicy(${allow.length} permitted)';
}

/// An animation that ran, and the declaration that allowed it to.
@immutable
final class PermittedActivity {
  const PermittedActivity(this.activity, this.declaration);

  final AnimationActivity activity;
  final PermittedAnimation declaration;

  String get elementId => declaration.element;
  String get reason => declaration.reason;
  String get owner => activity.owner;

  /// The pixels this animation actually occupies.
  LogicalRect? get bounds => activity.bounds;

  @override
  String toString() => '$owner in "$elementId" ($reason)';
}

/// Whether a screen is ready to be validated.
///
/// Sealed, because "settled" and "settled except for two declared
/// animations" are different enough that a report must be able to say
/// which - and a caller must not be able to read a bool and skip past
/// the distinction.
@immutable
sealed class QuiescenceVerdict {
  const QuiescenceVerdict({
    required this.permitted,
    required this.unexpected,
    required this.belowTopRoute,
    required this.unusedDeclarations,
    required this.blockers,
  });

  /// Animations that ran and were declared.
  final List<PermittedActivity> permitted;

  /// Animations that ran and were not.
  final List<AnimationActivity> unexpected;

  /// Animations belonging to a screen underneath this one.
  ///
  /// Reported rather than dropped: "ignored 1 animation on the screen
  /// behind" is information, and silently discarding it would make a
  /// wrong route attribution invisible.
  final List<AnimationActivity> belowTopRoute;

  /// Declared elements that were not animating.
  ///
  /// Dead configuration, worth saying out loud - a carousel with one
  /// banner does not animate - but not fatal, because erroring would
  /// make the run depend on how much data a fixture happens to hold.
  final List<String> unusedDeclarations;

  /// Every reason this screen is not ready. Empty when it is.
  final List<String> blockers;

  bool get isSettled => this is QuiescenceSettled;

  /// The declarations that were actually used, for the report.
  List<String> get excludedElements {
    final seen = <String>{};
    return [
      for (final entry in permitted)
        if (seen.add(entry.elementId)) entry.elementId,
    ];
  }

  /// The pixels that must be excluded from visual comparison.
  ///
  /// A permitted animation is, by definition, different in every frame.
  /// Comparing its pixels against a baseline would fail at random, so
  /// they come out - and the report says how many and how much, because
  /// an exclusion nobody mentions is a hole in the check.
  ///
  /// **The animation's own box, not the declared element's.** Measured:
  /// the two looping badges on a real dashboard are 33x33 each, inside
  /// a scroll body that fills the screen. Excluding what was declared
  /// would have blanked the whole screen to hide 0.2% of it; excluding
  /// what actually moves costs almost nothing.
  List<LogicalRect> get excludedRegions => [
        for (final entry in permitted)
          if (entry.bounds != null) entry.bounds!,
      ];

  /// Permitted animations whose position is unknown.
  ///
  /// Their pixels cannot be excluded, so a comparison including them
  /// would pass or fail at random. A caller that is about to photograph
  /// the screen should decline rather than record that.
  List<PermittedActivity> get unlocatable => [
        for (final entry in permitted)
          if (entry.bounds == null) entry,
      ];

  /// How many animations this verdict actually looked at.
  int get consideredCount => permitted.length + unexpected.length;

  /// The report block for this screen, one line at a time.
  ///
  /// See STOP-2, Reporting.
  List<String> describeLines() {
    final lines = <String>[
      '$consideredCount animation${consideredCount == 1 ? '' : 's'} ticking',
      '${permitted.length} permitted',
      '${unexpected.length} unexpected',
    ];
    for (final entry in permitted) {
      final where = entry.bounds == null
          ? ' (position unknown)'
          : ' at ${entry.bounds!.x.round()},${entry.bounds!.y.round()} '
              '${entry.bounds!.width.round()}x${entry.bounds!.height.round()}';
      lines.add('  permitted: ${entry.owner} in "${entry.elementId}"$where '
          '- ${entry.reason}');
    }
    for (final entry in unexpected) {
      lines.add('  unexpected: ${entry.describe}');
    }
    if (belowTopRoute.isNotEmpty) {
      lines.add('  ${belowTopRoute.length} ignored on the screen underneath');
    }
    for (final unused in unusedDeclarations) {
      lines.add('  declared but not animating: "$unused"');
    }
    return lines;
  }

  /// The same block as one string.
  String describe() => describeLines().join('\n');
}

/// Ready to validate: nothing is moving that was not declared.
final class QuiescenceSettled extends QuiescenceVerdict {
  const QuiescenceSettled({
    super.permitted = const [],
    super.belowTopRoute = const [],
    super.unusedDeclarations = const [],
  }) : super(unexpected: const [], blockers: const []);
}

/// Not ready, and here is everything that is in the way.
final class QuiescenceBlocked extends QuiescenceVerdict {
  const QuiescenceBlocked({
    required super.blockers,
    super.permitted = const [],
    super.unexpected = const [],
    super.belowTopRoute = const [],
    super.unusedDeclarations = const [],
  });
}

/// Decides whether a screen has stopped changing.
///
/// Lives in the engine rather than the SDK on purpose. The application
/// under test reports what is ticking; what is *acceptable* is a
/// property of the test configuration, so it is decided out here where
/// every other verdict is decided, and changing a declaration needs no
/// rebuild of the application.
///
/// Every rule below is a comparison. Nothing here samples a clock to
/// guess at stability, and nothing consults a model.
class QuiescenceEvaluator {
  const QuiescenceEvaluator();

  QuiescenceVerdict evaluate({
    required List<AnimationActivity> animations,
    required QuiescencePolicy policy,
    required int inFlightRequests,
    required Duration sinceLastFrame,
    required Duration quietPeriod,
    int? topRouteIndex,
    int unattributed = 0,
  }) {
    final below = <AnimationActivity>[];
    final unexpected = <AnimationActivity>[];

    // Grouped by declaration rather than classified one at a time,
    // because a declared `count` is a claim about the whole group and
    // cannot be checked an animation at a time.
    final matched = <PermittedAnimation, List<AnimationActivity>>{
      for (final entry in policy.allow) entry: <AnimationActivity>[],
    };

    for (final activity in animations) {
      // A screen underneath is not this screen. Flutter mutes tickers
      // beneath an *opaque* route on its own, so this only ever fires
      // under a transparent one - a dialog over an animating dashboard.
      //
      // An animation whose route is unknown is NOT excused: not knowing
      // where something is is not a reason to ignore it.
      if (topRouteIndex != null &&
          activity.routeIndex != null &&
          activity.routeIndex != topRouteIndex) {
        below.add(activity);
        continue;
      }

      final declaration = policy.covering(activity);
      if (declaration == null) {
        unexpected.add(activity);
      } else {
        matched[declaration]!.add(activity);
      }
    }

    final permitted = <PermittedActivity>[];
    final miscounted = <String>[];
    final unused = <String>[];

    for (final entry in policy.allow) {
      final group = matched[entry]!;
      final wanted = entry.count;

      if (wanted == null) {
        // Unchanged behaviour: a declaration with no count permits
        // whatever it matches, and matching nothing is dead
        // configuration rather than a failure.
        permitted.addAll([
          for (final activity in group) PermittedActivity(activity, entry),
        ]);
        if (group.isEmpty) unused.add(entry.element);
        continue;
      }

      if (group.length == wanted) {
        permitted.addAll([
          for (final activity in group) PermittedActivity(activity, entry),
        ]);
        continue;
      }

      // Not "the surplus one is unexpected": nothing says which of the
      // three is the extra. A declared count is a claim about the whole
      // group, so when it does not hold, none of the pixels it covers
      // can be excluded on its authority - and all of them are named,
      // with their bounds, so a reader can see which is the newcomer.
      unexpected.addAll(group);
      miscounted.add(
        '"${entry.element}" declares $wanted ${entry.subject}'
        '${wanted == 1 ? '' : 's'} and ${group.length} '
        '${group.length == 1 ? 'is' : 'are'} running. A declared count is '
        'exact, so none of them is permitted until either the screen or '
        'the declaration changes',
      );
    }

    final blockers = <String>[
      ...miscounted,
      if (unexpected.isNotEmpty) _describeUnexpected(unexpected),
      // Flutter counted more animations than the inventory could name.
      // Never observed in a measured case - the two agree exactly - but
      // it is the one hole a declared exception must not have: an
      // animation nobody can see is an animation nobody can declare,
      // and letting it pass would turn this feature back into the
      // blanket flag it exists to avoid.
      if (unattributed > 0)
        '$unattributed animation${unattributed == 1 ? '' : 's'} running that '
            'the application could not name. Nothing can be declared for '
            'it, so it still blocks. Either the SDK predates animation '
            'reporting, or a frame callback was scheduled outside a '
            'Ticker',
      if (inFlightRequests > 0)
        '$inFlightRequests request${inFlightRequests == 1 ? '' : 's'} '
            'still in flight',
      // The quiet period is the original mechanism and is kept exactly
      // as it was - except when an animation has been declared, and
      // then it cannot apply: a permitted animation renders a frame
      // every 16ms, so waiting for quiet is waiting for ever. Waiting
      // for ever is what this milestone exists to end.
      //
      // Nothing is loosened by that. The frames are expected *because
      // they were declared*, and their pixels are excluded from the
      // comparison for the same reason.
      if (permitted.isEmpty && sinceLastFrame < quietPeriod)
        'frames still rendering (last was '
            '${sinceLastFrame.inMilliseconds}ms ago, need '
            '${quietPeriod.inMilliseconds}ms of quiet)',
    ];

    if (blockers.isEmpty) {
      return QuiescenceSettled(
        permitted: permitted,
        belowTopRoute: below,
        unusedDeclarations: unused,
      );
    }

    return QuiescenceBlocked(
      blockers: blockers,
      permitted: permitted,
      unexpected: unexpected,
      belowTopRoute: below,
      unusedDeclarations: unused,
    );
  }

  /// One line naming every animation that is not accounted for.
  ///
  /// Names the widget and the id, because "2 animations running" is
  /// what made this unfixable for a fortnight. An animation with no
  /// enclosing id is called out separately: it cannot be declared until
  /// somebody gives it a name, and that is the actual next action.
  String _describeUnexpected(List<AnimationActivity> unexpected) {
    final described = unexpected.map((a) => a.describe).join(', ');
    final anonymous = unexpected.any((a) => a.elementId == null);

    return '${unexpected.length} unexpected '
        'animation${unexpected.length == 1 ? '' : 's'} running: $described. '
        '${anonymous ? 'An animation with no semantic id cannot be declared '
            '- wrap it in a TestId first. ' : ''}'
        'If it is meant to run for ever, declare it under "quiescence: '
        'allow:" for this screen.';
  }
}
