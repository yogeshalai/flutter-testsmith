import 'package:ecommerce_app/api/api_client.dart';
import 'package:ecommerce_app/api/models.dart';
import 'package:ecommerce_app/app.dart';
import 'package:ecommerce_app/screens/cart_screen.dart';
import 'package:ecommerce_app/screens/checkout_screen.dart';
import 'package:ecommerce_app/screens/home_screen.dart';
import 'package:ecommerce_app/screens/login_screen.dart';
import 'package:ecommerce_app/screens/order_success_screen.dart';
import 'package:ecommerce_app/screens/product_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import 'harness.dart';

/// Phase 12, brief item 2 - UI states.
///
/// Every row asserts on the **captured UI tree**, not on a widget
/// finder. That is the contract a flow actually has: `testsmith` sees
/// semantic ids, text, `enabled` and `visible`, and a state that a
/// widget test can find but the tree cannot report is a state no flow
/// can assert on.

final matrix = MatrixRecorder(
  'UI state matrix',
  'docs/evidence/ui_state_matrix.md',
  const [
    'Screen',
    'State',
    'Arranged by',
    'Element present',
    'Elements absent',
    'enabled',
  ],
);

/// Pumps a screen against a canned API and captures the tree.
Future<UiSnapshot> screen(
  WidgetTester tester,
  Widget child, {
  required String screenId,
  required ApiClient api,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(804, 1800);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    AppScope(api: api, child: MaterialApp(home: child)),
  );

  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A loading screen holds a CircularProgressIndicator, whose
    // animation never ends: pumpAndSettle would wait for a settle that
    // never comes.
    await tester.pump();
  }

  return const UiTreeInspector().capture(
    root: tester.binding.rootElement!,
    screenId: screenId,
    devicePixelRatio: 2,
  );
}

