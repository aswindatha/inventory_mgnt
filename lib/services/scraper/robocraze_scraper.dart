import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../../data/models/enums.dart';
import 'product_candidate.dart';
import 'scrape_result.dart';
import 'vendor_http.dart';

/// Robocraze price/stock scraper.
///
/// Robocraze runs a Shopify storefront. Shopify themes vary far more than
/// WooCommerce's, so this leans on JSON-LD first and treats the DOM pass as the
/// fallback — the inverse of [RobuScraper].
class RobocrazeScraper extends VendorPriceScraper {
  RobocrazeScraper({super.dio}) : super(vendor: Vendor.robocraze);

  @override
  String searchUrl(String mpn) =>
      'https://robocraze.com/search?q=${Uri.encodeQueryComponent(mpn)}';

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
      ...candidatesFromJsonLd(htmlText),
      ..._candidatesFromCards(doc),
    ];

    final best = pickBestCandidate(candidates, mpn);
    if (best == null) return ScrapeResult.notFound(vendor, mpn);

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
      '.product-card, .product-item, .grid__item .card, .card-wrapper, li.grid__item',
    );

    return cards.map((card) {
      final title =
          firstText(card, [
            '.card__heading',
            '.product-card__title',
            '.product-item__title',
            'h3',
            'h2',
            '.title',
          ]) ??
          '';

      final url = firstAttr(card, [
        'a.card__heading',
        'a.product-card__link',
        'a.product-item__link',
        'a',
      ], 'href');

      final priceText = firstText(card, [
        '.price__regular .price-item',
        '.price-item--regular',
        '.price',
        '.product-card__price',
        '.money',
      ]);

      final stockText = firstText(card, [
        '.product-card__availability',
        '.availability',
        '.stock',
        '.badge',
      ]);

      // Shopify marks sold-out cards with a badge rather than a stock element.
      final soldOutBadge = card.querySelector('.badge')?.text.toLowerCase();
      final isSoldOut = soldOutBadge != null && soldOutBadge.contains('sold out');

      return ProductCandidate(
        title: title,
        url: url,
        price: parsePriceText(priceText),
        inStock: parseStockText(stockText) ?? (isSoldOut ? false : null),
      );
    }).toList();
  }
}
