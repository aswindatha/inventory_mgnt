import 'package:collection/collection.dart';
import 'package:drift/drift.dart' hide Component;
import 'package:uuid/uuid.dart';

import '../../services/cart/cart_automation_service.dart';
import '../../services/cart/cart_adapters.dart';
import '../local/app_database.dart';
import '../models/enums.dart';
import '../models/inventory.dart';
import '../models/vendor.dart';
import '../remote/sync_service.dart';

/// A queued cart row paired with the URL that will actually add it.
///
/// The UI needs both halves: the id to record the outcome against, and the URL
/// to open in the WebView.
class PreparedCartItem {
  const PreparedCartItem({
    required this.cartItemId,
    required this.componentId,
    required this.componentName,
    required this.mpn,
    required this.vendor,
    required this.kind,
    this.url,
    this.message,
  });

  final String cartItemId;
  final String componentId;
  final String componentName;
  final String mpn;
  final Vendor vendor;
  final CartPreparationKind kind;
  final String? url;
  final String? message;

  bool get isReady => kind == CartPreparationKind.directUrl;
  bool get needsManual => kind == CartPreparationKind.productPageOnly;
  bool get isUnavailable => kind == CartPreparationKind.unavailable;

  /// True when there is something to open in a browser.
  bool get canOpen => url != null && url!.isNotEmpty;
}

/// Owns the `cart_items` queue behind the Purchasing screen.
///
/// The lifecycle is deliberately conservative:
///   pending -> added_to_cart  (only after the vendor page confirmed the add)
///           -> failed         (with a reason)
///
/// Nothing here marks an item as added on the strength of having *tried*. That
/// is the "do not silently pretend success" rule from spec §6 expressed as code.
class CartRepository {
  CartRepository(this._db, this._sync, this._automation);

  final AppDatabase _db;
  final SyncService _sync;
  final CartAutomationService _automation;

  static const _uuid = Uuid();

  List<Vendor> get supportedVendors => _automation.supportedVendors;

  Stream<List<CartReviewItem>> watchCartItems() => _db.watchCartItems();

  Future<CartItem?> byId(String id) => _db.cartItemById(id);

  // ===========================================================================
  // Queueing
  // ===========================================================================

  /// Queues [components] for [vendor] and resolves each into a cart-add URL.
  ///
  /// The returned list is what the UI needs to open each item in a WebView and
  /// to report a per-vendor outcome ("3 ready, 1 blocked") rather than one
  /// opaque pass/fail.
  Future<List<PreparedCartItem>> queueAndPrepare({
    required String userId,
    required List<Component> components,
    required Vendor vendor,
    num quantityPerItem = 1,
  }) async {
    if (components.isEmpty) return const [];

    final requests = <CartRequest>[];
    final itemIds = <String, String>{}; // componentId -> cartItemId

    for (final component in components) {
      final cartItemId = await _queueItem(
        userId: userId,
        component: component,
        vendor: vendor,
        quantity: quantityPerItem,
      );
      itemIds[component.id] = cartItemId;

      requests.add(
        CartRequest(
          componentId: component.id,
          componentName: component.name,
          mpn: component.mpn,
          vendor: vendor,
          quantity: quantityPerItem,
          productUrl: await _cachedProductUrl(component.id, vendor),
        ),
      );
    }

    final summaries = await _automation.prepareBatch(requests);
    final prepared = <PreparedCartItem>[];

    // Record the resolution outcome against each queued row. An item that only
    // resolved to a product page stays `pending` — it is not a failure, it just
    // needs the user to finish it by hand.
    for (final summary in summaries) {
      for (final result in summary.results) {
        final cartItemId = itemIds[result.componentId];
        if (cartItemId == null) continue;

        if (result.preparation.kind == CartPreparationKind.unavailable) {
          await markFailed(cartItemId, result.message ?? 'Could not prepare this item.');
        } else {
          await _updateLocal(
            cartItemId,
            status: CartItemStatus.pending,
            error: result.isDirect
                ? null
                : (result.message ?? 'Add this one manually from the product page.'),
            clearError: result.isDirect,
          );
        }

        prepared.add(
          PreparedCartItem(
            cartItemId: cartItemId,
            componentId: result.componentId,
            componentName: result.request.componentName,
            mpn: result.request.mpn,
            vendor: result.vendor,
            kind: result.preparation.kind,
            url: result.preparation.url,
            message: result.preparation.message,
          ),
        );
      }
    }

    return prepared;
  }

