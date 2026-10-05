import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Phase 12, brief item 7 - test selection, stressed.
///
/// Built against the shape of the real seven-screen application:
/// six flows, a shared state widget, a router, a mappings file. The
/// question the brief asks is whether a ProductDetails change selects
/// the Cart and Checkout tests, and the answer turns out to depend on
/// what "the Cart tests" means - see the group below.

ImpactIndex exampleAppIndex() {
  final builder = ImpactIndexBuilder(appDirectory: 'app');

  void flow(String path, String yaml) =>
      builder.addFlow(path, TestFlow.parse(yaml, source: path));

  flow('app/tests/home.yaml', '''
appId: a
flow: home
steps:
  - expectScreen:
      id: /login
  - tap:
      id: login.submit
  - expectScreen:
      id: /home
''');

  flow('app/tests/product.yaml', '''
appId: a
flow: product_details
steps:
  - tap:
      id: login.submit
  - expectScreen:
      id: /home
  - tap:
      id: home.open_product
  - expectScreen:
      id: /product/details
''');

  flow('app/tests/cart.yaml', '''
appId: a
flow: cart_only
steps:
  - tap:
      id: home.open_cart
  - expectScreen:
      id: /cart
''');

  flow('app/tests/journey.yaml', '''
appId: a
flow: full_journey
steps:
  - expectScreen:
      id: /home
  - expectScreen:
      id: /products
  - expectScreen:
      id: /product/details
  - expectScreen:
      id: /cart
  - expectScreen:
      id: /checkout
  - expectScreen:
      id: /order/success
''');

  builder.addSource('app/lib/product_details_screen.dart', '''
class ProductDetailsScreen extends StatefulWidget {
  static const String route = '/product/details';
}
const a = TestKey('product.price');
const b = TestKey('product.add_to_cart');
''');

  builder.addSource('app/lib/screens/cart_screen.dart', '''
class CartScreen extends StatefulWidget {
  static const String route = '/cart';
}
const a = TestKey('cart.checkout');
''');

  builder.addSource('app/lib/screens/checkout_screen.dart', '''
class CheckoutScreen extends StatefulWidget {
  static const String route = '/checkout';
}
''');

  builder.addSource('app/lib/app.dart', '''
void main() {}
MaterialApp(routes: {});
''');

  // The shared state widget. Every id it builds is interpolated.
  builder.addSource('app/lib/widgets/async_view.dart', r'''
Widget build() => CircularProgressIndicator(key: TestKey('$idPrefix.loading'));
Widget error() => Text(key: TestKey('$idPrefix.error'));
''');

  builder.addConfig('app/mappings/cart.yaml', '/cart');

  return builder.build();
}

