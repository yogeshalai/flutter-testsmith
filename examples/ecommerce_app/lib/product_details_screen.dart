import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import 'api/api_client.dart';
import 'api/models.dart';
import 'app.dart';
import 'screens/cart_screen.dart';

/// Re-exported so that `import 'product_details_screen.dart'` keeps
/// working. The model moved to `api/models.dart` in Phase 12, when six
/// more screens needed it; the import path did not have to move with it.
export 'api/models.dart' show Product;
export 'api/api_client.dart' show apiBase;

/// Fetches the product shown by [ProductDetailsScreen].
typedef ProductFetcher = Future<Product> Function();

/// The screen the Figma spec and the visual baseline are both bound to.
///
/// **Its layout is frozen.** Every margin is a fraction of the 402pt
/// design frame, the committed baseline was recorded from it on a real
/// device, and `figma/product_details.json` measures it to two pixels.
/// Phase 12 changed what it fetches and where the button goes, and
/// nothing about what it paints.
class ProductDetailsScreen extends StatefulWidget {
  const ProductDetailsScreen({super.key, this.fetchProduct});

  static const String route = '/product/details';

  /// Overrides how the product is loaded.
  ///
  /// Defaults to a real `dart:io` request, which is what the SDK
  /// intercepts on a device. Injectable so a widget test can run
  /// without a socket - flutter_test stubs every HttpClient to 400 -
  /// and so an application can supply its own client.
  final ProductFetcher? fetchProduct;

  @override
  State<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<ProductDetailsScreen> {
  Product? _product;
  String? _error;

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
    // Still the first frame, which is the case the correlation
    // grace window and the SDK ring buffer exist for.
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final fetch = widget.fetchProduct ?? _fetchOverHttp;
      final product = await fetch();
      if (!mounted) return;
      setState(() => _product = product);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is ApiException ? error.userMessage : '$error';
      });
    }
  }

  Future<Product> _fetchOverHttp() {
    // The id travels as a route argument when the list pushed this
    // screen, and defaults to the fixture product otherwise - which is
    // the path the committed baseline and the two original flows take.
    final argument = ModalRoute.of(context)?.settings.arguments;
    final id = argument is String ? argument : '123';
    return AppScope.of(context).product(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Product Details')),
      body: TestId(id: 'product.card', child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Text(error, key: const TestKey('product.error'));
    }

    final product = _product;
    if (product == null) {
      return const Center(
        child: CircularProgressIndicator(key: TestKey('product.loading')),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: _dp(context, 24)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: _dp(context, 20)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_dp(context, 12)),
              child: product.showsImage
                  ? Image.asset(
                      'assets/product.png',
                      key: const TestKey('product.image'),
                      width: _dp(context, 362),
                      height: _dp(context, 362),
                      fit: BoxFit.cover,
                    )
                  // A catalogue entry with no photograph is ordinary. The
                  // placeholder occupies the same box, so the layout does
                  // not jump - and so the design's geometry check still
                  // has something to measure.
                  : Container(
                      key: const TestKey('product.image_placeholder'),
                      width: _dp(context, 362),
                      height: _dp(context, 362),
                      color: const Color(0xFFE9E9E9),
                      alignment: Alignment.center,
                      child: const Text('No image'),
                    ),
            ),
          ),
          SizedBox(height: _dp(context, 56)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: _dp(context, 34)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.displayName,
                  key: const TestKey('product.name'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF353535),
                  ),
                ),
                SizedBox(height: _dp(context, 10)),
                Text(
                  product.formattedPrice,
                  key: const TestKey('product.price'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF353535),
                  ),
                ),
                if (product.showsDiscount) ...[
                  SizedBox(height: _dp(context, 10)),
                  Text(
                    '${product.discount}% off',
                    key: const TestKey('product.discount_badge'),
                  ),
                ],
                if (!product.available) ...[
                  SizedBox(height: _dp(context, 10)),
                  Text(
                    'Out of stock',
                    key: const TestKey('product.unavailable'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                SizedBox(height: _dp(context, 79)),
                SizedBox(
                  width: _dp(context, 281),
                  child: const Text(
                    'Lorem Ipsum is simply dummy text of the printing and '
                    "typesetting industry. Lorem Ipsum has been the industry's "
                    'standard dummy text ever since the 1500s',
                    key: TestKey('product.description'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF6F6F6F),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: _dp(context, 56)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: _dp(context, 74)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Highlights',
                  key: TestKey('product.highlights_label'),
                  style: _sectionLabel,
                ),
                SizedBox(height: _dp(context, 47)),
                const Text(
                  'Information',
                  key: TestKey('product.information_label'),
                  style: _sectionLabel,
                ),
              ],
            ),
          ),
          SizedBox(height: _dp(context, 40)),
          // Part of the page, not a pinned bar. The design draws it at
          // the foot of a 1198pt frame - that is the end of the content,
          // and pinning it would place it above everything below the
          // fold in screen order.
          _buildCartBar(context, product),
        ],
      ),
    );
  }

  /// The bar the design puts at the foot of the screen.
  ///
  /// Laid out with [Stack] rather than a [Row]: the design fixes both
  /// the total and the button by their left edge, and a Row would place
  /// them relative to each other's intrinsic width - which depends on
  /// the font, and so would drift.
  Widget _buildCartBar(BuildContext context, Product product) {
    return Container(
      color: const Color(0xFF2D3A4B),
      height: _dp(context, 60),
      width: double.infinity,
      child: Stack(
        children: [
          Positioned(
            left: _dp(context, 83),
            top: _dp(context, 21),
            child: Text(
              product.formattedPrice,
              key: const TestKey('product.cart_total'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFFFFFFFF),
              ),
            ),
          ),
          Positioned(
            left: _dp(context, 293),
            top: _dp(context, 12),
            child: TextButton(
              key: const TestKey('product.add_to_cart'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              // The motivating example: disabled when the API says the
              // product is unavailable.
              onPressed: product.canAddToCart
                  ? () => Navigator.of(context).pushNamed(CartScreen.route)
                  : null,
              child: const Text(
                'Add',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6EC8B1),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const TextStyle _sectionLabel = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
  color: Color(0xFF2D3A4B),
);

/// The width the design was drawn at.
const double _designFrameWidth = 402;

/// Converts a design measurement into logical pixels for this screen.
///
/// Margins and gaps are expressed as fractions of the design frame
/// rather than as absolute numbers, so the layout keeps the design's
/// proportions on a device of any width - which is what makes the
/// geometry comparison meaningful instead of a measure of how close this
/// particular phone happens to be to 402pt.
///
/// Font sizes are deliberately *not* scaled: a type scale is an absolute
/// token, and the typography check compares it as one.
double _dp(BuildContext context, double designPx) =>
    MediaQuery.sizeOf(context).width * designPx / _designFrameWidth;
