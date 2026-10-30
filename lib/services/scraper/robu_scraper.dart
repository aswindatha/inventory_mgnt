import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../../data/models/enums.dart';
import 'product_candidate.dart';
import 'scrape_result.dart';
import 'vendor_http.dart';

/// Robu.in price/stock scraper (spec §5).
///
/// Robu runs WooCommerce, so the search page exposes `.woocommerce-Price-amount`
/// and `.stock` per product card. A JSON-LD pass runs alongside as a fallback
/// because theme changes are common and the structured data is more stable.
class RobuScraper extends VendorPriceScraper {
  RobuScraper({super.dio}) : super(vendor: Vendor.robu);

  @override
  String searchUrl(String mpn) =>
      'https://robu.in/?s=${Uri.encodeQueryComponent(mpn)}&post_type=product';

  /// Fetches and parses the search page for [mpn].
  ///
  /// Never throws for a vendor-side problem — the failure is returned as a
  /// [ScrapeResult] with a non-success [ScrapeOutcome] so callers can render
  /// "Price unavailable (Bot Protection)" instead of crashing.
  @override
  Future<ScrapeResult> fetchPrice(String mpn) async {
    final trimmed = mpn.trim();
    if (trimmed.isEmpty) {
      return ScrapeResult.notFound(vendor, mpn);
    }

    final response = await http.fetchHtml(searchUrl(trimmed), trimmed);
    if (response.failure != null) return response.failure!;

    return parseSearchPage(response.body!, trimmed);
  }

  ScrapeResult parseSearchPage(String htmlText, String mpn) {
    final doc = parser.parse(htmlText);

    final candidates = <ProductCandidate>[
      ..._candidatesFromCards(doc),
      ...candidatesFromJsonLd(htmlText),
    ];

    final best = pickBestCandidate(candidates, mpn);
    if (best == null) return ScrapeResult.notFound(vendor, mpn);

    // A match with neither a price nor a stock signal is not a usable result.
    if (best.price == null && best.inStock == null) {
      return ScrapeResult.parseError(
        vendor,
        mpn,
        'Found "${best.title}" but could not read its price or stock.',
      );
    }

    return ScrapeResult(
      vendor: vendor,
      mpn: mpn,
      outcome: ScrapeOutcome.success,
      price: best.price,
      inStock: best.inStock,
      productUrl: best.url,
      productTitle: best.title,
    );
  }

  List<ProductCandidate> _candidatesFromCards(dom.Document doc) {
    final cards = doc.querySelectorAll(
      'ul.products li.product, .products .product, li.product, .product-small',
    );

    return cards.map((card) {
      final title =
          firstText(card, [
            '.woocommerce-loop-product__title',
            'h2',
            'h3',
            '.product-title',
          ]) ??
          '';

      final url =
          firstAttr(card, [
            'a.woocommerce-LoopProduct-link',
            'a.woocommerce-loop-product__link',
            'h2 a',
            'h3 a',
            'a',
          ], 'href');

      final priceText = firstText(card, [
        '.woocommerce-Price-amount',
        '.price ins .woocommerce-Price-amount',
        '.price',
      ]);

      final stockText = firstText(card, ['.stock', '.stock-status', '.availability']);

      // WooCommerce marks out-of-stock cards with a class even when the .stock
      // element is absent.
      final classes = card.classes;
      final outOfStock = classes.contains('outofstock');
      final inStockClass = classes.contains('instock');

      return ProductCandidate(
        title: title,
        url: url,
        price: parsePriceText(priceText),
        inStock: parseStockText(stockText) ??
            (outOfStock ? false : (inStockClass ? true : null)),
      );
    }).toList();
  }
}
