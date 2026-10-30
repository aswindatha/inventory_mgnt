import '../../data/models/enums.dart';
import 'robocraze_scraper.dart';
import 'robu_scraper.dart';
import 'scrape_result.dart';
import 'vendor_http.dart';

/// Maps [Vendor] to its scraper.
///
/// Adding a vendor means writing one [VendorPriceScraper] and registering it
/// here; nothing else in the app needs to change.
class ScraperRegistry {
  ScraperRegistry({List<VendorPriceScraper>? scrapers})
    : _scrapers = {
        for (final scraper in scrapers ?? _defaultScrapers)
          scraper.vendor: scraper,
      };

  static final List<VendorPriceScraper> _defaultScrapers = [
    RobuScraper(),
    RobocrazeScraper(),
  ];

  final Map<Vendor, VendorPriceScraper> _scrapers;

  /// Vendors that actually have a scraper. `Vendor.other` never will.
  List<Vendor> get supportedVendors => _scrapers.keys.toList(growable: false);

  VendorPriceScraper? forVendor(Vendor vendor) => _scrapers[vendor];

  bool supports(Vendor vendor) => _scrapers.containsKey(vendor);

  /// Scrapes [mpn] at [vendor]. Returns null when no scraper is registered,
  /// which the UI renders as "not supported" rather than as a failure.
  Future<ScrapeResult?> scrape(Vendor vendor, String mpn) {
    final scraper = _scrapers[vendor];
    if (scraper == null) return Future.value(null);
    return scraper.fetchPrice(mpn);
  }
}
