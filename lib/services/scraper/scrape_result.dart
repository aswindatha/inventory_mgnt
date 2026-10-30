import '../../data/models/enums.dart';

/// How a scrape attempt ended.
///
/// [blocked] and [notFound] are distinct on purpose: "Cloudflare refused us" and
/// "this vendor does not stock the part" lead to different UI and different user
/// actions, and conflating them would tell the user a part is unavailable when
/// it may be sitting in stock.
enum ScrapeOutcome {
  success,
  notFound,
  blocked,
  networkError,
  parseError;

  bool get isFailure => this != ScrapeOutcome.success;

  String get label => switch (this) {
    ScrapeOutcome.success => 'OK',
    ScrapeOutcome.notFound => 'Not listed',
    ScrapeOutcome.blocked => 'Price unavailable (Bot Protection)',
    ScrapeOutcome.networkError => 'Network error',
    ScrapeOutcome.parseError => 'Could not read page',
  };
}

class ScrapeResult {
  const ScrapeResult({
    required this.vendor,
    required this.mpn,
    required this.outcome,
    this.price,
    this.inStock,
    this.productUrl,
    this.productTitle,
    this.currency = 'INR',
    this.message,
  });

  final Vendor vendor;
  final String mpn;
  final ScrapeOutcome outcome;

  /// Null whenever the page did not yield a trustworthy number — including the
  /// blocked case. A fabricated price is worse than no price.
  final num? price;

  /// Null means "unknown", not "out of stock".
  final bool? inStock;

  final String? productUrl;
  final String? productTitle;
  final String currency;
  final String? message;

  bool get isSuccess => outcome == ScrapeOutcome.success;

  factory ScrapeResult.blocked(Vendor vendor, String mpn, {String? message}) =>
      ScrapeResult(
        vendor: vendor,
        mpn: mpn,
        outcome: ScrapeOutcome.blocked,
        message: message ?? 'The vendor blocked the request (bot protection).',
      );

  factory ScrapeResult.notFound(Vendor vendor, String mpn) => ScrapeResult(
    vendor: vendor,
    mpn: mpn,
    outcome: ScrapeOutcome.notFound,
    message: 'No matching product found.',
  );

  factory ScrapeResult.networkError(Vendor vendor, String mpn, String message) =>
      ScrapeResult(
        vendor: vendor,
        mpn: mpn,
        outcome: ScrapeOutcome.networkError,
        message: message,
      );

  factory ScrapeResult.parseError(Vendor vendor, String mpn, String message) =>
      ScrapeResult(
        vendor: vendor,
        mpn: mpn,
        outcome: ScrapeOutcome.parseError,
        message: message,
      );

  @override
  String toString() =>
      'ScrapeResult(${vendor.wire}, $mpn, ${outcome.name}, price: $price, stock: $inStock)';
}
