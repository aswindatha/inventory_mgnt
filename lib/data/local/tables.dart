/// Local mirror of the remote schema.
///
/// Every table carries `sync_status` (see `SyncStatus` in
/// `lib/data/models/enums.dart`) and `updated_at`, per spec §1. `sync_status`
/// is local-only — the server is the source of truth and has no meaningful
/// notion of a "pending" row.
///
/// Timestamps use drift's default `dateTime()` mapping (Unix seconds). All
/// writes normalise to UTC first, so the stored instant is unambiguous.
library;

import 'package:drift/drift.dart';

class CachedCompanies extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get inviteCode => text().named('invite_code')();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  IntColumn get syncStatus => integer().named('sync_status').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class CachedUsers extends Table {
  TextColumn get id => text()();
  TextColumn get companyId => text().named('company_id').nullable()();
  TextColumn get email => text()();
  TextColumn get displayName => text().named('display_name').nullable()();
  TextColumn get role => text().withDefault(const Constant('member'))();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  IntColumn get syncStatus => integer().named('sync_status').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class CachedInventories extends Table {
  TextColumn get id => text()();
  TextColumn get companyId => text().named('company_id')();
  TextColumn get name => text()();
  TextColumn get locationNote => text().named('location_note').nullable()();
  TextColumn get createdBy => text().named('created_by').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  IntColumn get syncStatus => integer().named('sync_status').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class CachedComponents extends Table {
  TextColumn get id => text()();
  TextColumn get inventoryId => text().named('inventory_id')();
  TextColumn get mpn => text()();
  TextColumn get name => text()();
  TextColumn get manufacturer => text().nullable()();
  TextColumn get footprint => text().nullable()();
  TextColumn get dimensions => text().nullable()();
  TextColumn get imageUrl => text().named('image_url').nullable()();

  /// Per-device on-disk cache. Never pushed to the server.
  TextColumn get localImagePath => text().named('local_image_path').nullable()();

  RealColumn get quantity => real().withDefault(const Constant(0))();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  RealColumn get lowStockThreshold =>
      real().named('low_stock_threshold').withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  IntColumn get syncStatus => integer().named('sync_status').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class CachedProjects extends Table {
  TextColumn get id => text()();
  TextColumn get companyId => text().named('company_id')();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('planning'))();
  TextColumn get createdBy => text().named('created_by').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  IntColumn get syncStatus => integer().named('sync_status').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class CachedProjectComponents extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().named('project_id')();
  TextColumn get componentId => text().named('component_id')();
  TextColumn get inventoryId => text().named('inventory_id')();
  RealColumn get quantityRequired =>
      real().named('quantity_required').withDefault(const Constant(0))();
  RealColumn get quantityAllocated =>
      real().named('quantity_allocated').withDefault(const Constant(0))();
  TextColumn get description => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('planned'))();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  IntColumn get syncStatus => integer().named('sync_status').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class CachedStockTransactions extends Table {
  TextColumn get id => text()();
  TextColumn get componentId => text().named('component_id')();
  TextColumn get projectId => text().named('project_id').nullable()();
  TextColumn get userId => text().named('user_id').nullable()();
  RealColumn get changeQty => real().named('change_qty')();
  TextColumn get reason => text()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();

  @override
  Set<Column> get primaryKey => {id};
}

class CachedVendorPrices extends Table {
  TextColumn get id => text()();
  TextColumn get componentId => text().named('component_id')();
  TextColumn get vendor => text()();
  RealColumn get price => real().nullable()();
  TextColumn get currency => text().withDefault(const Constant('INR'))();
  BoolColumn get inStock => boolean().named('in_stock').nullable()();
  TextColumn get productUrl => text().named('product_url').nullable()();
  DateTimeColumn get fetchedAt => dateTime().named('fetched_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  IntColumn get syncStatus => integer().named('sync_status').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class CachedCartItems extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().named('user_id')();
  TextColumn get vendor => text()();
  TextColumn get componentId => text().named('component_id')();
  RealColumn get quantity => real().withDefault(const Constant(1))();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get error => text().nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();
  IntColumn get syncStatus => integer().named('sync_status').withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// The write queue.
///
/// Row-level `sync_status` says *what* is dirty; this table says *how* to make
/// it clean. Operations that are not plain row writes — stock adjustments and
/// `proceed_with_project`, which are RPC calls — can only be expressed here.
class PendingOps extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();          // insert | update | delete | rpc
  TextColumn get target => text()();        // table name, or rpc function name
  TextColumn get rowId => text().named('row_id').nullable()();
  TextColumn get payload => text()();       // JSON
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().named('last_error').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();

  @override
  Set<Column> get primaryKey => {id};
}
