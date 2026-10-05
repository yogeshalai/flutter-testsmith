import 'package:ecommerce_app/api/api_client.dart';
import 'package:ecommerce_app/main.dart';
import 'package:ecommerce_app/screens/cart_screen.dart';
import 'package:ecommerce_app/screens/checkout_screen.dart';
import 'package:ecommerce_app/screens/login_screen.dart';
import 'package:ecommerce_app/screens/order_success_screen.dart';
import 'package:ecommerce_app/screens/product_list_screen.dart';
import 'package:ecommerce_app/product_details_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

const Product unavailableProduct = Product(
  name: 'Nike Air Max',
  price: 2999,
  discount: 0,
  available: false,
);

const Product discountedProduct = Product(
  name: 'Adidas Ultraboost',
  price: 4599,
  discount: 15,
  available: true,
);

/// Pumps the details screen with a stubbed fetch.
///
/// flutter_test stubs every HttpClient to status 400, so the real
/// request path cannot run here; it is exercised on a device instead.
Future<void> pumpDetails(
  WidgetTester tester, {
  Product? product,
  Object? error,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ProductDetailsScreen(
        fetchProduct: () async {
          if (error != null) throw error;
          return product!;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The screen as the platform sees it.
///
/// Assertions go through [UiTreeInspector] rather than through a widget
/// cast, and that is the point: `tester.widget<FilledButton>(...)` broke
/// the moment Phase 6 restyled the button, and stayed broken because the
/// cast asserts on an implementation detail no test should know. The
/// platform reads `enabled` off the captured node; so should this.
UiSnapshot capture(WidgetTester tester) => const UiTreeInspector().capture(
      root: tester.binding.rootElement!,
      screenId: '/product/details',
      devicePixelRatio: 1.0,
    );

/// A client that never answers, so every screen sits in its loading
/// state and no route needs a fixture to build.
final ApiClient neverAnsweringApi = _NeverAnswers();

class _NeverAnswers extends ApiClient {
  @override
  Future<Never> product(String id) => Completer<Never>().future;
  @override
  Future<Never> cart() => Completer<Never>().future;
  @override
  Future<Never> products() => Completer<Never>().future;
  @override
  Future<Never> homeSummary() => Completer<Never>().future;
}

void main() {
  group('app shell', () {
    testWidgets('opens on the sign-in screen', (tester) async {
      // Changed in Phase 12: the app used to start on /home, which is a
      // state nobody can reach without a token.
      await tester.pumpWidget(const EcommerceApp());
      await tester.pump();

      expect(find.byKey(const TestKey('login.email')), findsOneWidget);
      expect(find.byKey(const TestKey('login.submit')), findsOneWidget);
    });

    testWidgets('shows the instrumentation status, so a failed run can be '
        'diagnosed from a screenshot', (tester) async {
      await tester.pumpWidget(const EcommerceApp());
      await tester.pump();

      expect(find.byKey(const TestKey('login.sdk_status')), findsOneWidget);
    });

    testWidgets('every route in the table builds', (tester) async {
      // A route that throws on build is a crash nobody sees until a
      // flow navigates to it.
      for (final route in const [
        LoginScreen.route,
        HomeScreen.route,
        ProductListScreen.route,
        ProductDetailsScreen.route,
        CartScreen.route,
        CheckoutScreen.route,
        OrderSuccessScreen.route,
      ]) {
        await tester.pumpWidget(
          EcommerceApp(api: neverAnsweringApi, initialRoute: route),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: route);
      }
    });
  });

  group('product details', () {
    testWidgets('shows the name and formatted price', (tester) async {
      await pumpDetails(tester, product: unavailableProduct);

      expect(find.byKey(const TestKey('product.name')), findsOneWidget);
      // Twice: once in the card, once in the bar at the foot of the
      // page. Asserting "exactly one" asserted a layout the design
      // changed in Phase 6.
      expect(capture(tester).find('product.price')?.text, 'Rs 2,999');
      expect(capture(tester).find('product.cart_total')?.text, 'Rs 2,999');
    });

    testWidgets('disables add to cart when the API says unavailable',
        (tester) async {
      // The motivating example from the specification.
      await pumpDetails(tester, product: unavailableProduct);

      expect(capture(tester).find('product.add_to_cart')?.enabled, isFalse);
      expect(find.byKey(const TestKey('product.unavailable')), findsOneWidget);
    });

    testWidgets('enables add to cart when available', (tester) async {
      await pumpDetails(tester, product: discountedProduct);

      expect(capture(tester).find('product.add_to_cart')?.enabled, isTrue);
      expect(find.byKey(const TestKey('product.unavailable')), findsNothing);
    });

    testWidgets('shows a discount badge when there is a discount',
        (tester) async {
      await pumpDetails(tester, product: discountedProduct);

      expect(
        find.byKey(const TestKey('product.discount_badge')),
        findsOneWidget,
      );
    });

    testWidgets('hides the discount badge when there is none', (tester) async {
      // A separate test rather than a second pump: pumpWidget reuses the
      // State for the same widget type, so initState would not re-run
      // and the screen would still be showing the first product.
      await pumpDetails(tester, product: unavailableProduct);

      expect(find.byKey(const TestKey('product.discount_badge')), findsNothing);
    });

    testWidgets('shows the error rather than an empty screen', (tester) async {
      await pumpDetails(tester, error: 'connection refused');

      expect(find.byKey(const TestKey('product.error')), findsOneWidget);
    });

    testWidgets('is wrapped in an addressable subtree', (tester) async {
      await pumpDetails(tester, product: unavailableProduct);

      expect(resolveTestId(tester.element(find.byType(TestId))),
          'product.card');
    });
  });

  group('price formatting', () {
    test('groups thousands', () {
      expect(
        const Product(name: 'x', price: 2999, discount: 0, available: true)
            .formattedPrice,
        'Rs 2,999',
      );
      expect(
        const Product(name: 'x', price: 999, discount: 0, available: true)
            .formattedPrice,
        'Rs 999',
      );
      expect(
        const Product(name: 'x', price: 1234567, discount: 0, available: true)
            .formattedPrice,
        'Rs 1,234,567',
      );
    });
  });
}
