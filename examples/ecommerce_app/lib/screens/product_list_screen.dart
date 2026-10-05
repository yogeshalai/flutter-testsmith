import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../app.dart';
import '../product_details_screen.dart' show ProductDetailsScreen;
import '../widgets/async_view.dart';

/// The catalogue. Where the empty state, the per-row conditional UI and
/// the null fields live.
class ProductListScreen extends StatefulWidget {
  const ProductListScreen({super.key});

  static const String route = '/products';

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  Loaded<List<Product>> _products = const Loaded.loading();

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
    setState(() => _products = const Loaded.loading());
    try {
      final products = await AppScope.of(context).products();
      if (!mounted) return;
      setState(() {
        // An empty list is not an error and not a failure to load. It is
        // its own state, and conflating it with either is how "no
        // results" comes to look like a spinner that never stops.
        _products =
            products.isEmpty ? const Loaded.empty() : Loaded.data(products);
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _products = Loaded.error(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Products')),
      body: AsyncView<List<Product>>(
        idPrefix: 'products',
        loaded: _products,
        onRetry: _load,
        emptyMessage: 'No products match right now',
        builder: (context, products) => ListView(
          key: const TestKey('products.list'),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${products.length} products',
                key: const TestKey('products.count'),
              ),
            ),
            for (final product in products) _row(context, product),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Product product) {
    return ListTile(
      key: TestKey('products.item_${product.id}'),
      // A null image is the ordinary case, not an error: the row shows a
      // placeholder rather than a broken box.
      leading: product.showsImage
          ? const Icon(Icons.image, key: TestKey('products.thumb'))
          : Icon(
              Icons.inventory_2_outlined,
              key: TestKey('products.thumb_placeholder_${product.id}'),
            ),
      title: Text(
        product.displayName,
        key: TestKey('products.name_${product.id}'),
      ),
      subtitle: Row(
        children: [
          Text(
            product.formattedPrice,
            key: TestKey('products.price_${product.id}'),
          ),
          if (product.showsDiscount) ...[
            const SizedBox(width: 8),
            Text(
              '${product.discount}% off',
              key: TestKey('products.discount_${product.id}'),
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
          if (!product.available) ...[
            const SizedBox(width: 8),
            Text(
              'Out of stock',
              key: TestKey('products.unavailable_${product.id}'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      // An unavailable product is not tappable, which is a real disabled
      // state on a real list row.
      enabled: product.canAddToCart,
      onTap: () => Navigator.of(context).pushNamed(
        ProductDetailsScreen.route,
        arguments: product.id,
      ),
    );
  }
}
