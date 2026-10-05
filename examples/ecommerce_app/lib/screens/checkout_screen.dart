import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import '../api/api_client.dart';
import '../api/defects.dart';
import '../api/models.dart';
import '../app.dart';
import '../widgets/async_view.dart';
import 'order_success_screen.dart';

/// Where the payment credentials are. Four of the seven seeded secrets
/// pass through this screen, which is what makes it the interesting one
/// for the redaction matrix.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  static const String route = '/checkout';

  /// Seeded payment details. Constants, so a run's artefacts can be
  /// searched for the literals rather than for a pattern that might
  /// match something innocent.
  static const String seededCardNumber = '4111111111111111';
  static const String seededCvv = '731';
  static const String seededOtp = '884512';

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final TextEditingController _address =
      TextEditingController(text: '221B Baker Street');
  final TextEditingController _card =
      TextEditingController(text: CheckoutScreen.seededCardNumber);
  final TextEditingController _cvv =
      TextEditingController(text: CheckoutScreen.seededCvv);
  final TextEditingController _otp =
      TextEditingController(text: CheckoutScreen.seededOtp);

  Loaded<Cart> _cart = const Loaded.loading();
  bool _placing = false;
  ApiException? _failure;

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

  @override
  void dispose() {
    _address.dispose();
    _card.dispose();
    _cvv.dispose();
    _otp.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _cart = const Loaded.loading());
    try {
      final cart = await AppScope.of(context).cart();
      if (!mounted) return;
      setState(() => _cart = cart.isEmpty ? const Loaded.empty() : Loaded.data(cart));
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _cart = Loaded.error(error));
    }
  }

  Future<void> _placeOrder() async {
    setState(() {
      _placing = true;
      _failure = null;
    });

    try {
      final order = await AppScope.of(context).checkout(
        address: _address.text,
        cardNumber: _card.text,
        cvv: _cvv.text,
        otp: _otp.text,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(
        OrderSuccessScreen.route,
        arguments: order,
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _placing = false;
        _failure = error;
      });
    }
  }

  /// Whether the order may be placed.
  ///
  /// Three reasons it may not, each distinguishable on screen: a request
  /// is already in flight, the cart is not loaded, or the form is short
  /// of something. A single opaque disabled button would make all three
  /// look like a bug.
  bool get _canPlaceOrder =>
      !_placing &&
      _cart.state == LoadState.data &&
      _address.text.trim().isNotEmpty &&
      _card.text.trim().length >= 12 &&
      _cvv.text.trim().length >= 3;

  @override
  Widget build(BuildContext context) {
    final failure = _failure;

    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: AsyncView<Cart>(
        idPrefix: 'checkout',
        loaded: _cart,
        onRetry: _load,
        emptyMessage: 'There is nothing to check out',
        builder: (context, cart) => SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const TestKey('checkout.address'),
                controller: _address,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Delivery address',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const TestKey('checkout.card_number'),
                controller: _card,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Card number'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const TestKey('checkout.cvv'),
                controller: _cvv,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'CVV'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const TestKey('checkout.otp'),
                controller: _otp,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'One-time code'),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Payable now'),
                  Text(
                    cart.formattedTotal,
                    key: const TestKey('checkout.total'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Delivery'),
                  Text(
                    '${Defects.current.currencySymbol}'
                    '${groupThousands(cart.deliveryFee)}',
                    key: const TestKey('checkout.delivery_fee'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const TestKey('checkout.place_order'),
                onPressed: _canPlaceOrder ? _placeOrder : null,
                child: Text(_placing ? 'Placing…' : 'Place order'),
              ),
              if (_placing) ...[
                const SizedBox(height: 20),
                const Center(
                  child: CircularProgressIndicator(
                    key: TestKey('checkout.placing'),
                  ),
                ),
              ],
              if (failure != null) ...[
                const SizedBox(height: 20),
                Text(
                  failure.userMessage,
                  key: const TestKey('checkout.payment_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                Text(
                  failure.isTimeout
                      ? 'timeout'
                      : 'status ${failure.statusCode ?? 'none'}',
                  key: const TestKey('checkout.payment_error_code'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
