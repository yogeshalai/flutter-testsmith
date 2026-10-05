import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import '../api/models.dart';
import 'home_screen.dart';

/// The end of the flow.
///
/// Takes the order as a route argument rather than refetching it: this
/// is the one screen whose data came from a POST, and re-requesting it
/// would be both wrong and a second chance to fail.
class OrderSuccessScreen extends StatelessWidget {
  const OrderSuccessScreen({super.key, this.order});

  static const String route = '/order/success';

  final Order? order;

  @override
  Widget build(BuildContext context) {
    final argument = ModalRoute.of(context)?.settings.arguments;
    final resolved = order ?? (argument is Order ? argument : null);

    return Scaffold(
      appBar: AppBar(title: const Text('Order placed')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, size: 64),
              const SizedBox(height: 16),
              const Text(
                'Thank you, your order is confirmed',
                key: TestKey('order.success_message'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 12),
              // Reaching this screen with no order is not a crash and not
              // a blank page: it is a defined, reportable state. A screen
              // that throws here tells a test platform nothing about what
              // it would have shown.
              Text(
                resolved == null
                    ? 'Order reference unavailable'
                    : resolved.orderId,
                key: const TestKey('order.id'),
              ),
              const SizedBox(height: 8),
              Text(
                // Null ETA has its own words rather than "null minutes".
                resolved?.etaText ?? 'We will be in touch',
                key: const TestKey('order.eta'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 32),
              FilledButton(
                key: const TestKey('order.continue_shopping'),
                onPressed: () => Navigator.of(context)
                    .pushNamedAndRemoveUntil(HomeScreen.route, (_) => false),
                child: const Text('Continue shopping'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