  Future<String> _queueItem({
    required String userId,
    required Component component,
    required Vendor vendor,
    required num quantity,
  }) async {
    // Reuse an existing open row for the same component/vendor rather than
    // stacking duplicates every time the user taps "add all".
    final existing = (await _db.pendingCartItemsFor(vendor))
        .where((i) => i.componentId == component.id && i.status != CartItemStatus.addedToCart)
        .firstOrNull;

    if (existing != null) {
      await _updateLocal(existing.id, status: CartItemStatus.pending, error: null, clearError: true);
      return existing.id;
    }

    final now = DateTime.now().toUtc();
    final id = _uuid.v4();

    await _db.into(_db.cachedCartItems).insert(
      CachedCartItemsCompanion.insert(
        id: id,
        userId: userId,
        vendor: vendor.wire,
        componentId: component.id,
        quantity: Value(quantity.toDouble()),
        createdAt: now,
        updatedAt: now,
        syncStatus: Value(SyncStatus.pendingCreate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'insert',
      target: 'cart_items',
      rowId: id,
      payload: {
        'id': id,
        'user_id': userId,
        'vendor': vendor.wire,
        'component_id': component.id,
        'quantity': quantity,
        'status': CartItemStatus.pending.wire,
      },
    );
    await _sync.push();

    return id;
  }

  Future<String?> _cachedProductUrl(String componentId, Vendor vendor) async {
    final prices = await _db.vendorPricesFor(componentId);
    for (final price in prices) {
      if (price.vendor == vendor && (price.productUrl?.isNotEmpty ?? false)) {
        return price.productUrl;
      }
    }
    return null;
  }

  // ===========================================================================
  // Status transitions
  // ===========================================================================

  /// Marks an item as confirmed in the vendor cart.
  ///
  /// Only call this once the vendor page has actually confirmed the add — see
  /// `CartWebViewScreen`, which watches for the cart confirmation before
  /// recording it.
  Future<void> markAdded(String cartItemId) =>
      _updateLocal(cartItemId, status: CartItemStatus.addedToCart, error: null, clearError: true);

  Future<void> markFailed(String cartItemId, String reason) =>
      _updateLocal(cartItemId, status: CartItemStatus.failed, error: reason);

  Future<void> resetToPending(String cartItemId) =>
      _updateLocal(cartItemId, status: CartItemStatus.pending, error: null, clearError: true);

  Future<void> remove(String cartItemId) async {
    await (_db.delete(_db.cachedCartItems)..where((t) => t.id.equals(cartItemId))).go();
    await _db.enqueue(kind: 'delete', target: 'cart_items', rowId: cartItemId);
    await _sync.push();
  }

  /// Clears everything already confirmed, so the review screen shows only work
  /// that still needs doing.
  Future<void> clearAdded() async {
    final added = await (_db.select(_db.cachedCartItems)
          ..where((t) => t.status.equals(CartItemStatus.addedToCart.wire)))
        .get();

    for (final item in added) {
      await remove(item.id);
    }
  }

  Future<void> _updateLocal(
    String cartItemId, {
    required CartItemStatus status,
    String? error,
    bool clearError = false,
  }) async {
    await (_db.update(_db.cachedCartItems)..where((t) => t.id.equals(cartItemId))).write(
      CachedCartItemsCompanion(
        status: Value(status.wire),
        error: Value(clearError ? null : error),
        updatedAt: Value(DateTime.now().toUtc()),
        syncStatus: Value(SyncStatus.pendingUpdate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'update',
      target: 'cart_items',
      rowId: cartItemId,
      payload: {'status': status.wire, 'error': clearError ? null : error},
    );
    await _sync.push();
  }
}
