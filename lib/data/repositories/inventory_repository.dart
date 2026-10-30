import 'package:drift/drift.dart' hide Component;
import 'package:uuid/uuid.dart';

import '../../core/failures.dart';
import '../local/app_database.dart';
import '../models/enums.dart';
import '../models/inventory.dart';
import '../remote/sync_service.dart';

/// Inventories and the components they hold.
///
/// Every write is local-first: the cache is updated immediately so the UI is
/// responsive and works offline, then a [PendingOps] row is queued and an
/// opportunistic push is attempted. Nothing here blocks on the network.
class InventoryRepository {
  InventoryRepository(this._db, this._sync);

  final AppDatabase _db;
  final SyncService _sync;

  static const _uuid = Uuid();

  /// Sensible opening value for a new component so it does not immediately read
  /// as low-stock at zero.
  static const num defaultLowStockThreshold = 5;

  // ===========================================================================
  // Inventories
  // ===========================================================================

  Stream<List<InventorySummary>> watchSummaries() => _db.watchInventorySummaries();

  Stream<Inventory?> watchInventory(String id) => _db.watchInventory(id);

  Future<Inventory> createInventory({
    required String companyId,
    required String userId,
    required String name,
    String? locationNote,
  }) async {
    if (name.trim().isEmpty) {
      throw const ValidationFailure('Inventory name is required.');
    }

    final inventory = Inventory(
      id: _uuid.v4(),
      companyId: companyId,
      name: name.trim(),
      locationNote: locationNote?.trim().isEmpty ?? true ? null : locationNote!.trim(),
      createdBy: userId,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );

    await _db.into(_db.cachedInventories).insert(
      CachedInventoriesCompanion.insert(
        id: inventory.id,
        companyId: inventory.companyId,
        name: inventory.name,
        locationNote: Value(inventory.locationNote),
        createdBy: Value(inventory.createdBy),
        createdAt: inventory.createdAt,
        updatedAt: inventory.updatedAt,
        syncStatus: Value(SyncStatus.pendingCreate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'insert',
      target: 'inventories',
      rowId: inventory.id,
      payload: inventory.toInsertMap(companyId, userId),
    );
    await _sync.push();

    return inventory;
  }

  Future<void> updateInventory({
    required String id,
    required String name,
    String? locationNote,
  }) async {
    if (name.trim().isEmpty) {
      throw const ValidationFailure('Inventory name is required.');
    }

    final cleanNote = locationNote?.trim();
    await (_db.update(_db.cachedInventories)..where((t) => t.id.equals(id))).write(
      CachedInventoriesCompanion(
        name: Value(name.trim()),
        locationNote: Value(cleanNote?.isEmpty ?? true ? null : cleanNote),
        updatedAt: Value(DateTime.now().toUtc()),
        syncStatus: Value(SyncStatus.pendingUpdate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'update',
      target: 'inventories',
      rowId: id,
      payload: {
        'name': name.trim(),
        'location_note': cleanNote?.isEmpty ?? true ? null : cleanNote,
      },
    );
    await _sync.push();
  }

  /// Deletes an inventory and, by cascade, every component inside it. Owner and
  /// admin only — the RLS policy rejects it for members.
  Future<void> deleteInventory(String id) async {
    await (_db.delete(_db.cachedInventories)..where((t) => t.id.equals(id))).go();
    await (_db.delete(_db.cachedComponents)..where((t) => t.inventoryId.equals(id))).go();

    await _db.enqueue(kind: 'delete', target: 'inventories', rowId: id);
    await _sync.push();
  }

  // ===========================================================================
  // Components
  // ===========================================================================

  Stream<List<Component>> watchComponents(String inventoryId, {String search = ''}) =>
      _db.watchComponents(inventoryId, search: search);

  Stream<Component?> watchComponent(String id) => _db.watchComponent(id);

  Future<Component?> componentByMpn(String inventoryId, String mpn) =>
      _db.componentByMpn(inventoryId, mpn);

  /// Creates a component. `mpn` must be unique within the inventory — the same
  /// part may exist independently in another inventory.
  Future<Component> addComponent({
    required String inventoryId,
    required String mpn,
    required String name,
    String? manufacturer,
    String? footprint,
    String? dimensions,
    String? imageUrl,
    num quantity = 0,
    String unit = 'pcs',
    num? lowStockThreshold,
  }) async {
    final cleanMpn = mpn.trim();
    if (cleanMpn.isEmpty) {
      throw const ValidationFailure('Manufacturer part number is required.');
    }
    if (name.trim().isEmpty) {
      throw const ValidationFailure('Component name is required.');
    }
    if (quantity < 0) {
      throw const ValidationFailure('Quantity cannot be negative.');
    }

    final existing = await _db.componentByMpn(inventoryId, cleanMpn);
    if (existing != null) {
      throw ValidationFailure(
        'This inventory already has a component with MPN "$cleanMpn".',
      );
    }

    final now = DateTime.now().toUtc();
    final component = Component(
      id: _uuid.v4(),
      inventoryId: inventoryId,
      mpn: cleanMpn,
      name: name.trim(),
      manufacturer: manufacturer?.trim().isEmpty ?? true ? null : manufacturer!.trim(),
      footprint: footprint?.trim().isEmpty ?? true ? null : footprint!.trim(),
      dimensions: dimensions?.trim().isEmpty ?? true ? null : dimensions!.trim(),
      imageUrl: imageUrl,
      quantity: quantity,
      unit: unit.trim().isEmpty ? 'pcs' : unit.trim(),
      lowStockThreshold: lowStockThreshold ?? defaultLowStockThreshold,
      createdAt: now,
      updatedAt: now,
    );

    await _db.into(_db.cachedComponents).insert(
      CachedComponentsCompanion.insert(
        id: component.id,
        inventoryId: component.inventoryId,
        mpn: component.mpn,
        name: component.name,
        manufacturer: Value(component.manufacturer),
        footprint: Value(component.footprint),
        dimensions: Value(component.dimensions),
        imageUrl: Value(component.imageUrl),
        quantity: Value(component.quantity.toDouble()),
        unit: Value(component.unit),
        lowStockThreshold: Value(component.lowStockThreshold.toDouble()),
        createdAt: now,
        updatedAt: now,
        syncStatus: Value(SyncStatus.pendingCreate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'insert',
      target: 'components',
      rowId: component.id,
      payload: component.toInsertMap(inventoryId),
    );
    await _sync.push();

    return component;
  }

  /// Edits metadata only. Quantity is not accepted here — use [adjustQuantity].
  Future<void> updateComponent({
    required String id,
    required String mpn,
    required String name,
    String? manufacturer,
    String? footprint,
    String? dimensions,
    String? imageUrl,
    required String unit,
    required num lowStockThreshold,
  }) async {
    if (mpn.trim().isEmpty) {
      throw const ValidationFailure('Manufacturer part number is required.');
    }
    if (name.trim().isEmpty) {
      throw const ValidationFailure('Component name is required.');
    }

    final cleanMpn = mpn.trim();
    final current = await _db.componentById(id);
    if (current == null) {
      throw const NotFoundFailure('That component no longer exists.');
    }

    if (cleanMpn != current.mpn) {
      final clash = await _db.componentByMpn(current.inventoryId, cleanMpn);
      if (clash != null && clash.id != id) {
        throw ValidationFailure(
          'This inventory already has a component with MPN "$cleanMpn".',
        );
      }
    }

    await (_db.update(_db.cachedComponents)..where((t) => t.id.equals(id))).write(
      CachedComponentsCompanion(
        mpn: Value(cleanMpn),
        name: Value(name.trim()),
        manufacturer: Value(manufacturer?.trim().isEmpty ?? true ? null : manufacturer!.trim()),
        footprint: Value(footprint?.trim().isEmpty ?? true ? null : footprint!.trim()),
        dimensions: Value(dimensions?.trim().isEmpty ?? true ? null : dimensions!.trim()),
        imageUrl: Value(imageUrl),
        unit: Value(unit.trim().isEmpty ? 'pcs' : unit.trim()),
        lowStockThreshold: Value(lowStockThreshold.toDouble()),
        updatedAt: Value(DateTime.now().toUtc()),
        syncStatus: Value(SyncStatus.pendingUpdate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'update',
      target: 'components',
      rowId: id,
      payload: {
        'mpn': cleanMpn,
        'name': name.trim(),
        'manufacturer': manufacturer?.trim().isEmpty ?? true ? null : manufacturer!.trim(),
        'footprint': footprint?.trim().isEmpty ?? true ? null : footprint!.trim(),
        'dimensions': dimensions?.trim().isEmpty ?? true ? null : dimensions!.trim(),
        'image_url': imageUrl,
        'unit': unit.trim().isEmpty ? 'pcs' : unit.trim(),
        'low_stock_threshold': lowStockThreshold,
      },
    );
    await _sync.push();
  }

  Future<void> deleteComponent(String id) async {
    await (_db.delete(_db.cachedComponents)..where((t) => t.id.equals(id))).go();
    await _db.enqueue(kind: 'delete', target: 'components', rowId: id);
    await _sync.push();
  }

  /// Records a device-local copy of the component image. Never synced.
  Future<void> setLocalImagePath(String componentId, String? path) async {
    await (_db.update(_db.cachedComponents)..where((t) => t.id.equals(componentId)))
        .write(CachedComponentsCompanion(localImagePath: Value(path)));
  }

  // ===========================================================================
  // Stock
  // ===========================================================================

  /// Moves stock by [changeQty] (signed) and writes an audit row.
  ///
  /// This is a server-side RPC, not a table write, because the quantity change
  /// and its `stock_transactions` entry must land in one transaction. It is
  /// queued like any other operation, and the local quantity is updated
  /// optimistically so the UI reflects the change immediately.
  ///
  /// Throws [ValidationFailure] locally if the change would drive stock
  /// negative, so the common case fails fast without a round trip.
  Future<void> adjustQuantity({
    required String componentId,
    required num changeQty,
    TransactionReason reason = TransactionReason.manualAdjust,
    String? projectId,
  }) async {
    if (changeQty == 0) {
      throw const ValidationFailure('Enter a non-zero adjustment.');
    }

    final current = await _db.componentById(componentId);
    if (current == null) {
      throw const NotFoundFailure('That component no longer exists.');
    }

    final next = current.quantity + changeQty;
    if (next < 0) {
      throw ValidationFailure(
        'Only ${current.quantity} ${current.unit} in stock — cannot remove '
        '${changeQty.abs()}.',
      );
    }

    await (_db.update(_db.cachedComponents)..where((t) => t.id.equals(componentId)))
        .write(
      CachedComponentsCompanion(
        quantity: Value(next.toDouble()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );

    await _db.enqueue(
      kind: 'rpc',
      target: 'adjust_component_quantity',
      rowId: componentId,
      payload: {
        'p_component_id': componentId,
        'p_change_qty': changeQty,
        'p_reason': reason.wire,
        'p_project_id': projectId,
      },
    );

    await _sync.push();
  }

  Stream<List<StockTransaction>> watchTransactions(String componentId) =>
      _db.watchTransactions(componentId);

  /// Refreshes the audit trail from the server for one component.
  Future<void> refreshTransactions(String componentId) async {
    try {
      await _sync.pullTransactionsFor(componentId);
    } on AppFailure {
      // The trail is supplementary; a failure here must not break the screen.
    }
  }
}
