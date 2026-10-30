import '../../core/config/env.dart';
import '../../data/models/enums.dart';
import 'cart_adapters.dart';

/// One component to push into a vendor cart.
class CartRequest {
  const CartRequest({
    required this.componentId,
    required this.componentName,
    required this.mpn,
    required this.vendor,
    required this.quantity,
    this.productUrl,
  });

  final String componentId;
  final String componentName;
  final String mpn;
  final Vendor vendor;
  final num quantity;

  /// Cached product URL from `vendor_price_cache`. Without it there is nothing
  /// to open and the item cannot be prepared.
  final String? productUrl;
}

class CartRequestResult {
  const CartRequestResult({
    required this.request,
    required this.preparation,
  });

  final CartRequest request;
  final CartPreparation preparation;

  String get componentId => request.componentId;
  Vendor get vendor => request.vendor;
  bool get isDirect => preparation.isDirect;

  String? get message => preparation.message;
  String? get url => preparation.url;
}

/// Per-vendor rollup for a batch run.
class CartVendorSummary {
  const CartVendorSummary({required this.vendor, required this.results});

  final Vendor vendor;
  final List<CartRequestResult> results;

  int get total => results.length;
  int get prepared => results.where((r) => r.isDirect).length;
  int get needsManual => results
      .where((r) => r.preparation.kind == CartPreparationKind.productPageOnly)
      .length;
  int get unavailable => results
      .where((r) => r.preparation.kind == CartPreparationKind.unavailable)
      .length;

  bool get allPrepared => prepared == total && total > 0;
}

/// Resolves vendor product pages into URLs that add items to a cart.
///
/// Deliberately does **not** claim to have added anything to a cart. A mobile
/// HTTP client cannot populate the cart in the user's browser session, so the
/// most this layer can honestly do is resolve a URL that does the add when the
/// user opens it in their own session. The UI opens that URL in a WebView and
/// only then records the item as added (spec §6).
class CartAutomationService {
  CartAutomationService({
    List<CartAdapter>? adapters,
    this.spacing = AppConfig.cartRequestSpacing,
  }) : _adapters = {
         for (final adapter in adapters ?? _defaultAdapters) adapter.vendor: adapter,
       };

  static final List<CartAdapter> _defaultAdapters = [
    WooCommerceCartAdapter(),
    ShopifyCartAdapter(),
  ];

  final Map<Vendor, CartAdapter> _adapters;

  /// Politeness delay between requests within one batch.
  final Duration spacing;

  List<Vendor> get supportedVendors => _adapters.keys.toList(growable: false);

  bool supports(Vendor vendor) => _adapters.containsKey(vendor);

  /// Resolves one request. Never throws — an unsupported vendor, a missing
  /// product URL and a bot-blocked page are all returned as preparations with a
  /// non-direct kind.
  Future<CartRequestResult> prepare(CartRequest request) async {
    final productUrl = request.productUrl;

    if (productUrl == null || productUrl.trim().isEmpty) {
      return CartRequestResult(
        request: request,
        preparation: const CartPreparation(
          kind: CartPreparationKind.unavailable,
          message: 'No cached product link for this vendor. Refresh its price first.',
        ),
      );
    }

    final adapter = _adapters[request.vendor];
    if (adapter == null) {
      return CartRequestResult(
        request: request,
        preparation: CartPreparation(
          kind: CartPreparationKind.unavailable,
          message: 'Cart automation is not supported for ${request.vendor.label}.',
        ),
      );
    }

    try {
      final preparation = await adapter.prepare(productUrl, request.quantity);
      return CartRequestResult(request: request, preparation: preparation);
    } catch (e) {
      return CartRequestResult(
        request: request,
        preparation: CartPreparation(
          kind: CartPreparationKind.unavailable,
          message: 'Could not read the product page: $e',
        ),
      );
    }
  }

  /// Resolves many requests, grouped by vendor and staggered.
  ///
  /// Requests are spaced by [_spacing] so a bulk run does not look like an
  /// attack to the vendor's bot protection — which would fail the whole batch
  /// rather than one item (spec §6: "rate-limit and stagger requests").
  Future<List<CartVendorSummary>> prepareBatch(List<CartRequest> requests) async {
    final byVendor = <Vendor, List<CartRequest>>{};
    for (final request in requests) {
      byVendor.putIfAbsent(request.vendor, () => []).add(request);
    }

    final summaries = <CartVendorSummary>[];

    for (final entry in byVendor.entries) {
      final results = <CartRequestResult>[];
      for (var i = 0; i < entry.value.length; i++) {
        if (i > 0) await Future<void>.delayed(spacing);
        results.add(await prepare(entry.value[i]));
      }
      summaries.add(CartVendorSummary(vendor: entry.key, results: results));
    }

    return summaries;
  }
}
