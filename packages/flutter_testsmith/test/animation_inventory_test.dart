import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// Which animations are running, not merely how many.
///
/// `transientCallbackCount` said "2 animations running" and stopped
/// there, which is why a screen that never settles could only ever be
/// given up on. To declare an exception you first have to be able to
/// name the thing you are excepting.
///
/// Everything here runs against **real widgets**, because the mechanism
/// is Flutter's own bookkeeping and a hand-built tree would prove
/// nothing about it.

/// A shimmer placeholder: repeats for ever.
class Perpetual extends StatefulWidget {
  const Perpetual({super.key, this.child = const Text('shimmer')});

  final Widget child;

  @override
  State<Perpetual> createState() => _PerpetualState();
}

class _PerpetualState extends State<Perpetual>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: controller, child: widget.child);
}

/// A transition: runs once and stops.
class Finite extends StatefulWidget {
  const Finite({super.key});

  @override
  State<Finite> createState() => _FiniteState();
}

class _FiniteState extends State<Finite> with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..forward();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: controller, child: const Text('hero'));
}

/// A marquee: a raw [Ticker], not an [AnimationController].
class Marquee extends StatefulWidget {
  const Marquee({super.key});

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  late final Ticker ticker;

  @override
  void initState() {
    super.initState();
    ticker = createTicker((_) {})..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('offer');
}

/// Two controllers on one state, one running and one not.
class Pair extends StatefulWidget {
  const Pair({super.key});

  @override
  State<Pair> createState() => _PairState();
}

class _PairState extends State<Pair> with TickerProviderStateMixin {
  late final AnimationController running;
  late final AnimationController idle;

  @override
  void initState() {
    super.initState();
    running = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    idle =
        AnimationController(vsync: this, duration: const Duration(seconds: 1));
  }

  @override
  void dispose() {
    running.dispose();
    idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          FadeTransition(opacity: running, child: const Text('a')),
          FadeTransition(opacity: idle, child: const Text('b')),
        ],
      );
}

Future<List<AnimationActivity>> inventory(
  WidgetTester tester,
  Widget app, {
  int frames = 4,
}) async {
  await tester.pumpWidget(app);
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return const AnimationInspector().inspect(tester.binding.rootElement!);
}

/// Everything ticking, by the widget that owns it.
Iterable<String> owners(List<AnimationActivity> found) =>
    found.map((a) => a.owner);

