import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/failures.dart';
import '../../core/json.dart';
import '../local/app_database.dart';
import '../models/enums.dart';
import 'backend.dart';

class SyncOutcome {
  const SyncOutcome({
    required this.ok,
    this.pushed = 0,
    this.failed = 0,
    this.pulled = 0,
    this.error,
  });

  final bool ok;
  final int pushed;
  final int failed;
  final int pulled;
  final String? error;

  static const SyncOutcome offline = SyncOutcome(
    ok: false,
    error: 'Offline. Changes are queued and will sync when you reconnect.',
  );
}

/// Keeps the local drift cache and the Supabase database in step.
///
/// Push-then-pull, deliberately in that order: local edits must reach the
/// server before a refresh overwrites the cache, otherwise unsynced work would
/// be reverted by its own pull.
class SyncService {
  SyncService(this._backend, this._db);

  final Backend _backend;
  final AppDatabase _db;

  /// Operations that keep failing for a *permanent* reason (a rejected write, a
  /// stock shortage) are left in the queue with their error recorded so the UI
  /// can show them, but they stop being retried after this many attempts.
  static const int maxAttempts = 5;

  bool get canSync => _backend.isConfigured && _backend.currentUserId != null;

  Future<SyncOutcome> sync() async {
    if (!canSync) return SyncOutcome.offline;

    var pushed = 0;
    var failed = 0;
    var pulled = 0;

    try {
      final pushResult = await push();
      pushed = pushResult.pushed;
      failed = pushResult.failed;
      pulled = await pull();
      return SyncOutcome(ok: true, pushed: pushed, failed: failed, pulled: pulled);
    } on AppFailure catch (e) {
      return SyncOutcome(ok: false, pushed: pushed, failed: failed, error: e.userMessage);
    }
  }

  // ===========================================================================
  // Push
  // ===========================================================================

  Future<({int pushed, int failed})> push() async {
    if (!canSync) return (pushed: 0, failed: 0);

    final ops = await _db.nextOps();
    var pushed = 0;
    var failed = 0;

    for (final op in ops) {
      if (op.attempts >= maxAttempts) continue;

      try {
        await _apply(op);
        await _db.deleteOp(op.id);
        await _markRowSynced(op.target, op.rowId);
        pushed++;
      } on AppFailure catch (e) {
        await _db.markOpFailed(op.id, e.userMessage);
        failed++;

        // A transient failure means the network is down; stop draining so we do
        // not burn through every queued op failing identically.
        if (e is NetworkFailure) break;
      }
    }

    return (pushed: pushed, failed: failed);
  }

  Future<void> _apply(PendingOp op) async {
    final payload = op.payload.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(op.payload) as Map);

