import 'package:dio/dio.dart';

import '../../core/config/env.dart';
import '../../core/failures.dart';
import '../../data/models/enums.dart';
import 'scrape_result.dart';

/// Shared HTTP behaviour for every vendor integration — the price scrapers and
/// the cart adapters alike.
///
/// Both talk to the same storefronts, so both present the same identity: the
/// desktop User-Agent from [AppConfig.scraperUserAgent], the same timeouts, and
/// the same rule that a non-2xx status is a *result* rather than an exception.
///
/// Composition rather than inheritance, so a caller that is not itself a vendor
/// (a cart adapter) can still borrow the behaviour.
class VendorHttpClient {
  VendorHttpClient({required this.vendor, Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: AppConfig.scraperTimeout,
              receiveTimeout: AppConfig.scraperTimeout,
              sendTimeout: AppConfig.scraperTimeout,
              headers: {
                'User-Agent': AppConfig.scraperUserAgent,
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
                'Accept-Language': 'en-IN,en;q=0.9',
                'Cache-Control': 'no-cache',
              },
              // Let 403/404/503 through so we can classify them instead of
              // letting dio throw a generic exception.
              validateStatus: (status) => status != null && status < 600,
              followRedirects: true,
              maxRedirects: 5,
            ),
          );

  final Vendor vendor;
  final Dio dio;

  /// Cloudflare and friends return these to non-browser clients. Treated as
  /// "unknown", never as "out of stock".
  static const Set<int> botProtectionStatuses = {401, 403, 429, 503};

  bool isBotProtection(int? status) =>
      status != null && botProtectionStatuses.contains(status);

  /// Fetches a URL and returns the body, or a classified failure.
  Future<({String? body, ScrapeResult? failure})> fetchHtml(
    String url,
    String mpn,
  ) async {
    try {
      final response = await dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );

      final status = response.statusCode;
      if (isBotProtection(status)) {
        return (
          body: null,
          failure: ScrapeResult.blocked(
            vendor,
            mpn,
            message: 'Bot protection (HTTP $status).',
          ),
        );
      }
      if (status == 404) {
        return (body: null, failure: ScrapeResult.notFound(vendor, mpn));
      }
      if (status != null && status >= 400) {
        return (
          body: null,
          failure: ScrapeResult.networkError(
            vendor,
            mpn,
            'HTTP $status from ${vendor.host}.',
          ),
        );
      }

      final body = response.data;
      if (body == null || body.trim().isEmpty) {
        return (
          body: null,
          failure: ScrapeResult.parseError(vendor, mpn, 'Empty response body.'),
        );
      }

      return (body: body, failure: null);
    } on DioException catch (e) {
      return (body: null, failure: ScrapeResult.networkError(vendor, mpn, _describe(e)));
    } catch (e) {
      return (body: null, failure: ScrapeResult.networkError(vendor, mpn, e.toString()));
    }
  }

  String _describe(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.sendTimeout => 'Timed out reaching ${vendor.host}.',
    DioExceptionType.connectionError => 'Could not reach ${vendor.host}.',
    _ => e.message ?? 'Request to ${vendor.host} failed.',
  };

  /// Maps a scrape outcome onto an [AppFailure] for callers that want to surface
  /// it as an error rather than a result.
  static AppFailure toFailure(ScrapeResult result) => switch (result.outcome) {
    ScrapeOutcome.blocked => NetworkFailure(result.message ?? 'Bot protection.'),
    ScrapeOutcome.networkError => NetworkFailure(result.message ?? 'Network error.'),
    ScrapeOutcome.notFound => NotFoundFailure(result.message ?? 'Not found.'),
    ScrapeOutcome.parseError =>
      UnexpectedFailure(result.message ?? 'Could not parse page.'),
    ScrapeOutcome.success => const UnexpectedFailure('Not a failure.'),
  };
}

/// Contract every vendor price scraper implements, so new vendors can be added
/// without touching call sites (spec §5: "extensible to more vendors").
abstract class VendorPriceScraper {
  VendorPriceScraper({required this.vendor, Dio? dio})
    : http = VendorHttpClient(vendor: vendor, dio: dio);

  final Vendor vendor;
  final VendorHttpClient http;

  /// The vendor search URL for a part number.
  String searchUrl(String mpn);

  /// Scrapes price and stock for [mpn].
  ///
  /// Implementations must not throw for vendor-side failures — return a
  /// [ScrapeResult] whose outcome is not [ScrapeOutcome.success] instead.
  Future<ScrapeResult> fetchPrice(String mpn);
}

/// Parses a storefront price string such as `₹1,234.56` or `Rs. 89` into a
/// number. Returns null when there is no plausible number in the text.
num? parsePriceText(String? raw) {
  if (raw == null) return null;

  final match = RegExp(r'(\d[\d,]*\.?\d*)').firstMatch(raw);
  if (match == null) return null;

  final normalised = match.group(1)!.replaceAll(',', '');
  return num.tryParse(normalised);
}

/// Interprets a WooCommerce `.stock` element. Returns null when the text does
/// not say anything conclusive.
bool? parseStockText(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;

  final text = raw.toLowerCase();
  if (text.contains('out of stock') ||
      text.contains('unavailable') ||
      text.contains('sold out')) {
    return false;
  }
  if (text.contains('in stock') ||
      text.contains('available') ||
      text.contains('add to cart')) {
    return true;
  }
  return null;
}
