import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const String _productFlow = '''
appId: com.example.ecommerce_app
flow: product_details
steps:
  - launchApp
  - tap:
      id: home.open_product
  - expectScreen:
      id: /product/details
  - validateScreen
''';

const String _homeFlow = '''
appId: com.example.ecommerce_app
flow: home
steps:
  - launchApp
  - expectScreen:
      id: /home
  - validateScreen
''';

const String _productSource = '''
class ProductDetailsScreen extends StatefulWidget {
  static const String route = '/product/details';
}
Widget build() => Text(x, key: const TestKey('product.price'));
''';

const String _mainSource = '''
void main() => runApp(const EcommerceApp());
class HomeScreen extends StatelessWidget {
  static const String route = '/home';
}
Widget build() => MaterialApp(
  home: FilledButton(key: const TestKey('home.open_product')),
);
''';

/// An index over the two example flows and the two example sources.
ImpactIndex _index() => (ImpactIndexBuilder(appDirectory: 'examples/app')
      ..addFlow('examples/app/tests/product.yaml',
          TestFlow.parse(_productFlow, source: 'p.yaml'))
      ..addFlow('examples/app/tests/home.yaml',
          TestFlow.parse(_homeFlow, source: 'h.yaml'))
      ..addSource('examples/app/lib/product_details_screen.dart',
          _productSource)
      ..addSource('examples/app/lib/main.dart', _mainSource)
      ..addConfig('examples/app/mappings/product_details.yaml',
          '/product/details'))
    .build();

ImpactSelection _select(List<String> changed) =>
    ImpactAnalyser(_index()).select(changed);

Set<String> _names(Iterable<FlowCoverage> flows) =>
    {for (final f in flows) f.name};

void main() {
  group('what a source file touches', () {
    test('a screen file is attributed to its route and its test ids', () {
      final index = _index();
      final file =
          index.file('examples/app/lib/product_details_screen.dart')!;

      expect(file.screens, contains('/product/details'));
      expect(file.elements, contains('product.price'));
      expect(file.isGlobal, isFalse);
    });

    test('a file that wires the application is global', () {
      // main.dart declares a route like any screen, but it also builds
      // the MaterialApp. Attributing it to /home alone would mean a
      // change to the router selected only the home flow.
      final file = _index().file('examples/app/lib/main.dart')!;

      expect(file.isGlobal, isTrue);
    });

    test('a mappings file is attributed to the screen it names', () {
      final file =
          _index().file('examples/app/mappings/product_details.yaml')!;

      expect(file.screens, {'/product/details'});
    });
  });

  group('selecting flows', () {
    test('a change to one screen selects only the flow that visits it', () {
      final selection =
          _select(['examples/app/lib/product_details_screen.dart']);

      expect(_names(selection.selected), {'product_details'});
      expect(_names(selection.skipped), {'home'});
      expect(selection.isFullSuite, isFalse);
    });

    test('a change to the home screen selects the flow that asserts on it',
        () {
      // The product flow taps home.open_product, so it depends on the
      // home screen too. Both flows are selected, and that is correct
      // rather than conservative.
      final selection = _select(['examples/app/lib/main.dart']);

      expect(_names(selection.selected), {'product_details', 'home'});
    });

    test('a change to a screen configuration selects that screen\'s flow',
        () {
      final selection =
          _select(['examples/app/mappings/product_details.yaml']);

      expect(_names(selection.selected), {'product_details'});
    });

    test('changing a flow file selects that flow', () {
      final selection = _select(['examples/app/tests/home.yaml']);

      expect(_names(selection.selected), {'home'});
    });

    test('says why each flow was selected', () {
      // A selection nobody can audit is a selection nobody will trust.
      final selection =
          _select(['examples/app/lib/product_details_screen.dart']);

      expect(
        selection.reasonFor('product_details'),
        allOf(contains('product_details_screen.dart'),
            contains('/product/details')),
      );
    });
  });

  group('falling back to everything', () {
    test('an unrecognised file in the application runs the whole suite', () {
      // A shared widget with no route and no test id could be used by
      // any screen. Guessing narrower here is how a regression ships.
      final selection = _select(['examples/app/lib/widgets/spinner.dart']);

      expect(selection.isFullSuite, isTrue);
      expect(_names(selection.selected), {'product_details', 'home'});
      expect(selection.reason, contains('spinner.dart'));
    });

    test('a change to the test platform itself runs the whole suite', () {
      // If the tool changed, no previous result about the application
      // can be trusted to still hold.
      final selection =
          _select(['packages/flutter_testsmith_engine/lib/src/validation/validators.dart']);

      expect(selection.isFullSuite, isTrue);
    });

    test('a manifest or asset change runs the whole suite', () {
      for (final path in [
        'examples/app/pubspec.yaml',
        'examples/app/assets/product.png',
      ]) {
        expect(_select([path]).isFullSuite, isTrue, reason: path);
      }
    });

    test('one unattributable file outweighs several attributed ones', () {
      // Selection narrows only on positive evidence about EVERY change.
      final selection = _select([
        'examples/app/lib/product_details_screen.dart',
        'examples/app/lib/widgets/spinner.dart',
      ]);

      expect(selection.isFullSuite, isTrue);
    });
  });

  group('changes that cannot affect a test', () {
    test('documentation selects nothing', () {
      final selection = _select(['README.md', 'docs/ARCHITECTURE.md']);

      expect(selection.selected, isEmpty);
      expect(selection.isFullSuite, isFalse);
    });

    test('no changes at all selects nothing', () {
      final selection = _select(const []);

      expect(selection.selected, isEmpty);
      expect(selection.reason, contains('no changes'));
    });

    test('documentation alongside code does not mask the code', () {
      final selection = _select(
        ['README.md', 'examples/app/lib/product_details_screen.dart'],
      );

      expect(_names(selection.selected), {'product_details'});
    });
  });
}
