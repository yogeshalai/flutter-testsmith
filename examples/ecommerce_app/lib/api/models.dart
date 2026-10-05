import 'defects.dart';

/// Everything here parses defensively, and that is the point.
///
/// A real backend omits fields, sends nulls where the schema promised a
/// value, and sends zero where a designer assumed a number. A model that
/// throws on those turns a data problem into a crash, and a crashed
/// screen tells a test platform nothing about what the screen would have
/// shown. Each degenerate input has to produce a *defined* UI state, so
/// that a validator has something to compare.

/// Reads an int that may be absent, null, a double, or a string.
int? optionalInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value.toString());
}

/// Reads a non-empty string, treating `""` as absent.
///
/// An empty name and a missing name are the same UI problem - there is
/// nothing to show - and collapsing them here means one placeholder path
/// instead of two.
String? optionalText(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

bool? optionalBool(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  return switch (value.toString().toLowerCase()) {
    'true' => true,
    'false' => false,
    _ => null,
  };
}

/// Groups thousands the way the `currency` transformation does.
String groupThousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

class Product {
  const Product({
    required this.name,
    required this.price,
    required this.discount,
    required this.available,
    this.id = '123',
    this.image,
    this.rating,
  });

  final String id;

  /// Null when the API sent no name, or an empty one.
  final String? name;

  /// Null when the API omitted the price entirely, which is different
  /// from a price of zero.
  final int? price;

  final int discount;
  final bool available;

  /// Null is normal: plenty of catalogue entries have no photograph.
  final String? image;

  final double? rating;

  factory Product.fromJson(Map<String, Object?> json) => Product(
        id: (json['id'] ?? '').toString(),
        name: optionalText(json['name']),
        price: optionalInt(json['price']),
        discount: optionalInt(json['discount']) ?? 0,
        available: optionalBool(json['available']) ?? true,
        image: optionalText(json['image']),
        rating: switch (json['rating']) {
          final num r => r.toDouble(),
          _ => null,
        },
      );

  /// What the screen shows for the name.
  ///
  /// The `truncateNameTo` defect lives here rather than in the widget so
  /// that the same wrongness appears everywhere the name is shown, which
  /// is how a real formatting bug behaves.
  String get displayName {
    final actual = name;
    if (actual == null) return 'Unnamed product';
    final limit = Defects.current.truncateNameTo;
    if (limit > 0 && actual.length > limit) return actual.substring(0, limit);
    return actual;
  }

  /// The app's own formatting, not the API's.
  ///
  /// The mapping declares `currency(INR)` as what this *should* produce.
  /// When the two disagree, that disagreement is the finding.
  String get formattedPrice {
    final actual = price;
    if (actual == null) return 'Price unavailable';
    final defects = Defects.current;
    return '${defects.currencySymbol}'
        '${groupThousands(actual - defects.priceOffBy)}';
  }

  /// Whether the buy action should be live.
  bool get canAddToCart =>
      Defects.current.ignoreAvailability ? true : available;

  /// Whether the discount badge should be on screen.
  bool get showsDiscount =>
      Defects.current.showDiscountWhenZero ? true : discount > 0;

  /// Whether the image widget should be built.
  bool get showsImage =>
      Defects.current.renderImageWhenNull ? true : image != null;

  @override
  String toString() => 'Product($id, $name, $price)';
}

class CartLine {
  const CartLine({
    required this.productId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  final String productId;
  final String? name;
  final int quantity;
  final int unitPrice;
  final int lineTotal;

  factory CartLine.fromJson(Map<String, Object?> json) => CartLine(
        productId: (json['productId'] ?? '').toString(),
        name: optionalText(json['name']),
        quantity: optionalInt(json['quantity']) ?? 0,
        unitPrice: optionalInt(json['unitPrice']) ?? 0,
        lineTotal: optionalInt(json['lineTotal']) ?? 0,
      );
}

class Cart {
  const Cart({
    required this.lines,
    required this.subtotal,
    required this.discount,
    required this.deliveryFee,
    required this.total,
    this.currency = 'INR',
  });

  final List<CartLine> lines;
  final int subtotal;
  final int discount;
  final int deliveryFee;

  /// What the API says the total is.
  final int total;

  final String currency;

  bool get isEmpty => lines.isEmpty;

  /// What the screen shows as the total.
  ///
  /// Not `total`: the `cartTotalIgnoresDeliveryFee` defect makes the app
  /// compute its own, which is exactly the class of bug where the API is
  /// right and the UI is wrong.
  int get displayTotal =>
      Defects.current.cartTotalIgnoresDeliveryFee ? total - deliveryFee : total;

  String get formattedTotal =>
      '${Defects.current.currencySymbol}${groupThousands(displayTotal)}';

  factory Cart.fromJson(Map<String, Object?> json) => Cart(
        lines: [
          for (final line in (json['lines'] as List?) ?? const [])
            if (line is Map) CartLine.fromJson(line.cast<String, Object?>()),
        ],
        subtotal: optionalInt(json['subtotal']) ?? 0,
        discount: optionalInt(json['discount']) ?? 0,
        deliveryFee: optionalInt(json['deliveryFee']) ?? 0,
        total: optionalInt(json['total']) ?? 0,
        currency: optionalText(json['currency']) ?? 'INR',
      );
}

class Order {
  const Order({required this.orderId, this.status, this.etaMinutes});

  final String orderId;
  final String? status;

  /// Null when the backend cannot estimate. A defined state, not a bug:
  /// the screen must say so rather than rendering "null minutes".
  final int? etaMinutes;

  String get etaText => etaMinutes == null
      ? 'We will confirm delivery time shortly'
      : 'Arriving in about $etaMinutes minutes';

  factory Order.fromJson(Map<String, Object?> json) => Order(
        orderId: optionalText(json['orderId']) ?? 'unknown',
        status: optionalText(json['status']),
        etaMinutes: optionalInt(json['etaMinutes']),
      );
}

class HomeSummary {
  const HomeSummary({
    required this.greeting,
    required this.cartCount,
    this.featuredProductId,
    this.bannerTitle,
  });

  final String greeting;
  final int cartCount;
  final String? featuredProductId;
  final String? bannerTitle;

  factory HomeSummary.fromJson(Map<String, Object?> json) => HomeSummary(
        greeting: optionalText(json['greeting']) ?? 'Welcome',
        cartCount: optionalInt(json['cartCount']) ?? 0,
        featuredProductId: optionalText(json['featuredProductId']),
        bannerTitle: optionalText(
          (json['banner'] as Map?)?.cast<String, Object?>()['title'],
        ),
      );
}

class Session {
  const Session({required this.token, this.refreshToken, this.userName});

  /// A bearer token. Seeded deliberately: it must never reach an event,
  /// a report or a model. See the Phase 12 security matrix.
  final String token;
  final String? refreshToken;
  final String? userName;

  factory Session.fromJson(Map<String, Object?> json) => Session(
        token: optionalText(json['token']) ?? '',
        refreshToken: optionalText(json['refreshToken']),
        userName: optionalText(
          (json['user'] as Map?)?.cast<String, Object?>()['name'],
        ),
      );
}
