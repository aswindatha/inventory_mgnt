import 'package:flutter_test/flutter_test.dart';
import 'package:inventorymgnt/data/models/enums.dart';
import 'package:inventorymgnt/services/scraper/product_candidate.dart';
import 'package:inventorymgnt/services/scraper/robocraze_scraper.dart';
import 'package:inventorymgnt/services/scraper/robu_scraper.dart';
import 'package:inventorymgnt/services/scraper/scrape_result.dart';
import 'package:inventorymgnt/services/scraper/vendor_http.dart';

/// A trimmed WooCommerce search page with three product cards.
const _robuSearchHtml = '''
<!DOCTYPE html>
<html><body>
<ul class="products">
  <li class="product instock">
    <a class="woocommerce-LoopProduct-link" href="https://robu.in/product/lm358dr-opamp/">
      <h2 class="woocommerce-loop-product__title">LM358DR Dual Op-Amp SOIC-8</h2>
    </a>
    <span class="price">
      <span class="woocommerce-Price-amount amount">
        <bdi><span class="woocommerce-Price-currencySymbol">&#8377;</span>24.50</bdi>
      </span>
    </span>
    <p class="stock in-stock">In stock</p>
  </li>
  <li class="product outofstock">
    <a class="woocommerce-LoopProduct-link" href="https://robu.in/product/atmega328p/">
      <h2 class="woocommerce-loop-product__title">ATmega328P-PU Microcontroller</h2>
    </a>
    <span class="price">
      <span class="woocommerce-Price-amount amount">
        <bdi>&#8377;1,299.00</bdi>
      </span>
    </span>
    <p class="stock out-of-stock">Out of stock</p>
  </li>
  <li class="product instock">
    <a class="woocommerce-LoopProduct-link" href="https://robu.in/product/ne555/">
      <h2 class="woocommerce-loop-product__title">NE555 Timer IC DIP-8</h2>
    </a>
    <span class="price">
      <span class="woocommerce-Price-amount amount"><bdi>&#8377;9.00</bdi></span>
    </span>
    <p class="stock in-stock">In stock</p>
  </li>
</ul>
</body></html>
''';

/// A Shopify search page relying on JSON-LD, which is the more stable signal.
const _robocrazeSearchHtml = '''
<!DOCTYPE html>
<html><head>
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "Product",
  "name": "ESP32-WROOM-32 Development Board",
  "url": "https://robocraze.com/products/esp32-wroom-32",
  "offers": {
    "@type": "Offer",
    "price": "349.00",
    "priceCurrency": "INR",
    "availability": "https://schema.org/InStock"
  }
}
</script>
</head><body>
  <div class="product-card">
    <a class="card__heading" href="https://robocraze.com/products/esp32-wroom-32">
      <h3>ESP32-WROOM-32 Development Board</h3>
    </a>
    <span class="price"><span class="money">₹349.00</span></span>
  </div>
</body></html>
''';

