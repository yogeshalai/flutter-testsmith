import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import 'api/defects.dart';
import 'app.dart';

/// Re-exported so that `import 'main.dart'` keeps reaching the app.
export 'app.dart';
export 'screens/home_screen.dart';

/// The seven-screen example: login, home, products, product details,
/// cart, checkout, order success.
///
/// Not a beautiful shop. A deliberately ordinary one, with the states a
/// real application actually has - loading, empty, error, absent fields,
/// zero values, conditional sections - because those are what a testing
/// platform has to be able to see.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await TestSdk.initialize(
    appId: 'com.example.ecommerce_app',
    appVersion: '0.2.0',
    // A compile-time constant, so a release build tree-shakes the
    // instrumentation away entirely.
    config: const TestSdkConfig(
      enabled: bool.fromEnvironment('TEST_MODE'),
    ),
  );

  // Read once, at startup, so every screen sees the same set for the
  // whole run. `--dart-define=SEED_PRICE_BUG=true` is the only way in
  // for a device build.
  Defects.current = Defects.fromEnvironment;

  runApp(const EcommerceApp());
}
