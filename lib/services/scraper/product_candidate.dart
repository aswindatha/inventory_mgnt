import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

/// A product listing pulled out of a vendor search page.
class ProductCandidate {
  const ProductCandidate({
    required this.title,
    this.url,
    this.price,
    this.inStock,
  });

  final String title;
  final String? url;
  final num? price;
  final bool? inStock;
}

/// Normalises a part number for fuzzy comparison: `RC-1234/A` -> `RC1234A`.
///
/// Vendor titles almost never reproduce the MPN with the manufacturer's exact
/// punctuation, so a literal `contains` check misses real matches.
String normaliseMpn(String mpn) =>
    mpn.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Picks the candidate whose title best matches [mpn].
///
/// Returns null when nothing scores above zero — better to report "not listed"
/// than to attach some unrelated product's price to the user's part.
ProductCandidate? pickBestCandidate(
  List<ProductCandidate> candidates,
  String mpn, {
  double minScore = 0.45,
}) {
  if (candidates.isEmpty) return null;

  final target = normaliseMpn(mpn);
  if (target.isEmpty) return candidates.first;

  ProductCandidate? best;
  var bestScore = 0.0;

  for (final candidate in candidates) {
    final score = _score(candidate.title, target);
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }

  return bestScore >= minScore ? best : null;
}

double _score(String title, String target) {
  final normalisedTitle = normaliseMpn(title);

  if (normalisedTitle.contains(target)) {
    // An exact token match beats a substring buried in a longer string.
    return normalisedTitle == target ? 1.0 : 0.9;
  }

  // Fall back to how much of the part number appears, in order.
  var matched = 0;
  var cursor = 0;
  for (final rune in target.split('')) {
    final idx = normalisedTitle.indexOf(rune, cursor);
    if (idx >= 0) {
      matched++;
      cursor = idx + 1;
    }
  }

  return target.isEmpty ? 0 : (matched / target.length) * 0.7;
}

/// Extracts `schema.org/Product` entries from JSON-LD blocks.
///
/// A useful fallback for themes that change their CSS classes, since most
/// storefronts keep their structured data stable for SEO.
List<ProductCandidate> candidatesFromJsonLd(String htmlText) {
  final doc = parser.parse(htmlText);
  final candidates = <ProductCandidate>[];

  for (final script in doc.querySelectorAll('script[type="application/ld+json"]')) {
    final raw = script.text.trim();
    if (raw.isEmpty) continue;

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      continue;
    }

    for (final node in _flattenJsonLd(decoded)) {
      final type = node['@type'];
      final isProduct = type is String
          ? type.toLowerCase() == 'product'
          : type is List && type.any((t) => t.toString().toLowerCase() == 'product');
      if (!isProduct) continue;

      final offers = node['offers'];
      final offer = offers is List ? (offers.isEmpty ? null : offers.first) : offers;

      candidates.add(
        ProductCandidate(
          title: (node['name'] ?? '').toString(),
          url: node['url']?.toString(),
          price: offer is Map ? _priceFromOffer(offer) : null,
          inStock: offer is Map ? _stockFromOffer(offer) : null,
        ),
      );
    }
  }

  return candidates;
}

Iterable<Map<String, Object?>> _flattenJsonLd(Object? decoded) sync* {
  if (decoded is Map) {
    final map = decoded.map((k, v) => MapEntry(k.toString(), v));
    if (map.containsKey('@type')) yield map.cast<String, Object?>();

    final graph = map['@graph'];
    if (graph is List) {
      for (final node in graph) {
        yield* _flattenJsonLd(node);
      }
    }
    for (final value in map.values) {
      if (value is List || value is Map) yield* _flattenJsonLd(value);
    }
  } else if (decoded is List) {
    for (final item in decoded) {
      yield* _flattenJsonLd(item);
    }
  }
}

num? _priceFromOffer(Map offer) {
  for (final key in ['price', 'lowPrice', 'highPrice']) {
    final value = offer[key];
    if (value is num) return value;
    if (value is String) {
      final parsed = num.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

bool? _stockFromOffer(Map offer) {
  final availability = offer['availability']?.toString().toLowerCase();
  if (availability == null) return null;
  if (availability.contains('instock') || availability.contains('in_stock')) return true;
  if (availability.contains('outofstock') ||
      availability.contains('out_of_stock') ||
      availability.contains('soldout')) {
    return false;
  }
  if (availability.contains('preorder') || availability.contains('backorder')) return false;
  return null;
}

/// Reads the first non-empty text from a set of CSS selectors.
String? firstText(dom.Element root, List<String> selectors) {
  for (final selector in selectors) {
    final el = root.querySelector(selector);
    final text = el?.text.trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return null;
}

/// Reads the first non-empty attribute from a set of CSS selectors.
String? firstAttr(dom.Element root, List<String> selectors, String attribute) {
  for (final selector in selectors) {
    final value = root.querySelector(selector)?.attributes[attribute]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}