    switch (op.kind) {
      case 'insert':
        await _backend.insertMany(op.target, [payload]);
      case 'update':
        if (op.rowId == null) {
          throw ValidationFailure('Queued update for ${op.target} has no row id.');
        }
        await _backend.update(op.target, op.rowId!, payload);
      case 'delete':
        if (op.rowId == null) {
          throw ValidationFailure('Queued delete for ${op.target} has no row id.');
        }
        await _backend.delete(op.target, op.rowId!);
      case 'upsert':
        // Only vendor_price_cache uses upsert today, and its real key is
        // (component_id, vendor) rather than id.
        await _backend.upsert(
          op.target,
          payload,
          onConflict: op.target == 'vendor_price_cache' ? 'component_id,vendor' : null,
        );
      case 'rpc':
        await _backend.rpc<Object?>(op.target, payload);
      default:
        throw ValidationFailure('Unknown queued operation "${op.kind}".');
    }
  }

  Future<void> _markRowSynced(String table, String? rowId) async {
    if (rowId == null) return;
    final status = Value(SyncStatus.synced.wire);

    await switch (table) {
      'inventories' =>
        (_db.update(_db.cachedInventories)..where((t) => t.id.equals(rowId)))
            .write(CachedInventoriesCompanion(syncStatus: status)),
      'components' =>
        (_db.update(_db.cachedComponents)..where((t) => t.id.equals(rowId)))
            .write(CachedComponentsCompanion(syncStatus: status)),
      'projects' =>
        (_db.update(_db.cachedProjects)..where((t) => t.id.equals(rowId)))
            .write(CachedProjectsCompanion(syncStatus: status)),
      'project_components' =>
        (_db.update(_db.cachedProjectComponents)..where((t) => t.id.equals(rowId)))
            .write(CachedProjectComponentsCompanion(syncStatus: status)),
      'vendor_price_cache' =>
        (_db.update(_db.cachedVendorPrices)..where((t) => t.id.equals(rowId)))
            .write(CachedVendorPricesCompanion(syncStatus: status)),
      'cart_items' =>
        (_db.update(_db.cachedCartItems)..where((t) => t.id.equals(rowId)))
            .write(CachedCartItemsCompanion(syncStatus: status)),
      _ => Future<void>.value(),
    };
  }

  // ===========================================================================
  // Pull
  // ===========================================================================

  /// Refreshes the cache from Supabase. Returns the number of rows written.
  ///
  /// Pending local rows are preserved: `replaceSynced` only deletes rows that
  /// have no queued operation against them.
  Future<int> pull() async {
    if (!canSync) return 0;

    var written = 0;

    // ---- company + members --------------------------------------------------
    final companies = await _backend.select('companies');
    await _db.replaceSynced(
      'companies',
      _db.cachedCompanies,
      companies.map(_companyCompanion).toList(),
    );
    written += companies.length;

    final members = await _backend.select('users', orderBy: 'email');
    await _db.replaceSynced('users', _db.cachedUsers, members.map(_userCompanion).toList());
    written += members.length;

    // ---- inventories --------------------------------------------------------
    final inventories = await _backend.select('inventories', orderBy: 'name');
    await _db.replaceSynced(
      'inventories',
      _db.cachedInventories,
      inventories.map(_inventoryCompanion).toList(),
    );
    written += inventories.length;

    // ---- components ---------------------------------------------------------
    // `local_image_path` is device-local and has no server column, so it is
    // merged back in from the existing cache before the refresh overwrites it.
    final cachedImagePaths = {
      for (final row in await _db.select(_db.cachedComponents).get())
        row.id: row.localImagePath,
    };

    final components = await _backend.select('components', orderBy: 'name');
    await _db.replaceSynced(
      'components',
      _db.cachedComponents,
      components
          .map((row) => _componentCompanion(row, cachedImagePaths[row['id'] as String?]))
          .toList(),
    );
    written += components.length;

    // ---- projects -----------------------------------------------------------
    final projects = await _backend.select('projects', orderBy: 'created_at', ascending: false);
    await _db.replaceSynced('projects', _db.cachedProjects, projects.map(_projectCompanion).toList());
    written += projects.length;

    final projectComponents = await _backend.select('project_components');
    await _db.replaceSynced(
      'project_components',
      _db.cachedProjectComponents,
      projectComponents.map(_projectComponentCompanion).toList(),
    );
    written += projectComponents.length;

    // ---- vendor price cache -------------------------------------------------
    final prices = await _backend.select('vendor_price_cache', orderBy: 'fetched_at', ascending: false);
    await _db.replaceSynced(
      'vendor_price_cache',
      _db.cachedVendorPrices,
      prices.map(_vendorPriceCompanion).toList(),
    );
    written += prices.length;

    // ---- cart items (own rows only; RLS scopes this) ------------------------
    final cartItems = await _backend.select('cart_items', orderBy: 'created_at', ascending: false);
    await _db.replaceSynced('cart_items', _db.cachedCartItems, cartItems.map(_cartItemCompanion).toList());
    written += cartItems.length;

    return written;
  }

  /// Pulls the audit trail for one component on demand. The trail is not part of
  /// the routine refresh because it grows without bound and is only ever read
  /// from the Component Details screen.
  Future<int> pullTransactionsFor(String componentId) async {
    if (!canSync) return 0;

    final rows = await _backend.select(
      'stock_transactions',
      equals: {'component_id': componentId},
      orderBy: 'created_at',
      ascending: false,
      limit: 100,
    );

    await (_db.delete(_db.cachedStockTransactions)
          ..where((t) => t.componentId.equals(componentId)))
        .go();

    await _db.batch((b) {
      b.insertAll(
        _db.cachedStockTransactions,
        rows.map(_stockTransactionCompanion).toList(),
        mode: InsertMode.insertOrReplace,
      );
    });

    return rows.length;
  }

  // ===========================================================================
  // Row -> companion mappers
  // ===========================================================================

  static CachedCompaniesCompanion _companyCompanion(Map<String, dynamic> m) =>
      CachedCompaniesCompanion.insert(
        id: parseString(m['id']),
        name: parseString(m['name']),
        inviteCode: parseString(m['invite_code']),
        createdAt: parseTimestamp(m['created_at']),
        updatedAt: parseTimestamp(m['created_at']),
      );

  static CachedUsersCompanion _userCompanion(Map<String, dynamic> m) =>
      CachedUsersCompanion.insert(
        id: parseString(m['id']),
        companyId: Value(parseStringOrNull(m['company_id'])),
        email: parseString(m['email']),
        displayName: Value(parseStringOrNull(m['display_name'])),
        role: Value(parseString(m['role'], fallback: 'member')),
        createdAt: parseTimestamp(m['created_at']),
        updatedAt: parseTimestamp(m['updated_at'] ?? m['created_at']),
      );

  static CachedInventoriesCompanion _inventoryCompanion(Map<String, dynamic> m) =>
      CachedInventoriesCompanion.insert(
        id: parseString(m['id']),
        companyId: parseString(m['company_id']),
        name: parseString(m['name']),
        locationNote: Value(parseStringOrNull(m['location_note'])),
        createdBy: Value(parseStringOrNull(m['created_by'])),
        createdAt: parseTimestamp(m['created_at']),
        updatedAt: parseTimestamp(m['updated_at'] ?? m['created_at']),
      );

  static CachedComponentsCompanion _componentCompanion(
    Map<String, dynamic> m,
    String? localImagePath,
  ) => CachedComponentsCompanion.insert(
    id: parseString(m['id']),
    inventoryId: parseString(m['inventory_id']),
    mpn: parseString(m['mpn']),
    name: parseString(m['name']),
    manufacturer: Value(parseStringOrNull(m['manufacturer'])),
    footprint: Value(parseStringOrNull(m['footprint'])),
    dimensions: Value(parseStringOrNull(m['dimensions'])),
    imageUrl: Value(parseStringOrNull(m['image_url'])),
    localImagePath: Value(localImagePath),
    quantity: Value(parseNum(m['quantity']).toDouble()),
    unit: Value(parseString(m['unit'], fallback: 'pcs')),
    lowStockThreshold: Value(parseNum(m['low_stock_threshold']).toDouble()),
    createdAt: parseTimestamp(m['created_at']),
    updatedAt: parseTimestamp(m['updated_at'] ?? m['created_at']),
  );

  static CachedProjectsCompanion _projectCompanion(Map<String, dynamic> m) =>
      CachedProjectsCompanion.insert(
        id: parseString(m['id']),
        companyId: parseString(m['company_id']),
        name: parseString(m['name']),
        description: Value(parseStringOrNull(m['description'])),
        status: Value(parseString(m['status'], fallback: 'planning')),
        createdBy: Value(parseStringOrNull(m['created_by'])),
        createdAt: parseTimestamp(m['created_at']),
        updatedAt: parseTimestamp(m['updated_at'] ?? m['created_at']),
      );

  static CachedProjectComponentsCompanion _projectComponentCompanion(
    Map<String, dynamic> m,
  ) => CachedProjectComponentsCompanion.insert(
    id: parseString(m['id']),
    projectId: parseString(m['project_id']),
    componentId: parseString(m['component_id']),
    inventoryId: parseString(m['inventory_id']),
    quantityRequired: Value(parseNum(m['quantity_required']).toDouble()),
    quantityAllocated: Value(parseNum(m['quantity_allocated']).toDouble()),
    description: Value(parseStringOrNull(m['description'])),
    status: Value(parseString(m['status'], fallback: 'planned')),
    createdAt: parseTimestamp(m['created_at']),
    updatedAt: parseTimestamp(m['updated_at'] ?? m['created_at']),
  );

  static CachedStockTransactionsCompanion _stockTransactionCompanion(
    Map<String, dynamic> m,
  ) => CachedStockTransactionsCompanion.insert(
    id: parseString(m['id']),
    componentId: parseString(m['component_id']),
    projectId: Value(parseStringOrNull(m['project_id'])),
    userId: Value(parseStringOrNull(m['user_id'])),
    changeQty: parseNum(m['change_qty']).toDouble(),
    reason: parseString(m['reason'], fallback: 'manual_adjust'),
    createdAt: parseTimestamp(m['created_at']),
  );

  static CachedVendorPricesCompanion _vendorPriceCompanion(Map<String, dynamic> m) =>
      CachedVendorPricesCompanion.insert(
        id: parseString(m['id']),
        componentId: parseString(m['component_id']),
        vendor: parseString(m['vendor']),
        price: Value(parseNumOrNull(m['price'])?.toDouble()),
        currency: Value(parseString(m['currency'], fallback: 'INR')),
        inStock: Value(parseBoolOrNull(m['in_stock'])),
        productUrl: Value(parseStringOrNull(m['product_url'])),
        fetchedAt: parseTimestamp(m['fetched_at']),
        updatedAt: parseTimestamp(m['updated_at'] ?? m['fetched_at']),
      );

  static CachedCartItemsCompanion _cartItemCompanion(Map<String, dynamic> m) =>
      CachedCartItemsCompanion.insert(
        id: parseString(m['id']),
        userId: parseString(m['user_id']),
        vendor: parseString(m['vendor']),
        componentId: parseString(m['component_id']),
        quantity: Value(parseNum(m['quantity'], fallback: 1).toDouble()),
        status: Value(parseString(m['status'], fallback: 'pending')),
        error: Value(parseStringOrNull(m['error'])),
        createdAt: parseTimestamp(m['created_at']),
        updatedAt: parseTimestamp(m['updated_at'] ?? m['created_at']),
      );
}
