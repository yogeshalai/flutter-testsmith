import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// A screen that animates for ever is not a screen that is broken.
///
/// A measured dashboard draws a looping discount badge on every outlet
/// card that has an offer, so `waitForSettle` never returned and visual
/// comparison was never even attempted. The answer is not
/// `ignoreAnimations: true` - that would hide a genuine animation defect
/// the day someone introduced one. It is a **declared exception**: the
/// screen names the animations it expects, and anything else still
/// blocks.
///
/// The distinction that matters most is in case 3. Three of the four
/// animations measured on that application are *loading* indicators, and
/// those must stay unexpected: excusing a spinner would make a screen
/// that never finishes loading look settled.
///
/// Every case below is deterministic. Nothing here consults a clock
/// beyond the quiet period the architecture already had, and nothing
/// consults a model.

const Duration _quiet = Duration(milliseconds: 500);
const Duration _longAgo = Duration(seconds: 5);

AnimationActivity ticking({
  String owner = 'Widget',
  List<String> path = const [],
  int? routeIndex,
  String? label,
  LogicalRect? bounds = const LogicalRect(x: 4, y: 8, width: 33, height: 33),
}) =>
    AnimationActivity(
      owner: owner,
      elementPath: path,
      routeIndex: routeIndex,
      label: label,
      bounds: bounds,
    );

QuiescenceVerdict evaluate(
  List<AnimationActivity> animations, {
  QuiescencePolicy policy = QuiescencePolicy.none,
  int inFlight = 0,
  Duration sinceLastFrame = _longAgo,
  int? topRouteIndex,
}) =>
    const QuiescenceEvaluator().evaluate(
      animations: animations,
      policy: policy,
      inFlightRequests: inFlight,
      sinceLastFrame: sinceLastFrame,
      quietPeriod: _quiet,
      topRouteIndex: topRouteIndex,
    );

QuiescencePolicy policyOf(String yaml) => MappingsFile.parse(
      'screen: /home\n$yaml',
      source: 'test.yaml',
    ).quiescence;

