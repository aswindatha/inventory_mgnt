import '../../core/config/env.dart';
import '../../core/json.dart';
import 'enums.dart';
import 'inventory.dart';

/// Cached scrape result for one component at one vendor.
///
/// [price] and [inStock] are both nullable on purpose: "we could not find out"
/// (bot protection, network failure) has to be representable and distinct from
/// "out of stock". Collapsing those two into `false` would let the UI claim a
/// part is unavailable when it may well be in stock.
class VendorPrice {
  const VendorPrice({
    required this.id,
    required this.componentId,
    required this.vendor,
    this.price,
    this.currency = 'INR',
    this.inStock,
    this.productUrl,
    required this.fetchedAt,
    required this.updatedAt,
  });

  final String id;
  final String componentId;
  final Vendor vendor;
  final num? price;
  final String currency;
  final bool? inStock;
  final String? productUrl;
  final DateTime fetchedAt;
  final DateTime updatedAt;

  bool isStale({Duration ttl = AppConfig.priceCacheTtl}) =>
      DateTime.now().toUtc().difference(fetchedAt.toUtc()) > ttl;

  /// Nothing at all could be read from the vendor page.
  bool get isUnavailable => price == null && inStock == null;

  /// A price came back but no stock signal, or vice versa — partial data.
  bool get isPartial => !isUnavailable && (price == null || inStock == null);

  bool get isBlocked => isUnavailable;

  factory VendorPrice.fromMap(Map<String, dynamic> map) => VendorPrice(
    id: parseString(map['id']),
    componentId: parseString(map['component_id']),
    vendor: Vendor.fromWire(parseStringOrNull(map['vendor'])),
    price: parseNumOrNull(map['price']),
    currency: parseString(map['currency'], fallback: 'INR'),
    inStock: parseBoolOrNull(map['in_stock']),
    productUrl: parseStringOrNull(map['product_url']),
    fetchedAt: parseTimestamp(map['fetched_at']),
    updatedAt: parseTimestamp(map['updated_at']),
  );

  Map<String, Object?> toUpsertMap(String componentId) => {
    'component_id': componentId,
    'vendor': vendor.wire,
    'price': price,
    'currency': currency,
    'in_stock': inStock,
    'product_url': productUrl,
    'fetched_at': fetchedAt.toIso8601String(),
  };

  VendorPrice copyWith({
    num? price,
    bool? inStock,
    String? productUrl,
    DateTime? fetchedAt,
    bool clearPrice = false,
    bool clearStock = false,
  }) => VendorPrice(
    id: id,
    componentId: componentId,
    vendor: vendor,
    price: clearPrice ? null : (price ?? this.price),
    currency: currency,
    inStock: clearStock ? null : (inStock ?? this.inStock),
    productUrl: productUrl ?? this.productUrl,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    updatedAt: updatedAt,
  );
}

/// One queued "push this into the vendor's real cart" action (spec §6).
class CartItem {
  const CartItem({
    required this.id,
    required this.userId,
    required this.vendor,
    required this.componentId,
    this.quantity = 1,
    this.status = CartItemStatus.pending,
    this.error,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String userId;
  final Vendor vendor;
  final String componentId;
  final num quantity;
  final CartItemStatus status;

  /// Populated when [status] is [CartItemStatus.failed] — e.g. "Bot protection
  /// (403)", "No cached product URL".
  final String? error;

  final DateTime createdAt;
  final DateTime updatedAt;

  factory CartItem.fromMap(Map<String, dynamic> map) => CartItem(
    id: parseString(map['id']),
    userId: parseString(map['user_id']),
    vendor: Vendor.fromWire(parseStringOrNull(map['vendor'])),
    componentId: parseString(map['component_id']),
    quantity: parseNum(map['quantity'], fallback: 1),
    status: CartItemStatus.fromWire(parseStringOrNull(map['status'])),
    error: parseStringOrNull(map['error']),
    createdAt: parseTimestamp(map['created_at']),
    updatedAt: parseTimestamp(map['updated_at']),
  );

  Map<String, Object?> toInsertMap(String userId) => {
    'id': id,
    'user_id': userId,
    'vendor': vendor.wire,
    'component_id': componentId,
    'quantity': quantity,
    'status': status.wire,
    'error': error,
  };

  CartItem copyWith({CartItemStatus? status, String? error, bool clearError = false}) =>
      CartItem(
        id: id,
        userId: userId,
        vendor: vendor,
        componentId: componentId,
        quantity: quantity,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

/// A cart row joined with what the Purchasing screen needs to render it.
class CartReviewItem {
  const CartReviewItem({
    required this.item,
    required this.component,
    required this.inventoryName,
    this.productUrl,
  });

  final CartItem item;
  final Component component;
  final String inventoryName;
  final String? productUrl;

  bool get canRetry => item.status != CartItemStatus.addedToCart;
}
