import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import '../api/api_client.dart';
import '../api/defects.dart';
import '../api/models.dart';
import '../app.dart';
import '../widgets/async_view.dart';
import 'checkout_screen.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  static const String route = '/cart';

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  Loaded<Cart> _cart = const Loaded.loading();

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
    setState(() => _cart = const Loaded.loading());
    try {
      final cart = await AppScope.of(context).cart();
      if (!mounted) return;
      // An empty cart is a first-class state with its own words and its
      // own affordance, not a list of nothing.
      setState(() => _cart = cart.isEmpty ? const Loaded.empty() : Loaded.data(cart));
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _cart = Loaded.error(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cart')),
      body: AsyncView<Cart>(
        idPrefix: 'cart',
        loaded: _cart,
        onRetry: _load,
        emptyMessage: 'Your cart is empty',
        builder: _body,
      ),
    );
  }

  Widget _body(BuildContext context, Cart cart) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${cart.lines.length} item(s)',
            key: const TestKey('cart.item_count'),
          ),
        ),
        Expanded(
          child: ListView(
            key: const TestKey('cart.list'),
            children: [
              for (final line in cart.lines)
                ListTile(
                  key: TestKey('cart.line_${line.productId}'),
                  title: Text(
                    line.name ?? 'Unnamed product',
                    key: TestKey('cart.name_${line.productId}'),
                  ),
                  subtitle: Text(
                    '${line.quantity} x '
                    '${Defects.current.currencySymbol}'
                    '${groupThousands(line.unitPrice)}',
                    key: TestKey('cart.qty_${line.productId}'),
                  ),
                  trailing: Text(
                    '${Defects.current.currencySymbol}'
                    '${groupThousands(line.lineTotal)}',
                    key: TestKey('cart.line_total_${line.productId}'),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _row('Subtotal', cart.subtotal, 'cart.subtotal'),
              // Conditional: no discount means no line, rather than a
              // line reading "0 off", which is the sort of thing a rule
              // asserts on.
              if (cart.discount > 0)
                _row('Discount', -cart.discount, 'cart.discount'),
              _row('Delivery', cart.deliveryFee, 'cart.delivery_fee'),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total'),
                  Text(
                    cart.formattedTotal,
                    key: const TestKey('cart.total'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const TestKey('cart.checkout'),
                onPressed: cart.isEmpty
                    ? null
                    : () =>
                        Navigator.of(context).pushNamed(CheckoutScreen.route),
                child: const Text('Checkout'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(String label, int amount, String id) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            '${Defects.current.currencySymbol}${groupThousands(amount)}',
            key: TestKey(id),
          ),
        ],
      );
}