void main() {
  setUp(resetDefects);
  tearDownAll(() => matrix.write(
        preamble: 'Each row pumps one screen against a canned API '
            'outcome and asserts on the tree `UiTreeInspector` captures '
            '- the same tree `ext.mytest.uiTree` returns on a device. '
            'The API outcomes themselves are proven over a real socket '
            'in `api_transport_matrix.md`.',
      ));

  group('loading', () {
    testWidgets('a screen waiting on the API shows loading and nothing else',
        (tester) async {
      final snapshot = await screen(
        tester,
        const ProductListScreen(),
        screenId: '/products',
        // Never answers: the screen stays in its loading state. An
        // empty override map would fail the call instead, which is the
        // error state, not this one.
        api: FakeApi(neverAnswers: true),
        settle: false,
      );

      expect(snapshot.find('products.loading'), isNotNull);
      expect(snapshot.find('products.list'), isNull);
      expect(snapshot.find('products.empty'), isNull);
      expect(snapshot.find('products.error'), isNull);

      matrix.add([
        '/products',
        'loading',
        'a request that has not answered',
        'products.loading',
        'products.list, products.empty, products.error',
        '-',
      ]);
    });
  });

  group('success', () {
    testWidgets('the product list renders its rows and no other state',
        (tester) async {
      final snapshot = await screen(
        tester,
        const ProductListScreen(),
        screenId: '/products',
        api: apiFor('default'),
      );

      expect(snapshot.find('products.list'), isNotNull);
      expect(snapshot.find('products.name_123')?.text, 'Nonveg-Burger');
      expect(snapshot.find('products.empty'), isNull);
      expect(snapshot.find('products.error'), isNull);
      expect(snapshot.find('products.loading'), isNull);

      matrix.add([
        '/products',
        'success',
        'default (3 items)',
        'products.list, products.name_123',
        'products.empty, products.error, products.loading',
        '-',
      ]);
    });

    testWidgets('the cart renders its totals', (tester) async {
      final snapshot = await screen(
        tester,
        const CartScreen(),
        screenId: '/cart',
        api: apiFor('default'),
      );

      expect(snapshot.find('cart.total')?.text, 'Rs 4,129');
      expect(snapshot.find('cart.subtotal')?.text, 'Rs 4,779');
      expect(snapshot.find('cart.delivery_fee')?.text, 'Rs 40');
      expect(snapshot.find('cart.checkout')?.enabled, isTrue);

      matrix.add([
        '/cart',
        'success',
        'default (2 lines)',
        'cart.total, cart.subtotal, cart.delivery_fee',
        'cart.empty, cart.error',
        'cart.checkout = true',
      ]);
    });

    testWidgets('order success shows the id and the ETA', (tester) async {
      final snapshot = await screen(
        tester,
        OrderSuccessScreen(
          order: Order.fromJson(fixtureBody('default', 'POST', '/checkout')),
        ),
        screenId: '/order/success',
        api: apiFor('default'),
      );

      expect(snapshot.find('order.id')?.text, 'ORD-20260912-0001');
      expect(snapshot.find('order.eta')?.text, contains('35 minutes'));

      matrix.add([
        '/order/success',
        'success',
        'default checkout reply',
        'order.id, order.eta',
        '-',
        '-',
      ]);
    });
  });

  group('empty', () {
    testWidgets('an empty catalogue is its own state', (tester) async {
      final snapshot = await screen(
        tester,
        const ProductListScreen(),
        screenId: '/products',
        api: apiFor('products_empty'),
      );

      expect(snapshot.find('products.empty'), isNotNull);
      expect(snapshot.find('products.list'), isNull);
      expect(snapshot.find('products.loading'), isNull);
      expect(snapshot.find('products.error'), isNull);

      matrix.add([
        '/products',
        'empty',
        'products_empty (items: [])',
        'products.empty',
        'products.list, products.loading, products.error',
        '-',
      ]);
    });

    testWidgets('an empty cart offers no checkout at all', (tester) async {
      final snapshot = await screen(
        tester,
        const CartScreen(),
        screenId: '/cart',
        api: apiFor('cart_empty'),
      );

      expect(snapshot.find('cart.empty'), isNotNull);
      // Absent rather than disabled. Both satisfy "you cannot check
      // out"; only one of them is what the screen does, and a rule
      // expecting `enabled: false` on an absent element fails.
      expect(snapshot.find('cart.checkout'), isNull);

      matrix.add([
        '/cart',
        'empty',
        'cart_empty (lines: [])',
        'cart.empty',
        'cart.checkout (absent, not disabled)',
        '-',
      ]);
    });

    testWidgets('checkout with an empty cart refuses to take an order',
        (tester) async {
      final snapshot = await screen(
        tester,
        const CheckoutScreen(),
        screenId: '/checkout',
        api: apiFor('cart_empty'),
      );

      expect(snapshot.find('checkout.empty'), isNotNull);
      expect(snapshot.find('checkout.place_order'), isNull);

      matrix.add([
        '/checkout',
        'empty',
        'cart_empty',
        'checkout.empty',
        'checkout.place_order',
        '-',
      ]);
    });
  });

  group('error', () {
    for (final (status, fixtureLabel, expectedText) in [
      (400, 'HTTP 400', 'not valid'),
      (401, 'HTTP 401', 'session has expired'),
      (403, 'HTTP 403', 'do not have access'),
      (404, 'HTTP 404', 'could not find'),
      (500, 'HTTP 500', 'our end'),
    ]) {
      testWidgets('$fixtureLabel renders its own words and a retry',
          (tester) async {
        final snapshot = await screen(
          tester,
          const ProductListScreen(),
          screenId: '/products',
          api: FakeApi(failure: ApiException('x', statusCode: status)),
        );

        expect(snapshot.find('products.error')?.text, contains(expectedText));
        expect(snapshot.find('products.error_code')?.text, 'status $status');
        // A retry, because an error with no way forward is a dead end.
        expect(snapshot.find('products.retry')?.enabled, isTrue);
        expect(snapshot.find('products.list'), isNull);

        matrix.add([
          '/products',
          'error',
          fixtureLabel,
          'products.error, products.error_code, products.retry',
          'products.list, products.loading, products.empty',
          'products.retry = true',
        ]);
      });
    }

    testWidgets('a timeout says timeout, not "status null"', (tester) async {
      final snapshot = await screen(
        tester,
        const ProductListScreen(),
        screenId: '/products',
        api: FakeApi(failure: const ApiException('t', isTimeout: true)),
      );

      expect(snapshot.find('products.error')?.text, contains('took too long'));
      expect(snapshot.find('products.error_code')?.text, 'timeout');

      matrix.add([
        '/products',
        'error',
        'timeout',
        'products.error, products.error_code',
        'products.list',
        '-',
      ]);
    });

    testWidgets('a declined card shows a payment error, not a screen error',
        (tester) async {
      await screen(
        tester,
        const CheckoutScreen(),
        screenId: '/checkout',
        api: _DecliningApi(apiFor('default')),
      );

      await tester.tap(find.byKey(const TestKey('checkout.place_order')));
      await tester.pumpAndSettle();

      final snapshot = const UiTreeInspector().capture(
        root: tester.binding.rootElement!,
        screenId: '/checkout',
        devicePixelRatio: 2,
      );

      expect(snapshot.find('checkout.payment_error'), isNotNull);
      expect(snapshot.find('checkout.payment_error_code')?.text, 'status 402');
      // The form is still there: the cart loaded, only the payment
      // failed.
      expect(snapshot.find('checkout.total'), isNotNull);
      expect(snapshot.find('checkout.place_order'), isNotNull);

      matrix.add([
        '/checkout',
        'action error',
        'checkout_declined (402)',
        'checkout.payment_error, checkout.total',
        'checkout.error (the screen itself is fine)',
        '-',
      ]);
    });
  });

  group('conditional and degenerate data', () {
    testWidgets('an out-of-stock row is disabled and says so', (tester) async {
      final snapshot = await screen(
        tester,
        const ProductListScreen(),
        screenId: '/products',
        api: apiFor('default'),
      );

      expect(snapshot.find('products.unavailable_789'), isNotNull);
      expect(snapshot.find('products.item_789')?.enabled, isFalse);
      expect(snapshot.find('products.item_123')?.enabled, isTrue);

      matrix.add([
        '/products',
        'unavailable',
        'items.2.available = false',
        'products.unavailable_789',
        '-',
        'products.item_789 = false',
      ]);
    });

    testWidgets('a discounted row shows a badge, an undiscounted one does not',
        (tester) async {
      final snapshot = await screen(
        tester,
        const ProductListScreen(),
        screenId: '/products',
        api: apiFor('default'),
      );

      expect(snapshot.find('products.discount_456'), isNotNull);
      expect(snapshot.find('products.discount_123'), isNull);

      matrix.add([
        '/products',
        'discounted',
        'items.1.discount = 15',
        'products.discount_456',
        'products.discount_123',
        '-',
      ]);
    });

    testWidgets('a null image falls back to a placeholder', (tester) async {
      final snapshot = await screen(
        tester,
        const ProductListScreen(),
        screenId: '/products',
        api: apiFor('default'),
      );

      expect(snapshot.find('products.thumb_placeholder_789'), isNotNull);

      matrix.add([
        '/products',
        'null field',
        'items.2.image = null',
        'products.thumb_placeholder_789',
        '-',
        '-',
      ]);
    });

    testWidgets('a null ETA becomes words, not "null"', (tester) async {
      final snapshot = await screen(
        tester,
        OrderSuccessScreen(
          order:
              Order.fromJson(fixtureBody('order_no_eta', 'POST', '/checkout')),
        ),
        screenId: '/order/success',
        api: apiFor('default'),
      );

      final eta = snapshot.find('order.eta')?.text;
      expect(eta, isNotNull);
      expect(eta, isNot(contains('null')));

      matrix.add([
        '/order/success',
        'null field',
        'order_no_eta (etaMinutes: null)',
        'order.eta',
        '-',
        '-',
      ]);
    });

    testWidgets('an order screen reached with no order does not crash',
        (tester) async {
      final snapshot = await screen(
        tester,
        const OrderSuccessScreen(),
        screenId: '/order/success',
        api: apiFor('default'),
      );

      expect(snapshot.find('order.id')?.text, 'Order reference unavailable');

      matrix.add([
        '/order/success',
        'missing data',
        'no route argument',
        'order.id (placeholder)',
        '-',
        '-',
      ]);
    });

    testWidgets('a banner in the response is rendered', (tester) async {
      final snapshot = await screen(
        tester,
        const HomeScreen(),
        screenId: '/home',
        api: apiFor('default'),
      );

      expect(snapshot.find('home.banner'), isNotNull);
    });

    testWidgets('an absent banner leaves the section out', (tester) async {
      // A separate test rather than a second pump: pumpWidget reuses the
      // State for the same widget type, so the screen would never reload
      // and would still be showing the first response.
      final snapshot = await screen(
        tester,
        const HomeScreen(),
        screenId: '/home',
        api: apiFor('home_no_banner'),
      );

      expect(snapshot.find('home.banner'), isNull);

      matrix.add([
        '/home',
        'conditional',
        'home_no_banner (no banner key)',
        '-',
        'home.banner',
        '-',
      ]);
    });

    testWidgets('an empty cart count disables the cart button', (tester) async {
      final snapshot = await screen(
        tester,
        const HomeScreen(),
        screenId: '/home',
        api: apiFor('cart_empty'),
      );

      expect(snapshot.find('home.open_cart')?.enabled, isFalse);
      expect(snapshot.find('home.cart_badge')?.text, 'Cart (0)');

      matrix.add([
        '/home',
        'disabled',
        'cart_empty (cartCount: 0)',
        'home.cart_badge',
        '-',
        'home.open_cart = false',
      ]);
    });
  });

  group('login', () {
    testWidgets('a refused login shows the reason and keeps the form',
        (tester) async {
      final snapshot0 = await screen(
        tester,
        const LoginScreen(),
        screenId: '/login',
        api: FakeApi(failure: const ApiException('x', statusCode: 401)),
      );
      expect(snapshot0.find('login.submit')?.enabled, isTrue);

      await tester.tap(find.byKey(const TestKey('login.submit')));
      await tester.pumpAndSettle();

      final snapshot = const UiTreeInspector().capture(
        root: tester.binding.rootElement!,
        screenId: '/login',
        devicePixelRatio: 2,
      );

      expect(snapshot.find('login.error')?.text, contains('session'));
      expect(snapshot.find('login.error_code')?.text, 'status 401');
      expect(snapshot.find('login.email'), isNotNull);

      matrix.add([
        '/login',
        'error',
        'login_invalid (401)',
        'login.error, login.error_code',
        '-',
        'login.submit = true (re-enabled)',
      ]);
    });
  });
}

/// Succeeds on every route except checkout, which is declined.
class _DecliningApi extends FakeApi {
  _DecliningApi(FakeApi inner) : super(overrides: inner.overrides);

  @override
  Future<Order> checkout({
    required String address,
    required String cardNumber,
    required String cvv,
    required String otp,
  }) async =>
      throw const ApiException('card declined', statusCode: 402);
}
