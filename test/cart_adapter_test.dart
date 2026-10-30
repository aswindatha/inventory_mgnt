import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as parser;
import 'package:inventorymgnt/data/models/enums.dart';
import 'package:inventorymgnt/services/cart/cart_adapters.dart';

/// A WooCommerce single-product page, which exposes the product id on the form.
const _wooProductPage = '''
<!DOCTYPE html>
<html><body>
<div class="product">
  <h1 class="product_title">LM358DR Dual Op-Amp</h1>
  <form class="cart" method="post">
    <input type="hidden" name="add-to-cart" value="48213">
    <button type="submit" name="add-to-cart" value="48213">Add to cart</button>
  </form>
</div>
</body></html>
''';

/// A WooCommerce page whose theme only carries the id on the button.
const _wooButtonOnlyPage = '''
<html><body>
  <button class="single_add_to_cart_button" name="add-to-cart" value="991">Add</button>
</body></html>
''';

/// A WooCommerce page with no add-to-cart signal at all.
const _wooNoIdPage = '''
<html><body><h1>LM358DR</h1><p>Discontinued</p></body></html>
''';

/// A Shopify product page with the canonical variant form.
const _shopifyProductPage = '''
<!DOCTYPE html>
<html><body>
  <h1>ESP32-WROOM-32</h1>
  <form action="/cart/add" method="post" id="product-form">
    <input type="hidden" name="id" value="44551234567890">
    <button type="submit">Add to cart</button>
  </form>
</body></html>
''';

/// A Shopify page using a radio-based variant picker. The `html` package's
/// querySelector throws UnimplementedError on `:checked`, so this fixture is the
/// regression guard for that.
const _shopifyRadioVariantPage = '''
<!DOCTYPE html>
<html><body>
  <h1>ESP32-WROOM-32</h1>
  <variant-selects>
    <input type="radio" name="id" value="44551234567890">
    <input type="radio" name="id" value="44551234567891">
  </variant-selects>
</body></html>
''';

/// A Shopify page using a select-based variant picker.
const _shopifySelectVariantPage = '''
<html><body>
  <select name="id">
    <option value="99887766554433">Dev board</option>
  </select>
</body></html>
''';

void main() {
  group('WooCommerce add-to-cart target resolution', () {
    final adapter = WooCommerceCartAdapter();

    test('reads the product id from the cart form', () {
      final doc = parser.parse(_wooProductPage);
      expect(adapter.extractAddTarget(doc), '48213');
    });

    test('falls back to the submit button value', () {
      final doc = parser.parse(_wooButtonOnlyPage);
      expect(adapter.extractAddTarget(doc), '991');
    });

    test('returns null when the page has no add-to-cart signal', () {
      // Returning null is what keeps the app from inventing a URL that would
      // silently fail in the user's browser.
      final doc = parser.parse(_wooNoIdPage);
      expect(adapter.extractAddTarget(doc), isNull);
    });

    test('targets the Robu vendor', () {
      expect(adapter.vendor, Vendor.robu);
    });
  });

  group('Shopify add-to-cart target resolution', () {
    final adapter = ShopifyCartAdapter();

    test('reads the variant id from the product form', () {
      final doc = parser.parse(_shopifyProductPage);
      expect(adapter.extractAddTarget(doc), '44551234567890');
    });

    test('returns null when there is no variant id', () {
      final doc = parser.parse('<html><body><h1>Sold out</h1></body></html>');
      expect(adapter.extractAddTarget(doc), isNull);
    });

    test('reads a radio-based variant picker without throwing', () {
      // `:checked` is not implemented by package:html and used to throw here.
      final doc = parser.parse(_shopifyRadioVariantPage);
      expect(adapter.extractAddTarget(doc), '44551234567890');
    });

    test('reads a select-based variant picker', () {
      final doc = parser.parse(_shopifySelectVariantPage);
      expect(adapter.extractAddTarget(doc), '99887766554433');
    });

    test('targets the Robocraze vendor', () {
      expect(adapter.vendor, Vendor.robocraze);
    });
  });

  group('cart preparation', () {
    test('an unavailable preparation carries a reason and no URL', () {
      const preparation = CartPreparation(
        kind: CartPreparationKind.unavailable,
        message: 'No cached product link for this vendor.',
      );

      expect(preparation.isDirect, isFalse);
      expect(preparation.url, isNull);
      expect(preparation.message, isNotNull);
    });

    test('a direct preparation is the only kind reported as ready', () {
      const direct = CartPreparation(
        kind: CartPreparationKind.directUrl,
        url: 'https://robu.in/?add-to-cart=1&quantity=2',
      );
      const manual = CartPreparation(
        kind: CartPreparationKind.productPageOnly,
        url: 'https://robu.in/product/x/',
      );

      expect(direct.isDirect, isTrue);
      expect(manual.isDirect, isFalse);
    });
  });
}
