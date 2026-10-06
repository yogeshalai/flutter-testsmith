// A push future completes only when the pushed route is popped, so these
// navigations are deliberately not awaited; awaiting them would deadlock
// the test. pumpAndSettle is what synchronises with the transition.
// ignore_for_file: unawaited_futures

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import 'support/fake_sdk_channel.dart';

const AppContext app = AppContext(
  appVersion: '1.0.0',
  buildMode: BuildMode.debug,
  environment: 'test',
  platform: 'android',
  devicePixelRatio: 1.875,
);

({TestSession session, FakeSdkChannel channel}) makeSession() {
  final channel = FakeSdkChannel();
  final session = TestSession(
    config: const TestSdkConfig(enabled: true),
    channel: channel,
    describeApp: () => app,
    appId: 'com.example.shop',
    sdkVersion: '0.1.0',
  );
  return (session: session, channel: channel);
}

List<String> screenEventSummary(FakeSdkChannel channel) => [
      for (final TestEvent e in channel.emitted)
        switch (e.payload) {
          ScreenEnterPayload(:final screenId, :final previousScreenId) =>
            'enter:$screenId(from=$previousScreenId)',
          ScreenExitPayload(:final screenId, :final nextScreenId) =>
            'exit:$screenId(to=$nextScreenId)',
          _ => 'other:${e.type.wire}',
        },
    ];

Widget appUnderTest(TestNavigatorObserver observer) {
  return MaterialApp(
    navigatorObservers: [observer],
    initialRoute: '/',
    routes: {
      '/': (_) => const Scaffold(body: Text('Home')),
      '/products': (_) => const Scaffold(body: Text('ProductList')),
      '/products/details': (_) => const Scaffold(body: Text('Details')),
    },
  );
}

void main() {
  unstableRouteNameTests();
  group('TestNavigatorObserver', () {
    testWidgets('emits SCREEN_ENTER for the initial route', (tester) async {
      final (:session, :channel) = makeSession();

      await tester.pumpWidget(
        appUnderTest(TestNavigatorObserver(session: session)),
      );

      expect(screenEventSummary(channel), ['enter:/(from=null)']);
      expect(session.currentScreenId, '/');
    });

    testWidgets('emits enter with the previous screen on push',
        (tester) async {
      final (:session, :channel) = makeSession();
      await tester.pumpWidget(
        appUnderTest(TestNavigatorObserver(session: session)),
      );

      tester.state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/products');
      await tester.pumpAndSettle();

      expect(screenEventSummary(channel), [
        'enter:/(from=null)',
        'enter:/products(from=/)',
      ]);
      expect(session.currentScreenId, '/products');
    });

    testWidgets('emits SCREEN_EXIT naming the screen returned to on pop',
        (tester) async {
      final (:session, :channel) = makeSession();
      await tester.pumpWidget(
        appUnderTest(TestNavigatorObserver(session: session)),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator))
        ..pushNamed('/products');
      await tester.pumpAndSettle();

      navigator.pop();
      await tester.pumpAndSettle();

      expect(screenEventSummary(channel), [
        'enter:/(from=null)',
        'enter:/products(from=/)',
        'exit:/products(to=/)',
      ]);
      expect(session.currentScreenId, '/');
    });

    testWidgets('emits an exit and an enter on replace', (tester) async {
      final (:session, :channel) = makeSession();
      await tester.pumpWidget(
        appUnderTest(TestNavigatorObserver(session: session)),
      );

      tester.state<NavigatorState>(find.byType(Navigator))
          .pushReplacementNamed('/products');
      await tester.pumpAndSettle();

      expect(screenEventSummary(channel), [
        'enter:/(from=null)',
        'exit:/(to=/products)',
        'enter:/products(from=/)',
      ]);
      expect(session.currentScreenId, '/products');
    });

    testWidgets('tracks a deep push sequence in order', (tester) async {
      final (:session, :channel) = makeSession();
      await tester.pumpWidget(
        appUnderTest(TestNavigatorObserver(session: session)),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));

      navigator.pushNamed('/products');
      await tester.pumpAndSettle();
      navigator.pushNamed('/products/details');
      await tester.pumpAndSettle();

      expect(screenEventSummary(channel), [
        'enter:/(from=null)',
        'enter:/products(from=/)',
        'enter:/products/details(from=/products)',
      ]);
    });
  });

  group('screen id resolution', () {
    testWidgets('falls back to a marker for an unnamed route', (tester) async {
      // Unnamed routes are unstable identifiers. The fallback must be
      // obviously synthetic so it is visible in a report rather than
      // silently passing as a real screen id.
      final (:session, :channel) = makeSession();
      await tester.pumpWidget(
        appUnderTest(TestNavigatorObserver(session: session)),
      );

      tester.state<NavigatorState>(find.byType(Navigator)).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Anonymous')),
            ),
          );
      await tester.pumpAndSettle();

      expect(session.currentScreenId, startsWith('<unnamed'));
    });

    testWidgets('uses a custom resolver when supplied', (tester) async {
      final (:session, :channel) = makeSession();

      await tester.pumpWidget(
        appUnderTest(
          TestNavigatorObserver(
            session: session,
            resolveScreenId: (route) => switch (route.settings.name) {
              '/' => 'Home',
              '/products' => 'ProductList',
              _ => 'Unknown',
            },
          ),
        ),
      );
      tester.state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/products');
      await tester.pumpAndSettle();

      expect(screenEventSummary(channel), [
        'enter:Home(from=null)',
        'enter:ProductList(from=Home)',
      ]);
    });
  });

  group('when the SDK is not armed', () {
    testWidgets('a null session makes the observer inert', (tester) async {
      // The application still builds and navigates normally; the observer
      // simply records nothing.
      await tester.pumpWidget(
        appUnderTest(TestNavigatorObserver(session: null)),
      );

      tester.state<NavigatorState>(find.byType(Navigator))
          .pushNamed('/products');
      await tester.pumpAndSettle();

      expect(find.text('ProductList'), findsOneWidget);
    });
  });
}

/// Added during external-application validation: go_router names the
/// route it builds for a StatefulShellRoute with an object hash, and two
/// consecutive runs reported `100338058` and then `720295915`.
void unstableRouteNameTests() {
  Route<dynamic> routeNamed(String? name) => PageRouteBuilder<void>(
        settings: RouteSettings(name: name),
        pageBuilder: (_, _, _) => const SizedBox.shrink(),
      );

  group('an unstable route name', () {
    test('a numeric name is refused, loudly', () {
      expect(
        defaultScreenIdResolver(routeNamed('720295915')),
        startsWith('<unnamed:'),
      );
    });

    test('a real path is kept', () {
      expect(defaultScreenIdResolver(routeNamed('/home')), '/home');
      expect(
        defaultScreenIdResolver(routeNamed('/orders/abc123')),
        '/orders/abc123',
      );
    });

    test('a short number is kept, because it may be deliberate', () {
      // A screen genuinely called "1" or "404" is odd but possible; a
      // ten-digit one never is.
      expect(defaultScreenIdResolver(routeNamed('404')), '404');
    });

    test('a name with digits in it is kept', () {
      expect(defaultScreenIdResolver(routeNamed('/tab2')), '/tab2');
      expect(defaultScreenIdResolver(routeNamed('step1')), 'step1');
    });

    test('an absent name is still the marker', () {
      expect(
        defaultScreenIdResolver(routeNamed(null)),
        startsWith('<unnamed:'),
      );
    });
  });
}
