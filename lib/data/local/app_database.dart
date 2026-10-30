import 'dart:convert';

import 'package:drift/drift.dart' hide Component;

import '../models/company.dart';
import '../models/enums.dart';
import '../models/inventory.dart';
import '../models/project.dart';
import '../models/vendor.dart';
import 'connection/connection_stub.dart'
    if (dart.library.io) 'connection/connection_native.dart'
    if (dart.library.js_interop) 'connection/connection_web.dart';
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    CachedCompanies,
    CachedUsers,
    CachedInventories,
    CachedComponents,
    CachedProjects,
    CachedProjectComponents,
    CachedStockTransactions,
    CachedVendorPrices,
    CachedCartItems,
    PendingOps,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(openConnection());

  /// Test seam: build against an in-memory database.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 is the first shipped schema; nothing to migrate yet.
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  // ===========================================================================
  // Reads
  // ===========================================================================

  Stream<List<Inventory>> watchInventories() {
    final q = select(cachedInventories)
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.watch().map(
      (rows) => rows.map(_toInventory).toList(),
    );
  }

  /// Home-screen rollups: component count, low-stock count and total units per
  /// inventory, aggregated in SQL rather than by streaming every component.
  ///
  /// Written as raw SQL because the low-stock count needs a column-to-column
  /// comparison (`quantity <= low_stock_threshold`) inside an aggregate, which
  /// drift's expression API cannot key reliably enough to read back.
  Stream<List<InventorySummary>> watchInventorySummaries() {
    final invQuery = select(cachedInventories)
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);

    return invQuery.watch().asyncMap((inventories) async {
      final rows = await customSelect(
        'SELECT inventory_id, '
        '       COUNT(*) AS component_count, '
        '       COALESCE(SUM(quantity), 0) AS total_units, '
        '       COALESCE(SUM(CASE WHEN quantity <= low_stock_threshold THEN 1 ELSE 0 END), 0) '
        '         AS low_stock_count '
        '  FROM cached_components '
        ' GROUP BY inventory_id',
        readsFrom: {cachedComponents},
      ).get();

      final byInventory = {
        for (final row in rows)
          row.read<String>('inventory_id'): (
            count: row.read<int>('component_count'),
            // SUM over a REAL column comes back as a double; drift's QueryRow
            // has no mapping for `num`.
            units: row.read<double>('total_units'),
            low: row.read<int>('low_stock_count'),
          ),
      };

      return inventories.map((row) {
        final agg = byInventory[row.id];
        return InventorySummary(
          inventory: _toInventory(row),
          componentCount: agg?.count ?? 0,
          lowStockCount: agg?.low ?? 0,
          totalUnits: agg?.units ?? 0,
        );
      }).toList();
    });
  }

  Stream<Inventory?> watchInventory(String id) {
    final q = select(cachedInventories)..where((t) => t.id.equals(id));
    return q.watchSingleOrNull().map((row) => row == null ? null : _toInventory(row));
  }

  Stream<List<Component>> watchComponents(String inventoryId, {String search = ''}) {
    final q = select(cachedComponents)
      ..where((t) => t.inventoryId.equals(inventoryId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.name),
        (t) => OrderingTerm.asc(t.mpn),
      ]);

    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      final pattern = '%$term%';
      q.where(
        (t) =>
            t.name.lower().like(pattern) |
            t.mpn.lower().like(pattern) |
            t.manufacturer.lower().like(pattern) |
            t.footprint.lower().like(pattern),
      );
    }

    return q.watch().map((rows) => rows.map(_toComponent).toList());
  }

  Stream<Component?> watchComponent(String id) {
    final q = select(cachedComponents)..where((t) => t.id.equals(id));
    return q.watchSingleOrNull().map((row) => row == null ? null : _toComponent(row));
  }

  Stream<List<Component>> watchAllComponents() {
    final q = select(cachedComponents)
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.watch().map((rows) => rows.map(_toComponent).toList());
  }

  Future<Component?> componentById(String id) async {
    final row = await (select(cachedComponents)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toComponent(row);
  }

  Future<Component?> componentByMpn(String inventoryId, String mpn) async {
    final row = await (select(cachedComponents)
          ..where((t) => t.inventoryId.equals(inventoryId) & t.mpn.equals(mpn)))
        .getSingleOrNull();
    return row == null ? null : _toComponent(row);
  }

  Stream<List<Project>> watchProjects() {
    final q = select(cachedProjects)
      ..orderBy([
        (t) => OrderingTerm.asc(t.status),
        (t) => OrderingTerm.desc(t.createdAt),
      ]);
    return q.watch().map((rows) => rows.map(_toProject).toList());
  }

  Stream<Project?> watchProject(String id) {
    final q = select(cachedProjects)..where((t) => t.id.equals(id));
    return q.watchSingleOrNull().map((row) => row == null ? null : _toProject(row));
  }

  /// Project lines joined with their component and source inventory name.
  Stream<List<ProjectLine>> watchProjectLines(String projectId) {
    final q = select(cachedProjectComponents).join([
      innerJoin(
        cachedComponents,
        cachedComponents.id.equalsExp(cachedProjectComponents.componentId),
      ),
      innerJoin(
        cachedInventories,
        cachedInventories.id.equalsExp(cachedProjectComponents.inventoryId),
      ),
    ])
      ..where(cachedProjectComponents.projectId.equals(projectId))
      ..orderBy([OrderingTerm.asc(cachedComponents.name)]);

    return q.watch().map(
      (rows) => rows
          .map(
            (row) => ProjectLine(
              line: _toProjectComponent(row.readTable(cachedProjectComponents)),
              component: _toComponent(row.readTable(cachedComponents)),
              inventoryName: row.readTable(cachedInventories).name,
            ),
          )
          .toList(),
    );
  }

  Stream<List<VendorPrice>> watchVendorPrices(String componentId) {
    final q = select(cachedVendorPrices)
      ..where((t) => t.componentId.equals(componentId))
      ..orderBy([(t) => OrderingTerm.asc(t.vendor)]);
    return q.watch().map((rows) => rows.map(_toVendorPrice).toList());
  }

  Future<List<VendorPrice>> vendorPricesFor(String componentId) async {
    final rows = await (select(cachedVendorPrices)
          ..where((t) => t.componentId.equals(componentId)))
        .get();
    return rows.map(_toVendorPrice).toList();
  }

  Stream<List<StockTransaction>> watchTransactions(String componentId) {
    final q = select(cachedStockTransactions)
      ..where((t) => t.componentId.equals(componentId))
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(100);
    return q.watch().map(
      (rows) => rows
          .map(
            (r) => StockTransaction(
              id: r.id,
              componentId: r.componentId,
              projectId: r.projectId,
              userId: r.userId,
              changeQty: r.changeQty,
              reason: TransactionReason.fromWire(r.reason),
              createdAt: r.createdAt,
            ),
          )
          .toList(),
    );
  }

  /// Cart rows joined with component, inventory and the cached vendor listing so
  /// the Purchasing screen can render a link without N+1 lookups.
  Stream<List<CartReviewItem>> watchCartItems() {
    final q = select(cachedCartItems).join([
      innerJoin(
        cachedComponents,
        cachedComponents.id.equalsExp(cachedCartItems.componentId),
      ),
      innerJoin(
        cachedInventories,
        cachedInventories.id.equalsExp(cachedComponents.inventoryId),
      ),
      leftOuterJoin(
        cachedVendorPrices,
        cachedVendorPrices.componentId.equalsExp(cachedCartItems.componentId) &
            cachedVendorPrices.vendor.equalsExp(cachedCartItems.vendor),
      ),
    ])
      ..orderBy([
        OrderingTerm.asc(cachedCartItems.vendor),
        OrderingTerm.desc(cachedCartItems.createdAt),
      ]);

    return q.watch().map(
      (rows) => rows
          .map(
            (row) => CartReviewItem(
              item: _toCartItem(row.readTable(cachedCartItems)),
              component: _toComponent(row.readTable(cachedComponents)),
              inventoryName: row.readTable(cachedInventories).name,
              productUrl: row.readTableOrNull(cachedVendorPrices)?.productUrl,
            ),
          )
          .toList(),
    );
  }

  Future<List<CartItem>> pendingCartItemsFor(Vendor vendor) async {
    final rows = await (select(cachedCartItems)
          ..where((t) => t.vendor.equals(vendor.wire) & t.status.isNotValue('added_to_cart')))
        .get();
    return rows.map(_toCartItem).toList();
  }

  Future<CartItem?> cartItemById(String id) async {
    final row = await (select(cachedCartItems)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toCartItem(row);
  }

  Stream<List<CachedUser>> watchMembers() {
    final q = select(cachedUsers)
      ..orderBy([(t) => OrderingTerm.asc(t.email)]);
    return q.watch();
  }

  Stream<AppUser?> watchUser(String id) {
    final q = select(cachedUsers)..where((t) => t.id.equals(id));
    return q.watchSingleOrNull().map((row) => row == null ? null : toAppUser(row));
  }

  Future<AppUser?> user(String id) async {
    final row = await (select(cachedUsers)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : toAppUser(row);
  }

  Future<void> cacheUser(AppUser user) async {
    await into(cachedUsers).insert(
      CachedUsersCompanion.insert(
        id: user.id,
        companyId: Value(user.companyId),
        email: user.email,
        displayName: Value(user.displayName),
        role: Value(user.role.wire),
        createdAt: user.createdAt,
        updatedAt: DateTime.now().toUtc(),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<CachedCompany?> company() async =>
      (select(cachedCompanies)..limit(1)).getSingleOrNull();

  Stream<CachedCompany?> watchCompany() =>
      (select(cachedCompanies)..limit(1)).watchSingleOrNull();

  // ===========================================================================
  // Cache maintenance (called by SyncService)
  // ===========================================================================

  /// Wipes every cached row for the previous company and user. Called on sign
  /// out and when the signed-in user switches companies, so one tenant's data
  /// can never bleed into another's session.
  Future<void> clearAll() async {
    await transaction(() async {
      // Annotated as TableInfo: the bare list literal infers `Table`, which
      // `delete()` cannot accept.
      for (final TableInfo table in <TableInfo>[
        cachedCompanies,
        cachedUsers,
        cachedInventories,
        cachedComponents,
        cachedProjects,
        cachedProjectComponents,
        cachedStockTransactions,
        cachedVendorPrices,
        cachedCartItems,
        pendingOps,
      ]) {
        await delete(table).go();
      }
    });
  }

  /// Replaces the cached copy of a table with freshly pulled rows, keeping any
  /// locally-pending rows so unsynced work is not discarded by a refresh.
  ///
  /// [remoteTable] is the server-side table name (`inventories`), which is what
  /// the write queue records — it is *not* the same as the local drift name
  /// (`cached_inventories`). Getting this wrong silently discards unsynced work
  /// on every refresh.
  Future<void> replaceSynced(
    String remoteTable,
    TableInfo table,
    List<Insertable> rows,
  ) async {
    await transaction(() async {
      final pendingIds = await _pendingRowIds(remoteTable);
      final idColumn = table.$columns.firstWhere((c) => c.name == 'id');

      // `id NOT IN ()` is invalid SQL, so an empty pending set means "delete
      // everything" rather than "delete nothing".
      final deleteQuery = delete(table);
      if (pendingIds.isNotEmpty) {
        deleteQuery.where((_) => idColumn.isNotIn(pendingIds.toList()));
      }
      await deleteQuery.go();

      for (final row in rows) {
        await into(table).insert(row, mode: InsertMode.insertOrReplace);
      }
    });
  }

  Future<Set<String>> _pendingRowIds(String tableName) async {
    final rows = await (select(pendingOps)
          ..where((t) => t.target.equals(tableName) & t.rowId.isNotNull()))
        .get();
    return rows.map((r) => r.rowId!).toSet();
  }

  // ===========================================================================
  // Write queue
  // ===========================================================================

  Future<void> enqueue({
    required String kind,
    required String target,
    String? rowId,
    Map<String, Object?> payload = const {},
  }) {
    return into(pendingOps).insert(
      PendingOpsCompanion.insert(
        id: _newOpId(),
        kind: kind,
        target: target,
        rowId: Value(rowId),
        payload: jsonEncode(payload),
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<List<PendingOp>> nextOps({int limit = 50}) {
    return (select(pendingOps)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
          ..limit(limit))
        .get();
  }

  Future<void> markOpFailed(String opId, String error) async {
    await customUpdate(
      'UPDATE pending_ops SET attempts = attempts + 1, last_error = ? WHERE id = ?',
      variables: [
        Variable.withString(error),
        Variable.withString(opId),
      ],
      updates: {pendingOps},
    );
  }

  Future<void> deleteOp(String opId) async {
    await (delete(pendingOps)..where((t) => t.id.equals(opId))).go();
  }

  Stream<int> watchPendingOpCount() =>
      (selectOnly(pendingOps)..addColumns([pendingOps.id.count()]))
          .watchSingle()
          .map((row) => row.read(pendingOps.id.count()) ?? 0);

  Future<int> pendingOpCount() async {
    final row = await (selectOnly(pendingOps)..addColumns([pendingOps.id.count()]))
        .getSingle();
    return row.read(pendingOps.id.count()) ?? 0;
  }

  String _newOpId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_opCounter++}';

  static int _opCounter = 0;

  // ===========================================================================
  // Mappers
  // ===========================================================================

  static Inventory _toInventory(CachedInventory r) => Inventory(
    id: r.id,
    companyId: r.companyId,
    name: r.name,
    locationNote: r.locationNote,
    createdBy: r.createdBy,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );

  static Component _toComponent(CachedComponent r) => Component(
    id: r.id,
    inventoryId: r.inventoryId,
    mpn: r.mpn,
    name: r.name,
    manufacturer: r.manufacturer,
    footprint: r.footprint,
    dimensions: r.dimensions,
    imageUrl: r.imageUrl,
    localImagePath: r.localImagePath,
    quantity: r.quantity,
    unit: r.unit,
    lowStockThreshold: r.lowStockThreshold,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );

  static Project _toProject(CachedProject r) => Project(
    id: r.id,
    companyId: r.companyId,
    name: r.name,
    description: r.description,
    status: ProjectStatus.fromWire(r.status),
    createdBy: r.createdBy,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );

  static ProjectComponent _toProjectComponent(CachedProjectComponent r) =>
      ProjectComponent(
        id: r.id,
        projectId: r.projectId,
        componentId: r.componentId,
        inventoryId: r.inventoryId,
        quantityRequired: r.quantityRequired,
        quantityAllocated: r.quantityAllocated,
        description: r.description,
        status: ProjectComponentStatus.fromWire(r.status),
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
      );

  static VendorPrice _toVendorPrice(CachedVendorPrice r) => VendorPrice(
    id: r.id,
    componentId: r.componentId,
    vendor: Vendor.fromWire(r.vendor),
    price: r.price,
    currency: r.currency,
    inStock: r.inStock,
    productUrl: r.productUrl,
    fetchedAt: r.fetchedAt,
    updatedAt: r.updatedAt,
  );

  static CartItem _toCartItem(CachedCartItem r) => CartItem(
    id: r.id,
    userId: r.userId,
    vendor: Vendor.fromWire(r.vendor),
    componentId: r.componentId,
    quantity: r.quantity,
    status: CartItemStatus.fromWire(r.status),
    error: r.error,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );

  static AppUser toAppUser(CachedUser r) => AppUser(
    id: r.id,
    companyId: r.companyId,
    email: r.email,
    displayName: r.displayName,
    role: UserRole.fromWire(r.role),
    createdAt: r.createdAt,
  );

  static Company toCompany(CachedCompany r) => Company(
    id: r.id,
    name: r.name,
    inviteCode: r.inviteCode,
    createdAt: r.createdAt,
  );
}
