import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

import '../../data/models/enums.dart';
import '../scraper/vendor_http.dart';

/// How an item can be pushed into a vendor cart.
enum CartPreparationKind {
  /// A URL exists that adds the item to the cart when visited. Opening it in the
  /// user's own session (the WebView) is a real, verifiable add.
  directUrl,

  /// Only the product page could be resolved; the user must add it themselves.
  productPageOnly,

  /// The product page could not be read at all.
  unavailable,
}

class CartPreparation {
  const CartPreparation({
    required this.kind,
    this.url,
    this.message,
    this.productTitle,
  });

  final CartPreparationKind kind;

  /// For [CartPreparationKind.directUrl] this is the add-to-cart URL; for
  /// [CartPreparationKind.productPageOnly] it is the product page.
  final String? url;

  final String? message;
  final String? productTitle;

  bool get isDirect => kind == CartPreparationKind.directUrl;
}

/// Turns a cached product URL into a URL that adds the item to a cart.
///
/// Both target vendors expose a URL-based add-to-cart, which is the only
/// mechanism that survives contact with a mobile client: an HTTP request from
/// the app cannot populate the cart in the *user's* browser session, so the
/// resolved URL is opened in a WebView where the session is theirs.
abstract class CartAdapter {
  CartAdapter({required this.vendor, Dio? dio})
    : http = VendorHttpClient(vendor: vendor, dio: dio);

  final Vendor vendor;
  final VendorHttpClient http;

  /// Resolves [productUrl] into something that can add [quantity] to a cart.
  Future<CartPreparation> prepare(String productUrl, num quantity);

  /// Reads the product id / variant id out of a product page.
  String? extractAddTarget(dom.Document doc);
}

/// Robu runs WooCommerce, whose add-to-cart is a query parameter on any page:
/// `/?add-to-cart=<productId>&quantity=<n>`.
class WooCommerceCartAdapter extends CartAdapter {
  WooCommerceCartAdapter({super.dio}) : super(vendor: Vendor.robu);

  @override
  Future<CartPreparation> prepare(String productUrl, num quantity) async {
    final response = await http.fetchHtml(productUrl, productUrl);
    if (response.failure != null) {
      return CartPreparation(
        kind: CartPreparationKind.unavailable,
        message: response.failure!.message,
      );
    }

    final doc = parser.parse(response.body!);
    final title = doc.querySelector('h1.product_title')?.text.trim() ??
        doc.querySelector('h1')?.text.trim();
    final productId = extractAddTarget(doc);

    if (productId == null) {
      return CartPreparation(
        kind: CartPreparationKind.productPageOnly,
        url: productUrl,
        productTitle: title,
        message: 'Could not read the product id; add it from the product page.',
      );
    }

    final origin = Uri.tryParse(productUrl)?.origin;
    if (origin == null) {
      return CartPreparation(
        kind: CartPreparationKind.productPageOnly,
        url: productUrl,
        productTitle: title,
        message: 'Could not determine the vendor origin.',
      );
    }

    return CartPreparation(
      kind: CartPreparationKind.directUrl,
      url: '$origin/?add-to-cart=$productId&quantity=${quantity.toInt()}',
      productTitle: title,
    );
  }

  @override
  String? extractAddTarget(dom.Document doc) {
    // WooCommerce exposes the id in several places depending on the theme.
    for (final selector in [
      'input[name="add-to-cart"]',
      'button[name="add-to-cart"]',
      'form.cart input[name="product_id"]',
    ]) {
      final value = doc.querySelector(selector)?.attributes['value']?.trim();
      if (value != null && value.isNotEmpty) return value;
    }

    for (final selector in ['.add_to_cart_button', 'a.add_to_cart_button']) {
      final value = doc.querySelector(selector)?.attributes['data-product_id']?.trim();
      if (value != null && value.isNotEmpty) return value;
    }

    // Some themes only carry the id on the form element itself.
    final formId = doc.querySelector('form.cart')?.attributes['data-product_id']?.trim();
    if (formId != null && formId.isNotEmpty) return formId;

    return null;
  }
}

/// Robocraze runs Shopify, which supports a permalink add-to-cart:
/// `/cart/<variantId>:<quantity>`.
class ShopifyCartAdapter extends CartAdapter {
  ShopifyCartAdapter({super.dio}) : super(vendor: Vendor.robocraze);

  @override
  Future<CartPreparation> prepare(String productUrl, num quantity) async {
    final response = await http.fetchHtml(productUrl, productUrl);
    if (response.failure != null) {
      return CartPreparation(
        kind: CartPreparationKind.unavailable,
        message: response.failure!.message,
      );
    }

    final doc = parser.parse(response.body!);
    final title = doc.querySelector('h1')?.text.trim();
    final variantId = extractAddTarget(doc);

    if (variantId == null) {
      return CartPreparation(
        kind: CartPreparationKind.productPageOnly,
        url: productUrl,
        productTitle: title,
        message: 'Could not read the variant id; add it from the product page.',
      );
    }

    final origin = Uri.tryParse(productUrl)?.origin;
    if (origin == null) {
      return CartPreparation(
        kind: CartPreparationKind.productPageOnly,
        url: productUrl,
        productTitle: title,
        message: 'Could not determine the vendor origin.',
      );
    }

    return CartPreparation(
      kind: CartPreparationKind.directUrl,
      url: '$origin/cart/$variantId:${quantity.toInt()}',
      productTitle: title,
    );
  }

  @override
  String? extractAddTarget(dom.Document doc) {
    // The canonical Shopify product form.
    final formValue = doc
        .querySelector('form[action*="/cart/add"] input[name="id"]')
        ?.attributes['value']
        ?.trim();
    if (formValue != null && formValue.isNotEmpty) return formValue;

    // A select-based variant picker.
    final optionValue =
        doc.querySelector('select[name="id"] option')?.attributes['value']?.trim();
    if (optionValue != null && optionValue.isNotEmpty) return optionValue;

    // A radio-based variant picker. `:checked` is deliberately avoided — the
    // `html` package's querySelector throws UnimplementedError on that pseudo
    // class, so the first radio with a value is taken instead.
    for (final radio in doc.querySelectorAll('input[type="radio"][name="id"]')) {
      final value = radio.attributes['value']?.trim();
      if (value != null && value.isNotEmpty) return value;
    }

    // Dawn and friends embed the product JSON in a script tag.
    final meta = doc.querySelector(
      'script[type="application/json"][data-product-json], '
      'script#ProductJson-product-template',
    );
    final raw = meta?.text;
    if (raw != null) {
      final match = RegExp(r'"id"\s*:\s*(\d{6,})').firstMatch(raw);
      if (match != null) return match.group(1);
    }

    return null;
  }
}