void main() {
  testWidgets('a screen with no animations reports none', (tester) async {
    final found = await inventory(
      tester,
      const MaterialApp(home: Scaffold(body: Text('static'))),
    );

    expect(found, isEmpty);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a perpetual animation is reported, with its owner',
      (tester) async {
    final found = await inventory(
      tester,
      const MaterialApp(home: Scaffold(body: Perpetual())),
    );

    expect(found, hasLength(1));
    expect(found.single.owner, 'Perpetual');
  });

  testWidgets('the count matches Flutter own, so nothing is unattributed',
      (tester) async {
    // The load-bearing claim of the whole design: every scheduled
    // transient callback is accounted for by a ticker we can name. If
    // this ever stops holding, a declared exception could hide an
    // animation nobody declared.
    final found = await inventory(
      tester,
      const MaterialApp(
        home: Scaffold(
          body: Column(children: [Perpetual(), Marquee(), Pair()]),
        ),
      ),
    );

    expect(found, hasLength(tester.binding.transientCallbackCount));
    // Perpetual, Marquee, and the one of Pair's two that is running.
    expect(found, hasLength(3));
  });

  testWidgets('a raw Ticker is reported as well as an AnimationController',
      (tester) async {
    final found = await inventory(
      tester,
      const MaterialApp(home: Scaffold(body: Marquee())),
    );

    expect(owners(found), ['Marquee']);
  });

  testWidgets('two controllers on one state report separately',
      (tester) async {
    final found = await inventory(
      tester,
      const MaterialApp(home: Scaffold(body: Pair())),
    );

    expect(found, hasLength(1), reason: 'only one of the two is running');
    expect(found.single.owner, 'Pair');
  });

  testWidgets('a finite animation disappears once it finishes',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Finite())));
    await tester.pump();

    expect(
      const AnimationInspector().inspect(tester.binding.rootElement!),
      hasLength(1),
    );

    await tester.pumpAndSettle();

    expect(
      const AnimationInspector().inspect(tester.binding.rootElement!),
      isEmpty,
    );
  });

  testWidgets('a stopped animation is not reported', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Pair())));
    await tester.pump(const Duration(milliseconds: 50));

    final state = tester.state<State<Pair>>(find.byType(Pair));
    // ignore: avoid_dynamic_calls
    (state as dynamic).running.stop();
    await tester.pump();

    expect(
      const AnimationInspector().inspect(tester.binding.rootElement!),
      isEmpty,
    );
  });

  group('attribution to a semantic id', () {
    testWidgets('reports the nearest enclosing id', (tester) async {
      final found = await inventory(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: TestId(id: 'home.offer_strip', child: Perpetual()),
          ),
        ),
      );

      expect(found.single.elementId, 'home.offer_strip');
    });

    testWidgets('reports every enclosing id, outermost first',
        (tester) async {
      // So a declaration may name any honest ancestor rather than
      // having to guess which one the platform considers nearest.
      final found = await inventory(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: TestId(
              id: 'home.offers',
              child: TestId(id: 'home.offers.strip', child: Perpetual()),
            ),
          ),
        ),
      );

      expect(found.single.elementPath, ['home.offers', 'home.offers.strip']);
    });

    testWidgets('an animation with no id reports an empty path',
        (tester) async {
      final found = await inventory(
        tester,
        const MaterialApp(home: Scaffold(body: Perpetual())),
      );

      expect(found.single.elementPath, isEmpty);
      expect(found.single.elementId, isNull);
    });

    testWidgets('a TestKey names it too', (tester) async {
      final found = await inventory(
        tester,
        MaterialApp(
          home: Scaffold(
            body: Perpetual(
              key: const TestKey('home.banner'),
              child: const Text('banner'),
            ),
          ),
        ),
      );

      expect(found.single.elementId, 'home.banner');
    });
  });

  group('routes', () {
    testWidgets('an opaque route on top mutes what is underneath',
        (tester) async {
      // Flutter own doing, via the overlay TickerMode. Asserted here
      // because the quiescence policy leans on it.
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const Perpetual()),
      );
      await tester.pump();
      unawaited(
        key.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('on top')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        const AnimationInspector().inspect(tester.binding.rootElement!),
        isEmpty,
      );
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('a transparent route on top does NOT mute it', (tester) async {
      // This is the case the policy route filter exists for: a dialog
      // over an animating dashboard keeps the dashboard ticking.
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          home: const TestId(id: 'home.offer_strip', child: Perpetual()),
        ),
      );
      await tester.pump();
      unawaited(
        showDialog<void>(
          context: key.currentContext!,
          builder: (_) => const AlertDialog(content: Text('dialog')),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final found = const AnimationInspector().inspect(
        tester.binding.rootElement!,
      );

      expect(found, hasLength(1));
      expect(found.single.elementId, 'home.offer_strip');
      expect(
        found.single.routeIndex,
        isNotNull,
        reason: 'the engine cannot confine it to a route without this',
      );
    });

    testWidgets('a muted subtree is not reported', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TickerMode(enabled: false, child: Perpetual()),
        ),
      );
      await tester.pump();

      expect(
        const AnimationInspector().inspect(tester.binding.rootElement!),
        isEmpty,
      );
    });
  });

  group('the settle probe carries the inventory', () {
    testWidgets('a settle reading lists what is ticking', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TestId(id: 'home.offer_strip', child: Perpetual()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final state = SettleState(
        sinceLastFrame: const Duration(milliseconds: 16),
        inFlightRequests: 0,
        transientCallbacks: tester.binding.transientCallbackCount,
        quietPeriod: const Duration(milliseconds: 500),
        animations: const AnimationInspector().inspect(
          tester.binding.rootElement!,
        ),
      );

      expect(state.animations.single.elementId, 'home.offer_strip');
      expect(state.isSettled, isFalse, reason: 'the SDK still decides nothing');
    });

    testWidgets('it survives the round trip over the wire', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TestId(id: 'home.offer_strip', child: Perpetual()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final sent = SettleState(
        sinceLastFrame: const Duration(milliseconds: 16),
        inFlightRequests: 1,
        transientCallbacks: tester.binding.transientCallbackCount,
        quietPeriod: const Duration(milliseconds: 500),
        topRouteIndex: 0,
        animations: const AnimationInspector().inspect(
          tester.binding.rootElement!,
        ),
      );

      final back = SettleState.fromJson(sent.toJson());

      expect(back.animations.single.owner, 'Perpetual');
      expect(back.animations.single.elementPath, ['home.offer_strip']);
      expect(back.topRouteIndex, 0);
      expect(back.transientCallbacks, sent.transientCallbacks);
    });

    testWidgets('an older SDK that sends no inventory still parses',
        (tester) async {
      final back = SettleState.fromJson(const {
        'sinceLastFrameMs': 16,
        'inFlightRequests': 0,
        'transientCallbacks': 2,
        'quietPeriodMs': 500,
      });

      expect(back.animations, isEmpty);
      expect(back.transientCallbacks, 2);
    });
  });

  group('security', () {
    testWidgets('the inventory carries no text from the screen',
        (tester) async {
      // An animation owner is a widget type and a semantic id. Neither
      // is user data, and nothing here reads a Text or a field value -
      // an inventory taken on a login screen must not become a second
      // way to read a password.
      final found = await inventory(
        tester,
        MaterialApp(
          home: Scaffold(
            body: TestId(
              id: 'login.password',
              child: Perpetual(
                child: TextField(
                  obscureText: true,
                  controller:
                      TextEditingController(text: 'SEEDED_PASSWORD_c41e77b0'),
                ),
              ),
            ),
          ),
        ),
      );

      expect(found, hasLength(1));
      expect(
        found.single.toJson().toString(),
        isNot(contains('SEEDED_PASSWORD_c41e77b0')),
      );
    });
  });
}
