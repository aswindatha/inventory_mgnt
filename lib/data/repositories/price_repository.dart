import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/env.dart';
import '../../services/scraper/scrape_result.dart';
import '../../services/scraper/scraper_registry.dart';
import '../local/app_database.dart';
import '../models/enums.dart';
import '../models/vendor.dart';
import '../remote/sync_service.dart';

/// Owns the `vendor_price_cache` lifecycle: read from cache, refresh when stale.
///
/// The cache exists so opening a Component Details screen does not hammer vendor
/// storefronts (spec §5). A screen open with a fresh cache entry performs zero
/// network calls.
class PriceRepository {
  PriceRepository(this._db, this._sync, this._registry);

  final AppDatabase _db;
  final SyncService _sync;
  final ScraperRegistry _registry;

  static const _uuid = Uuid();

  List<Vendor> get supportedVendors => _registry.supportedVendors;

  Stream<List<VendorPrice>> watchPrices(String componentId) =>
      _db.watchVendorPrices(componentId);

  Future<List<VendorPrice>> pricesFor(String componentId) =>
      _db.vendorPricesFor(componentId);

  /// Cache-first read: returns the stored row if it is fresher than
  /// [AppConfig.priceCacheTtl], otherwise scrapes and stores a new one.
  ///
  /// [force] skips the freshness check for an explicit user-initiated refresh.
  Future<VendorPrice?> getOrRefresh({
    required String componentId,
    required String mpn,
    required Vendor vendor,
    bool force = false,
  }) async {
    final cached = (await _db.vendorPricesFor(componentId))
        .where((p) => p.vendor == vendor)
        .firstOrNull;

    if (!force && cached != null && !cached.isStale()) {
      return cached;
    }

    if (!_registry.supports(vendor)) return cached;

    final result = await _registry.scrape(vendor, mpn);
    if (result == null) return cached;

    return _store(componentId, result);
  }

  /// Scrapes every supported vendor for one component, sequentially so we do not
  /// fire a burst of requests at the same storefront.
  Future<List<ScrapeResult>> refreshAll({
    required String componentId,
    required String mpn,
  }) async {
    final results = <ScrapeResult>[];
    for (final vendor in supportedVendors) {
      final result = await _registry.scrape(vendor, mpn);
      if (result == null) continue;
      results.add(result);
      await _store(componentId, result);
    }
    return results;
  }

  /// Persists a scrape result to the local cache and queues the remote upsert.
  ///
  /// A blocked or errored scrape still writes a row, with `price`/`in_stock`
  /// left null. That is deliberate: it records *when* we last tried, so the UI
  /// can say "could not check" instead of retrying on every rebuild.
  Future<VendorPrice> _store(String componentId, ScrapeResult result) async {
    final now = DateTime.now().toUtc();

    final existing = (await _db.vendorPricesFor(componentId))
        .where((p) => p.vendor == result.vendor)
        .firstOrNull;

    final price = VendorPrice(
      id: existing?.id ?? _uuid.v4(),
      componentId: componentId,
      vendor: result.vendor,
      price: result.price,
      currency: result.currency,
      inStock: result.inStock,
      productUrl: result.productUrl ?? existing?.productUrl,
      fetchedAt: now,
      updatedAt: now,
    );

    await _db.into(_db.cachedVendorPrices).insert(
      CachedVendorPricesCompanion.insert(
        id: price.id,
        componentId: price.componentId,
        vendor: price.vendor.wire,
        price: Value(price.price?.toDouble()),
        currency: Value(price.currency),
        inStock: Value(price.inStock),
        productUrl: Value(price.productUrl),
        fetchedAt: now,
        updatedAt: now,
        syncStatus: Value(
          existing == null ? SyncStatus.pendingCreate.wire : SyncStatus.pendingUpdate.wire,
        ),
      ),
      mode: InsertMode.insertOrReplace,
    );

    // Only the successful fields are pushed. A blocked scrape must not overwrite
    // a previously known-good price on the server with nulls.
    final payload = <String, Object?>{
      'component_id': componentId,
      'vendor': price.vendor.wire,
      'price': result.price,
      'currency': price.currency,
      'in_stock': result.inStock,
      'product_url': price.productUrl,
      'fetched_at': now.toIso8601String(),
    };

    await _db.enqueue(
      kind: 'upsert',
      target: 'vendor_price_cache',
      rowId: price.id,
      payload: payload,
    );
    await _sync.push();

    return price;
  }
}