void main() {
  group('1. a screen with no animations', () {
    test('is settled', () {
      final verdict = evaluate(const []);

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.permitted, isEmpty);
      expect(verdict.unexpected, isEmpty);
    });

    test('is still blocked by an in-flight request', () {
      final verdict = evaluate(const [], inFlight: 2);

      expect(verdict, isA<QuiescenceBlocked>());
      expect(verdict.blockers.single, contains('2 requests still in flight'));
    });

    test('is still blocked while frames are rendering', () {
      // Unchanged behaviour: with nothing declared and nothing ticking,
      // a repainting screen is not ready to photograph.
      final verdict = evaluate(
        const [],
        sinceLastFrame: const Duration(milliseconds: 16),
      );

      expect(verdict, isA<QuiescenceBlocked>());
      expect(verdict.blockers.single, contains('frames still rendering'));
    });
  });

  group('2. a finite animation that settles', () {
    test('blocks while it runs', () {
      final verdict = evaluate([
        ticking(owner: 'FadeTransition', path: ['home.hero']),
      ]);

      expect(verdict, isA<QuiescenceBlocked>());
      expect(verdict.unexpected, hasLength(1));
    });

    test('settles the moment it stops, with no declaration needed', () {
      // The SDK reports only tickers that are actually ticking, so a
      // finished animation simply stops appearing.
      expect(evaluate(const []), isA<QuiescenceSettled>());
    });
  });

  group('3. a perpetual animation with no declaration', () {
    test('is not settled, and the reason names the widget', () {
      final verdict = evaluate([
        ticking(owner: 'AppMarqueeText', path: ['home.offer_strip']),
      ]);

      expect(verdict, isA<QuiescenceBlocked>());
      expect(verdict.blockers.single, contains('AppMarqueeText'));
      expect(verdict.blockers.single, contains('home.offer_strip'));
    });

    test('says how to declare it, rather than only that it is stuck', () {
      final verdict = evaluate([
        ticking(owner: 'AppMarqueeText', path: ['home.offer_strip']),
      ]);

      expect(verdict.blockers.single, contains('quiescence'));
    });

    test('an animation with no semantic id at all asks for one', () {
      final verdict = evaluate([ticking(owner: 'Shimmer')]);

      expect(verdict, isA<QuiescenceBlocked>());
      expect(
        verdict.blockers.single,
        contains('no semantic id'),
        reason: 'it cannot be declared until it can be named',
      );
    });
  });

  group('4. a declared perpetual animation', () {
    final policy = policyOf('''
quiescence:
  allow:
    - element: home.offer_strip
      reason: the offer text scrolls continuously
''');

    test('is settled', () {
      final verdict = evaluate(
        [ticking(owner: 'AppMarqueeText', path: ['home.offer_strip'])],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.permitted, hasLength(1));
      expect(verdict.permitted.single.elementId, 'home.offer_strip');
    });

    test('matches on any semantic ancestor, not only the nearest', () {
      final verdict = evaluate(
        [
          ticking(
            owner: 'AppMarqueeText',
            path: ['home.offer_strip', 'home.offer_strip.text'],
          ),
        ],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceSettled>());
    });

    test('does not suppress an in-flight request', () {
      // Permitting an animation says nothing about loading.
      final verdict = evaluate(
        [ticking(owner: 'AppMarqueeText', path: ['home.offer_strip'])],
        policy: policy,
        inFlight: 1,
      );

      expect(verdict, isA<QuiescenceBlocked>());
      expect(verdict.blockers.single, contains('1 request still in flight'));
    });

    test('stops the frame-quiet period from blocking for ever', () {
      // The point of the milestone. A permitted animation renders a
      // frame every 16ms, so the quiet period can never elapse - and
      // waiting for it is what made these screens unvalidatable.
      final verdict = evaluate(
        [ticking(owner: 'AppMarqueeText', path: ['home.offer_strip'])],
        policy: policy,
        sinceLastFrame: const Duration(milliseconds: 16),
      );

      expect(verdict, isA<QuiescenceSettled>());
    });

    test('carries the declared reason into the verdict', () {
      final verdict = evaluate(
        [ticking(owner: 'AppMarqueeText', path: ['home.offer_strip'])],
        policy: policy,
      );

      expect(
        (verdict as QuiescenceSettled).permitted.single.reason,
        'the offer text scrolls continuously',
      );
    });
  });

  group('5. a declared animation plus an unexpected one', () {
    final policy = policyOf('''
quiescence:
  allow:
    - element: home.offer_strip
      reason: the offer text scrolls continuously
''');

    test('is not settled', () {
      final verdict = evaluate(
        [
          ticking(owner: 'AppMarqueeText', path: ['home.offer_strip']),
          ticking(owner: 'Shimmer', path: ['home.product_rail']),
        ],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceBlocked>());
    });

    test('names only the unexpected one', () {
      final verdict = evaluate(
        [
          ticking(owner: 'AppMarqueeText', path: ['home.offer_strip']),
          ticking(owner: 'Shimmer', path: ['home.product_rail']),
        ],
        policy: policy,
      );

      expect(verdict.unexpected, hasLength(1));
      expect(verdict.unexpected.single.owner, 'Shimmer');
      expect(verdict.blockers.single, contains('home.product_rail'));
      expect(verdict.blockers.single, isNot(contains('home.offer_strip')));
    });

    test('still reports the permitted one, so nothing is hidden', () {
      final verdict = evaluate(
        [
          ticking(owner: 'AppMarqueeText', path: ['home.offer_strip']),
          ticking(owner: 'Shimmer', path: ['home.product_rail']),
        ],
        policy: policy,
      );

      expect(verdict.permitted, hasLength(1));
    });
  });

  group('6. an invalid declaration is an error, never a silent permit', () {
    void rejects(String yaml, Matcher message) {
      expect(
        () => policyOf(yaml),
        throwsA(
          isA<MappingsFormatException>()
              .having((e) => e.message, 'message', message),
        ),
      );
    }

    test('an unknown key under quiescence', () {
      rejects('''
quiescence:
  ignoreAnimations: true
''', contains('ignoreAnimations'));
    });

    test('allow must be a list', () {
      rejects('''
quiescence:
  allow: home.offer_strip
''', contains('"allow" must be a list'));
    });

    test('an entry with no element', () {
      rejects('''
quiescence:
  allow:
    - reason: it scrolls
''', contains('"element" is required'));
    });

    test('an entry with no reason', () {
      // A reason is required so that the report can say *why* pixels
      // were excluded, and so that "allow everything" is tedious to
      // write rather than convenient.
      rejects('''
quiescence:
  allow:
    - element: home.offer_strip
''', contains('"reason" is required'));
    });

    test('an empty reason', () {
      rejects('''
quiescence:
  allow:
    - element: home.offer_strip
      reason: "  "
''', contains('"reason" is required'));
    });

    test('the same element declared twice', () {
      rejects('''
quiescence:
  allow:
    - element: home.offer_strip
      reason: one
    - element: home.offer_strip
      reason: two
''', contains('declared twice'));
    });

    test('a wildcard element', () {
      // The whole point is specificity. A pattern that matches
      // everything is the flag this milestone exists to refuse.
      rejects('''
quiescence:
  allow:
    - element: "*"
      reason: everything
''', contains('name one element'));
    });

    test('quiescence itself must be a mapping', () {
      rejects('quiescence: true', contains('must be a mapping'));
    });
  });

  group('7. several declared perpetual animations', () {
    final policy = policyOf('''
quiescence:
  allow:
    - element: home.offer_strip
      reason: the offer text scrolls continuously
    - element: home.banner_carousel
      reason: the promotional banner advances on a timer
''');

    test('all of them settle', () {
      final verdict = evaluate(
        [
          ticking(owner: 'AppMarqueeText', path: ['home.offer_strip']),
          ticking(owner: 'CarouselSlider', path: ['home.banner_carousel']),
        ],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.permitted, hasLength(2));
    });

    test('two tickers under one declaration are both permitted', () {
      final verdict = evaluate(
        [
          ticking(owner: 'FadeTransition', path: ['home.banner_carousel']),
          ticking(owner: 'PageView', path: ['home.banner_carousel']),
        ],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.permitted, hasLength(2));
    });

    test('a declaration that matched nothing is reported, not fatal', () {
      // Dead configuration is worth saying out loud - a carousel with
      // one banner does not animate - but erroring would make the run
      // depend on how much data the fixture happens to hold.
      final verdict = evaluate(
        [ticking(owner: 'AppMarqueeText', path: ['home.offer_strip'])],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.unusedDeclarations, ['home.banner_carousel']);
    });
  });

  group('8. an animation underneath the current route', () {
    test('does not count towards this screen\'s quiescence', () {
      // A dialog over an animating dashboard: Flutter mutes tickers
      // under an *opaque* route, but not under a transparent one.
      final verdict = evaluate(
        [ticking(owner: 'AppMarqueeText', path: ['home.offer_strip'], routeIndex: 0)],
        topRouteIndex: 1,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.unexpected, isEmpty);
    });

    test('is reported as ignored rather than dropped silently', () {
      final verdict = evaluate(
        [ticking(owner: 'AppMarqueeText', path: ['home.offer_strip'], routeIndex: 0)],
        topRouteIndex: 1,
      );

      expect(verdict.belowTopRoute, hasLength(1));
    });

    test('an animation on the current route still counts', () {
      final verdict = evaluate(
        [ticking(owner: 'Shimmer', path: ['dialog.spinner'], routeIndex: 1)],
        topRouteIndex: 1,
      );

      expect(verdict, isA<QuiescenceBlocked>());
    });

    test('an unknown route index counts, rather than being excused', () {
      // Not knowing where something is is not a reason to ignore it.
      final verdict = evaluate(
        [ticking(owner: 'Shimmer', path: ['home.rail'])],
        topRouteIndex: 1,
      );

      expect(verdict, isA<QuiescenceBlocked>());
    });

    test('a declaration does not reach under the top route either', () {
      // Permitting is scoped the same way: the entry applies to the
      // screen being validated, not to whatever is behind it.
      final verdict = evaluate(
        [ticking(owner: 'Shimmer', path: ['home.rail'], routeIndex: 0)],
        policy: policyOf('''
quiescence:
  allow:
    - element: home.rail
      reason: it shimmers
'''),
        topRouteIndex: 1,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.permitted, isEmpty, reason: 'it was not on this screen');
      expect(verdict.belowTopRoute, hasLength(1));
    });
  });

  group('9. what a permitted animation costs the visual comparison', () {
    final policy = policyOf('''
quiescence:
  allow:
    - element: home.offer_strip
      reason: the offer text scrolls continuously
''');

    test('its pixels are excluded, because they change every frame', () {
      final verdict = evaluate(
        [ticking(owner: 'AppMarqueeText', path: ['home.offer_strip'])],
        policy: policy,
      );

      expect(verdict.excludedElements, ['home.offer_strip']);
    });

    test('a screen with nothing permitted excludes nothing', () {
      expect(evaluate(const []).excludedElements, isEmpty);
    });

    test('the exclusions reach the visual configuration', () {
      final config = VisualCheckConfig.defaults.excluding(['home.offer_strip']);

      expect(config.ignoreElements, contains('home.offer_strip'));
    });

    test('exclusions add to whatever the screen already ignored', () {
      const base = VisualCheckConfig(ignoreElements: ['home.clock']);
      final config = base.excluding(['home.offer_strip']);

      expect(config.ignoreElements, ['home.clock', 'home.offer_strip']);
    });

    test('an element excluded twice is excluded once', () {
      const base = VisualCheckConfig(ignoreElements: ['home.offer_strip']);
      final config = base.excluding(['home.offer_strip']);

      expect(config.ignoreElements, ['home.offer_strip']);
    });
  });

  group('narrowing a declaration to one kind of widget', () {
    // The answer to a data-driven list. A dashboard draws a looping
    // badge on every outlet card that has an offer, so no id names one
    // of them - putting the same id on each would make it ambiguous for
    // every other check. Naming the kind keeps the exception specific.
    final policy = policyOf('''
quiescence:
  allow:
    - element: home.body
      widget: Lottie
      reason: the discount badge on an outlet card loops
''');

    test('permits that widget inside that element', () {
      final verdict = evaluate(
        [
          ticking(owner: 'Lottie', path: ['home.body']),
          ticking(owner: 'Lottie', path: ['home.body']),
        ],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.permitted, hasLength(2));
    });

    test('still blocks a different widget in the same element', () {
      // The whole point of narrowing: a shimmer appearing inside the
      // dashboard tomorrow is still news.
      final verdict = evaluate(
        [
          ticking(owner: 'Lottie', path: ['home.body']),
          ticking(owner: 'Shimmer', path: ['home.body']),
        ],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceBlocked>());
      expect(verdict.unexpected.single.owner, 'Shimmer');
    });

    test('still blocks the same widget somewhere else', () {
      final verdict = evaluate(
        [ticking(owner: 'Lottie', path: ['home.footer'])],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceBlocked>());
    });

    test('one element may permit two kinds separately', () {
      final both = policyOf('''
quiescence:
  allow:
    - element: home.body
      widget: Lottie
      reason: the discount badge loops
    - element: home.body
      widget: CarouselSlider
      reason: the banner advances on a timer
''');

      expect(both.allow, hasLength(2));
      expect(
        evaluate(
          [
            ticking(owner: 'Lottie', path: ['home.body']),
            ticking(owner: 'CarouselSlider', path: ['home.body']),
          ],
          policy: both,
        ),
        isA<QuiescenceSettled>(),
      );
    });

    test('the same element and widget twice is still a duplicate', () {
      expect(
        () => policyOf('''
quiescence:
  allow:
    - element: home.body
      widget: Lottie
      reason: one
    - element: home.body
      widget: Lottie
      reason: two
'''),
        throwsA(isA<MappingsFormatException>()),
      );
    });

    test('an empty widget name is rejected', () {
      expect(
        () => policyOf('''
quiescence:
  allow:
    - element: home.body
      widget: "  "
      reason: nothing
'''),
        throwsA(isA<MappingsFormatException>()),
      );
    });
  });

  group('narrowing a declaration to an exact number of instances', () {
    // `widget:` narrows the kind but not the place, and `element:` is
    // only as tight as the id it names. Both were recorded as a
    // limitation of STOP-2: a second Lottie added anywhere inside the
    // declared element would be permitted without anyone noticing.
    //
    // A count closes that, and it is only defensible because the data
    // is now a committed fixture rather than whatever the UAT backend
    // held this morning. Two outlet cards carry an offer in
    // `dashboard_populated`, so exactly two badges loop; a third means
    // something nobody declared is running.
    final policy = policyOf('''
quiescence:
  allow:
    - element: home.outlets_near_you
      widget: Lottie
      count: 2
      reason: the discount badge on each of the two outlet cards with an offer
''');

    List<AnimationActivity> badges(int many) => [
          for (var i = 0; i < many; i++)
            ticking(owner: 'Lottie', path: ['home.body', 'home.outlets_near_you']),
        ];

    test('settles when exactly that many are running', () {
      final verdict = evaluate(badges(2), policy: policy);

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.permitted, hasLength(2));
      expect(verdict.unexpected, isEmpty);
    });

    test('blocks when one more appears, and says so in those words', () {
      // The case the whole key exists for. Without it this reads as
      // three permitted animations and a green run.
      final verdict = evaluate(badges(3), policy: policy);

      expect(verdict, isA<QuiescenceBlocked>());
      expect(
        verdict.blockers.join(' '),
        allOf(
          contains('home.outlets_near_you'),
          contains('Lottie'),
          contains('2'),
          contains('3'),
        ),
      );
    });

    test('permits none of them when the count is wrong', () {
      // Not "the surplus one is unexpected": there is nothing that says
      // which of the three is the extra. A declared count is a claim
      // about the whole screen, and when it does not hold, none of the
      // pixels it covers can be excluded on its authority.
      final verdict = evaluate(badges(3), policy: policy);

      expect(verdict.permitted, isEmpty);
      expect(verdict.unexpected, hasLength(3));
      expect(verdict.excludedRegions, isEmpty);
    });

    test('blocks when one is missing, because the fixture is fixed', () {
      // A declaration with no count is allowed to match nothing - the
      // run must not depend on how much data a fixture happens to hold.
      // A declaration *with* a count has said how much data there is.
      final verdict = evaluate(badges(1), policy: policy);

      expect(verdict, isA<QuiescenceBlocked>());
      expect(verdict.blockers.join(' '), contains('1'));
    });

    test('blocks when none is running, rather than reporting dead config',
        () {
      final verdict = evaluate(const [], policy: policy);

      expect(verdict, isA<QuiescenceBlocked>());
      // Not merely "declared but not animating". A screen that should
      // show two offer badges and shows none is a screen that did not
      // render the fixture.
      expect(verdict.unusedDeclarations, isEmpty);
    });

    test('counts only what the declaration itself matches', () {
      // A shimmer in the same element is not one of the two badges, and
      // must not make the count come out right.
      final verdict = evaluate(
        [
          ...badges(2),
          ticking(owner: 'Shimmer', path: ['home.body', 'home.outlets_near_you']),
        ],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceBlocked>());
      expect(verdict.permitted, hasLength(2));
      expect(verdict.unexpected.single.owner, 'Shimmer');
    });

    test('an animation under another route does not count toward it', () {
      final verdict = evaluate(
        [
          ...badges(2),
          ticking(
            owner: 'Lottie',
            path: ['home.body', 'home.outlets_near_you'],
            routeIndex: 0,
          ),
        ],
        policy: policy,
        topRouteIndex: 1,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.permitted, hasLength(2));
      expect(verdict.belowTopRoute, hasLength(1));
    });

    test('a declaration with no count behaves exactly as it did before', () {
      final uncounted = policyOf('''
quiescence:
  allow:
    - element: home.body
      widget: Lottie
      reason: the discount badge loops
''');

      expect(
        evaluate(
          [
            ticking(owner: 'Lottie', path: ['home.body']),
            ticking(owner: 'Lottie', path: ['home.body']),
            ticking(owner: 'Lottie', path: ['home.body']),
          ],
          policy: uncounted,
        ),
        isA<QuiescenceSettled>(),
      );
    });

    test('a count of zero is a parse error, not a way to forbid a widget',
        () {
      // "None of these may run" is what leaving the declaration out
      // already means. Accepting it here would give one idea two
      // spellings.
      expect(
        () => policyOf('''
quiescence:
  allow:
    - element: home.body
      widget: Lottie
      count: 0
      reason: none
'''),
        throwsA(
          isA<MappingsFormatException>().having(
            (e) => e.message,
            'message',
            contains('"count"'),
          ),
        ),
      );
    });

    test('a count that is not a whole number is a parse error', () {
      for (final value in const ['two', '-1', '1.5']) {
        expect(
          () => policyOf('''
quiescence:
  allow:
    - element: home.body
      widget: Lottie
      count: $value
      reason: none
'''),
          throwsA(isA<MappingsFormatException>()),
          reason: 'count: $value',
        );
      }
    });

    test('the report names the declaration that miscounted', () {
      final lines = evaluate(badges(3), policy: policy).describeLines();

      expect(
        lines.join('\n'),
        contains('home.outlets_near_you'),
      );
    });
  });

  group('what comes out of the visual comparison', () {
    final policy = policyOf('''
quiescence:
  allow:
    - element: home.body
      widget: Lottie
      reason: the discount badge loops
''');

    test('the animation own box, not the declared element', () {
      // Measured: two 33x33 badges inside a scroll body that fills the
      // screen. Excluding what was declared would blank the screen to
      // hide 0.2% of it.
      final verdict = evaluate(
        [
          ticking(
            owner: 'Lottie',
            path: ['home.body'],
            bounds: const LogicalRect(x: 42, y: 1587, width: 33, height: 33),
          ),
        ],
        policy: policy,
      );

      expect(verdict.excludedRegions, [
        const LogicalRect(x: 42, y: 1587, width: 33, height: 33),
      ]);
    });

    test('two animations give two regions', () {
      final verdict = evaluate(
        [
          ticking(
            owner: 'Lottie',
            path: ['home.body'],
            bounds: const LogicalRect(x: 42, y: 1587, width: 33, height: 33),
          ),
          ticking(
            owner: 'Lottie',
            path: ['home.body'],
            bounds: const LogicalRect(x: 42, y: 1994, width: 33, height: 33),
          ),
        ],
        policy: policy,
      );

      expect(verdict.excludedRegions, hasLength(2));
    });

    test('an animation with no bounds cannot be excluded', () {
      final verdict = evaluate(
        [ticking(owner: 'Lottie', path: ['home.body'], bounds: null)],
        policy: policy,
      );

      expect(verdict, isA<QuiescenceSettled>());
      expect(verdict.excludedRegions, isEmpty);
      expect(
        verdict.unlocatable,
        hasLength(1),
        reason: 'a caller about to photograph must be able to decline',
      );
    });

    test('the regions reach the visual configuration', () {
      const region = LogicalRect(x: 42, y: 1587, width: 33, height: 33);
      final config = VisualCheckConfig.defaults.excludingRegions([region]);

      expect(config.ignoreRegions, [region]);
    });

    test('they add to whatever the screen already ignored', () {
      const bar = LogicalRect(x: 0, y: 0, width: 9999, height: 24);
      const badge = LogicalRect(x: 42, y: 1587, width: 33, height: 33);
      const base = VisualCheckConfig(ignoreRegions: [bar]);

      expect(base.excludingRegions([badge]).ignoreRegions, [bar, badge]);
    });

    test('the same region twice is excluded once', () {
      const badge = LogicalRect(x: 42, y: 1587, width: 33, height: 33);
      const base = VisualCheckConfig(ignoreRegions: [badge]);

      expect(base.excludingRegions([badge]).ignoreRegions, [badge]);
    });

    test('nothing permitted excludes nothing', () {
      expect(evaluate(const []).excludedRegions, isEmpty);
      expect(
        VisualCheckConfig.defaults.excludingRegions(const []).ignoreRegions,
        isEmpty,
      );
    });
  });

  group('10. a screen with no quiescence configuration is unchanged', () {
    test('the policy parses as empty', () {
      final mappings = MappingsFile.parse(
        'screen: /profile\nmappings: []\n',
        source: 'profile.yaml',
      );

      expect(mappings.quiescence, QuiescencePolicy.none);
      expect(mappings.quiescence.isEmpty, isTrue);
    });

    test('a settled screen is still settled', () {
      expect(evaluate(const []), isA<QuiescenceSettled>());
    });

    test('an animating screen is still blocked, exactly as before', () {
      final verdict = evaluate([ticking(owner: 'Shimmer', path: ['x'])]);

      expect(verdict, isA<QuiescenceBlocked>());
    });

    test('the quiet period still applies when nothing is permitted', () {
      final verdict = evaluate(
        const [],
        sinceLastFrame: const Duration(milliseconds: 100),
      );

      expect(verdict, isA<QuiescenceBlocked>());
    });

    test('every other mappings key is untouched', () {
      final mappings = MappingsFile.parse('''
screen: /profile
usesResponseFrom:
  endpoint: GET /api/profile/me
mappings:
  - target: profile.display_name
    source: response.data.firstName
quiescence:
  allow:
    - element: profile.spinner
      reason: it spins
''', source: 'profile.yaml');

      expect(mappings.screen, '/profile');
      expect(mappings.usesResponseFrom?.endpoint.path, '/api/profile/me');
      expect(mappings.mappings.single.target, 'profile.display_name');
      expect(mappings.quiescence.allow.single.element, 'profile.spinner');
    });
  });

  group('the report says what was excluded', () {
    test('a settled screen with permitted animations explains itself', () {
      final verdict = evaluate(
        [
          ticking(owner: 'AppMarqueeText', path: ['home.offer_strip']),
          ticking(owner: 'CarouselSlider', path: ['home.banner_carousel']),
        ],
        policy: policyOf('''
quiescence:
  allow:
    - element: home.offer_strip
      reason: the offer text scrolls continuously
    - element: home.banner_carousel
      reason: the promotional banner advances on a timer
'''),
      );

      final lines = verdict.describe();

      expect(lines, contains('2 animations ticking'));
      expect(lines, contains('2 permitted'));
      expect(lines, contains('0 unexpected'));
      expect(lines, contains('home.offer_strip'));
      expect(lines, contains('the offer text scrolls continuously'));
    });

    test('a blocked screen names what stopped it', () {
      final verdict = evaluate([ticking(owner: 'Shimmer', path: ['home.rail'])]);

      expect(verdict.describe(), contains('1 unexpected'));
    });
  });
}