void main() {
  group('price text parsing', () {
    test('reads a plain rupee amount', () {
      expect(parsePriceText('₹24.50'), 24.5);
    });

    test('strips thousands separators', () {
      expect(parsePriceText('₹1,299.00'), 1299);
    });

    test('handles the Rs. prefix', () {
      expect(parsePriceText('Rs. 89'), 89);
    });

    test('returns null when there is no number', () {
      expect(parsePriceText('Contact us for pricing'), isNull);
      expect(parsePriceText(null), isNull);
    });
  });

  group('stock text parsing', () {
    test('recognises in-stock phrasings', () {
      expect(parseStockText('In stock'), isTrue);
      expect(parseStockText('Add to cart'), isTrue);
    });

    test('recognises out-of-stock phrasings', () {
      expect(parseStockText('Out of stock'), isFalse);
      expect(parseStockText('Sold out'), isFalse);
    });

    test('returns null rather than guessing', () {
      // The whole point: "unknown" must stay distinct from "out of stock".
      expect(parseStockText('Ships in 3 days'), isNull);
      expect(parseStockText(''), isNull);
    });
  });

  group('MPN candidate matching', () {
    test('normalises punctuation away', () {
      expect(normaliseMpn('RC-1234/A'), 'RC1234A');
    });

    test('prefers the title containing the part number', () {
      final best = pickBestCandidate(
        const [
          ProductCandidate(title: 'NE555 Timer IC DIP-8', price: 9),
          ProductCandidate(title: 'LM358DR Dual Op-Amp SOIC-8', price: 24.5),
        ],
        'LM358DR',
      );
      expect(best?.title, contains('LM358DR'));
    });

    test('matches despite different punctuation in the title', () {
      final best = pickBestCandidate(
        const [ProductCandidate(title: 'ESP32 WROOM 32 Module', price: 349)],
        'ESP32-WROOM-32',
      );
      expect(best, isNotNull);
    });

    test('returns null rather than attaching an unrelated price', () {
      final best = pickBestCandidate(
        const [ProductCandidate(title: 'USB-C Cable 1m', price: 99)],
        'LM358DR',
      );
      expect(best, isNull);
    });

    test('returns null for an empty candidate list', () {
      expect(pickBestCandidate(const [], 'LM358DR'), isNull);
    });
  });

  group('Robu search page parsing', () {
    test('extracts price, stock, URL and title for a matching part', () {
      final result = RobuScraper().parseSearchPage(_robuSearchHtml, 'LM358DR');

      expect(result.outcome, ScrapeOutcome.success);
      expect(result.price, 24.5);
      expect(result.inStock, isTrue);
      expect(result.productUrl, 'https://robu.in/product/lm358dr-opamp/');
      expect(result.productTitle, contains('LM358DR'));
    });

    test('reads an out-of-stock card as out of stock, not unknown', () {
      final result = RobuScraper().parseSearchPage(_robuSearchHtml, 'ATmega328P-PU');

      expect(result.outcome, ScrapeOutcome.success);
      expect(result.inStock, isFalse);
      expect(result.price, 1299);
    });

    test('reports notFound when the part is absent from the page', () {
      final result = RobuScraper().parseSearchPage(_robuSearchHtml, 'NOT-A-REAL-PART-9000');

      expect(result.outcome, ScrapeOutcome.notFound);
      expect(result.price, isNull);
      expect(result.inStock, isNull);
    });

    test('never fabricates a price on an empty page', () {
      final result = RobuScraper().parseSearchPage('<html><body></body></html>', 'LM358DR');

      expect(result.outcome, ScrapeOutcome.notFound);
      expect(result.price, isNull);
    });
  });

  group('Robocraze search page parsing', () {
    test('reads a product from JSON-LD structured data', () {
      final result = RobocrazeScraper().parseSearchPage(
        _robocrazeSearchHtml,
        'ESP32-WROOM-32',
      );

      expect(result.outcome, ScrapeOutcome.success);
      expect(result.price, 349);
      expect(result.inStock, isTrue);
      expect(result.productUrl, 'https://robocraze.com/products/esp32-wroom-32');
    });

    test('reports notFound for an unmatched part number', () {
      final result = RobocrazeScraper().parseSearchPage(
        _robocrazeSearchHtml,
        'XYZ-999',
      );

      expect(result.outcome, ScrapeOutcome.notFound);
    });
  });

  group('bot protection classification', () {
    test('treats the usual block statuses as bot protection', () {
      final http = VendorHttpClient(vendor: Vendor.robu);
      for (final status in [401, 403, 429, 503]) {
        expect(http.isBotProtection(status), isTrue, reason: 'HTTP $status');
      }
    });

    test('does not mistake success or not-found for a block', () {
      final http = VendorHttpClient(vendor: Vendor.robu);
      expect(http.isBotProtection(200), isFalse);
      expect(http.isBotProtection(404), isFalse);
    });

    test('a blocked result carries no price and no stock signal', () {
      final result = ScrapeResult.blocked(Vendor.robu, 'LM358DR');

      expect(result.outcome, ScrapeOutcome.blocked);
      expect(result.price, isNull);
      expect(result.inStock, isNull);
      expect(result.outcome.label, 'Price unavailable (Bot Protection)');
    });
  });
}