void main() {
  late ImpactAnalyser analyser;
  setUp(() => analyser = ImpactAnalyser(exampleAppIndex()));

  group('a change confined to one screen', () {
    test('selects the flows that reach it and no others', () {
      final selection =
          analyser.select(['app/lib/product_details_screen.dart']);

      expect(selection.isFullSuite, isFalse);
      expect(
        selection.selected.map((f) => f.name),
        containsAll(<String>['product_details', 'full_journey']),
      );
      // The brief's question, answered precisely: Cart and Checkout are
      // covered, but only because the journey traverses them. A
      // cart-only flow is NOT selected - nothing in the changed file
      // declares a cart screen or a cart element, which is positive
      // evidence that it is unrelated.
      expect(selection.skipped.map((f) => f.name),
          containsAll(<String>['home', 'cart_only']));
    });

    test('names the specific overlap, so the choice is auditable', () {
      final selection =
          analyser.select(['app/lib/product_details_screen.dart']);

      expect(
        selection.reasonFor('product_details'),
        allOf(
          contains('product_details_screen.dart'),
          contains('/product/details'),
        ),
      );
    });

    test('a cart change selects the cart flows, not the product ones', () {
      final selection = analyser.select(['app/lib/screens/cart_screen.dart']);

      expect(selection.selected.map((f) => f.name),
          containsAll(<String>['cart_only', 'full_journey']));
      expect(selection.skipped.map((f) => f.name), contains('product_details'));
    });
  });

  group('a change affecting several screens', () {
    test('selects the union, and still excludes what neither touches', () {
      final selection = analyser.select([
        'app/lib/product_details_screen.dart',
        'app/lib/screens/cart_screen.dart',
      ]);

      expect(selection.isFullSuite, isFalse);
      expect(
        selection.selected.map((f) => f.name),
        containsAll(<String>['product_details', 'cart_only', 'full_journey']),
      );
      expect(selection.skipped.map((f) => f.name), ['home']);
    });

    test('a configuration file counts as touching its screen', () {
      final selection = analyser.select(['app/mappings/cart.yaml']);

      expect(selection.selected.map((f) => f.name),
          containsAll(<String>['cart_only', 'full_journey']));
    });
  });

  group('the full-suite fallback', () {
    test('a file nothing is known about selects everything', () {
      final selection = analyser.select(['app/lib/util/formatting.dart']);

      expect(selection.isFullSuite, isTrue);
      expect(selection.selected, hasLength(4));
      expect(selection.reason, contains('nothing is known about'));
    });

    test('a file whose every id is interpolated selects everything', () {
      // The Phase 12 defect, and the reason the fallback matters.
      // `TestKey('$idPrefix.loading')` matches the pattern and yields an
      // id no flow can ever name; keeping it made the file look
      // accounted for, and the analyser excluded every flow on evidence
      // that was fake. Measured before the fix: 0 of 6 selected.
      final selection = analyser.select(['app/lib/widgets/async_view.dart']);

      expect(
        selection.isFullSuite,
        isTrue,
        reason: 'AsyncView can reach the loading, error and empty state of '
            'every screen in the application',
      );
      expect(selection.reason, contains('nothing is known about'));
    });

    test('the router selects everything, with the reason that applies', () {
      final selection = analyser.select(['app/lib/app.dart']);

      expect(selection.isFullSuite, isTrue);
      expect(selection.reason, contains('can reach any screen'));
      expect(selection.reason, isNot(contains('nothing is known about')));
    });

    test('a manifest selects everything', () {
      expect(analyser.select(['app/pubspec.yaml']).isFullSuite, isTrue);
    });

    test('a bundled asset selects everything', () {
      expect(analyser.select(['app/assets/product.png']).isFullSuite, isTrue);
    });

    test('the platform own source selects everything', () {
      expect(
        analyser
            .select(['packages/flutter_testsmith_engine/lib/src/dsl/steps.dart'])
            .isFullSuite,
        isTrue,
      );
    });

    test('one unaccountable file among known ones still selects everything',
        () {
      // The asymmetry the rule exists for: a wrong answer here does not
      // produce a visible failure, it produces a regression nobody
      // looked for.
      final selection = analyser.select([
        'app/lib/product_details_screen.dart',
        'app/lib/util/formatting.dart',
      ]);

      expect(selection.isFullSuite, isTrue);
    });
  });

  group('changes that cannot alter behaviour', () {
    test('documentation selects nothing', () {
      final selection = analyser.select(['docs/ARCHITECTURE.md', 'README.md']);

      expect(selection.selected, isEmpty);
      expect(selection.reason, contains('only documentation'));
    });

    test('a CI workflow selects nothing', () {
      expect(
        analyser.select(['.github/workflows/test.yml']).selected,
        isEmpty,
      );
    });

    test('documentation alongside code does not mask the code', () {
      final selection = analyser.select(
        ['docs/ARCHITECTURE.md', 'app/lib/screens/cart_screen.dart'],
      );

      expect(selection.selected.map((f) => f.name), contains('cart_only'));
      expect(selection.reason, isNot(contains('only documentation')));
    });
  });

  group('what the index records', () {
    test('an interpolated id is not recorded at all', () {
      final index = exampleAppIndex();
      final file = index.file('app/lib/widgets/async_view.dart')!;

      expect(file.elements, isEmpty);
      expect(file.screens, isEmpty);
      expect(file.isAttributable, isFalse);
    });

    test('a literal id beside an interpolated one is still recorded', () {
      final builder = ImpactIndexBuilder(appDirectory: 'app')
        ..addSource('app/lib/mixed.dart', r'''
const a = TestKey('cart.checkout');
const b = TestKey('cart.line_$id');
''');

      final file = builder.build().file('app/lib/mixed.dart')!;
      expect(file.elements, {'cart.checkout'});
    });
  });
}
