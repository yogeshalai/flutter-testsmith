import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import 'api/api_client.dart';
import 'screens/cart_screen.dart';
import 'screens/checkout_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/order_success_screen.dart';
import 'product_details_screen.dart';
import 'screens/product_list_screen.dart';

/// Shares one [ApiClient] across the screens.
///
/// A single client rather than one per screen, because the bearer token
/// obtained at login has to reach every later call - which is also what
/// makes the redaction test worth running: the credential is genuinely
/// on the wire for six screens, not just one.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.api, required super.child});

  final ApiClient api;

  static ApiClient of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this widget');
    return scope!.api;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.api != api;
}

class EcommerceApp extends StatefulWidget {
  const EcommerceApp({super.key, this.api, this.initialRoute});

  /// Injectable so a widget test can drive a screen without a socket.
  final ApiClient? api;

  final String? initialRoute;

  @override
  State<EcommerceApp> createState() => _EcommerceAppState();
}

class _EcommerceAppState extends State<EcommerceApp> {
  late final ApiClient _api = widget.api ?? ApiClient();

  @override
  Widget build(BuildContext context) {
    return AppScope(
      api: _api,
      child: MaterialApp(
        title: 'Ecommerce Example',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        // Safe to attach unconditionally: inert when the SDK is not armed.
        navigatorObservers: [TestSdk.navigatorObserver],
        initialRoute: widget.initialRoute ?? LoginScreen.route,
        routes: {
          LoginScreen.route: (_) => const LoginScreen(),
          HomeScreen.route: (_) => const HomeScreen(),
          ProductListScreen.route: (_) => const ProductListScreen(),
          ProductDetailsScreen.route: (_) => const ProductDetailsScreen(),
          CartScreen.route: (_) => const CartScreen(),
          CheckoutScreen.route: (_) => const CheckoutScreen(),
          OrderSuccessScreen.route: (_) => const OrderSuccessScreen(),
        },
      ),
    );
  }
}
