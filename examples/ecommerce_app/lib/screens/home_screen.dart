import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../app.dart';
import '../product_details_screen.dart' show ProductDetailsScreen;
import '../widgets/async_view.dart';
import 'cart_screen.dart';
import 'product_list_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static const String route = '/home';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Loaded<HomeSummary> _summary = const Loaded.loading();

  /// Loads once, after dependencies are available.
  ///
  /// Not `initState`: the API client comes from an inherited widget, and
  /// reading one before `initState` has completed is an error Flutter
  /// asserts on. The flag keeps a dependency change from re-issuing the
  /// request - `didChangeDependencies` runs again whenever an ancestor
  /// inherited widget updates, and a screen that refetched on every
  /// theme change would be a load generator.
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _summary = const Loaded.loading());
    try {
      final summary = await AppScope.of(context).homeSummary();
      if (!mounted) return;
      setState(() => _summary = Loaded.data(summary));
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _summary = Loaded.error(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: AsyncView<HomeSummary>(
        idPrefix: 'home',
        loaded: _summary,
        onRetry: _load,
        builder: (context, summary) => _body(context, summary),
      ),
    );
  }

  Widget _body(BuildContext context, HomeSummary summary) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            summary.greeting,
            key: const TestKey('home.greeting'),
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 8),
          // Conditional UI driven by a value that can legitimately be
          // absent: a banner is a merchandising decision, not a
          // guarantee.
          if (summary.bannerTitle != null)
            Text(
              summary.bannerTitle!,
              key: const TestKey('home.banner'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          const Text(
            'Nike Air Max',
            key: TestKey('home.product_name'),
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 16),
          FilledButton(
            // Kept, and kept named this, because two committed flows, the
            // impact index and the visual baseline all reach the product
            // screen through it.
            key: const TestKey('home.open_product'),
            onPressed: () =>
                Navigator.of(context).pushNamed(ProductDetailsScreen.route),
            child: const Text('View product'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const TestKey('home.open_products'),
            onPressed: () =>
                Navigator.of(context).pushNamed(ProductListScreen.route),
            child: const Text('Browse all'),
          ),
          const SizedBox(height: 12),
          TextButton(
            key: const TestKey('home.open_cart'),
            // Disabled on an empty cart: a real `enabled` state driven by
            // an API number, which is what a rule asserts on.
            onPressed: summary.cartCount == 0
                ? null
                : () => Navigator.of(context).pushNamed(CartScreen.route),
            child: Text(
              'Cart (${summary.cartCount})',
              key: const TestKey('home.cart_badge'),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            TestSdk.isArmed
                ? 'test instrumentation: ARMED'
                : 'test instrumentation: off',
            key: const TestKey('home.sdk_status'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          // Shown on screen because a mis-placed tap during a smoke run
          // is otherwise very hard to diagnose: this makes the value the
          // SDK reports directly comparable with what MediaQuery sees.
          Text(
            'sdk dpr ${TestSdk.devicePixelRatio.toStringAsFixed(3)}  '
            'mediaQuery ${MediaQuery.devicePixelRatioOf(context).toStringAsFixed(3)}',
            key: const TestKey('home.dpr'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
