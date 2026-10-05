/// Deliberate bugs, injectable one at a time.
///
/// The platform's whole claim is that it catches a disagreement between
/// what an API returned and what a screen shows. Proving that needs an
/// application that can be made wrong on purpose, in a controlled way -
/// otherwise every "we caught it" is a story about code nobody ran.
///
/// Two ways in, because there are two callers:
///
/// * a device run seeds with `--dart-define`, read by [fromEnvironment];
/// * a widget test assigns [current] directly, because a test cannot set
///   a compile-time constant.
///
/// Everything defaults to correct. The application is only wrong when a
/// run asks it to be.
class Defects {
  const Defects({
    this.priceOffBy = 0,
    this.ignoreAvailability = false,
    this.truncateNameTo = 0,
    this.showDiscountWhenZero = false,
    this.currencySymbol = 'Rs ',
    this.cartTotalIgnoresDeliveryFee = false,
    this.renderImageWhenNull = false,
  });

  /// Renders `price - priceOffBy`. The specification's motivating
  /// example: the API says 2999 and the screen says 2599.
  final int priceOffBy;

  /// Leaves Add to Cart enabled even when the API says `available:false`.
  final bool ignoreAvailability;

  /// Cuts the product name to this many characters, so "Nike Air Max"
  /// renders as "Nike Air". Zero means no truncation.
  final int truncateNameTo;

  /// Shows the discount badge at `discount == 0`, breaking a declared
  /// rule rather than a mapping.
  final bool showDiscountWhenZero;

  /// What the app prefixes a price with. The mapping declares
  /// `currency(INR)`, which is `Rs `; anything else is a formatting bug.
  final String currencySymbol;

  /// Totals the cart without the delivery fee, so the UI and the API
  /// disagree by exactly the fee.
  final bool cartTotalIgnoresDeliveryFee;

  /// Renders the image widget even when the API sent `image: null`,
  /// instead of the placeholder.
  final bool renderImageWhenNull;

  /// What `--dart-define` asked for.
  ///
  /// `SEED_PRICE_BUG` is kept as a name because the README, the Phase 7
  /// measurements and the committed baseline all refer to it.
  static const Defects fromEnvironment = Defects(
    priceOffBy: int.fromEnvironment('SEED_PRICE_OFF_BY') +
        (bool.fromEnvironment('SEED_PRICE_BUG') ? 400 : 0),
    ignoreAvailability: bool.fromEnvironment('SEED_AVAILABILITY_BUG'),
    truncateNameTo: int.fromEnvironment('SEED_NAME_TRUNCATE'),
    showDiscountWhenZero: bool.fromEnvironment('SEED_DISCOUNT_BUG'),
    currencySymbol: String.fromEnvironment(
      'SEED_CURRENCY_SYMBOL',
      defaultValue: 'Rs ',
    ),
    cartTotalIgnoresDeliveryFee: bool.fromEnvironment('SEED_CART_TOTAL_BUG'),
    renderImageWhenNull: bool.fromEnvironment('SEED_NULL_IMAGE_BUG'),
  );

  /// No defects at all. What a correct build does.
  static const Defects none = Defects();

  /// The set in force. Mutable only so a widget test can drive the
  /// matrix; a shipped build never assigns it.
  static Defects current = fromEnvironment;

  /// Whether anything at all is seeded, for the banner on screen.
  bool get isClean =>
      priceOffBy == 0 &&
      !ignoreAvailability &&
      truncateNameTo == 0 &&
      !showDiscountWhenZero &&
      currencySymbol == 'Rs ' &&
      !cartTotalIgnoresDeliveryFee &&
      !renderImageWhenNull;

  @override
  String toString() => isClean ? 'Defects.none' : 'Defects(seeded)';
}
