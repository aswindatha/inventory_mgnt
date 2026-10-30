import '../../data/models/enums.dart';

/// Arguments for the cart-automation vendor page.
class VendorWebViewArgs {
  const VendorWebViewArgs({
    required this.url,
    required this.title,
    this.vendor,
    this.cartItemId,
  });

  final String url;
  final String title;
  final Vendor? vendor;

  /// When present, the screen records `added_to_cart` against this row once the
  /// vendor page confirms the add.
  final String? cartItemId;
}
