import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventorymgnt/data/local/app_database.dart';
import 'package:inventorymgnt/data/models/enums.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> insertInventory(String id, String name) async {
    await db.into(db.cachedInventories).insert(
      CachedInventoriesCompanion.insert(
        id: id,
        companyId: 'company-1',
        name: name,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> insertComponent({
    required String id,
    required String inventoryId,
    required String mpn,
    required String name,
    required num quantity,
    num lowStockThreshold = 5,
  }) async {
    await db.into(db.cachedComponents).insert(
      CachedComponentsCompanion.insert(
        id: id,
        inventoryId: inventoryId,
        mpn: mpn,
        name: name,
        quantity: Value(quantity.toDouble()),
        lowStockThreshold: Value(lowStockThreshold.toDouble()),
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  group('inventory summaries', () {
    test('rolls up component count, units and low-stock count', () async {
      await insertInventory('inv-1', 'Office');
      await insertComponent(
        id: 'c-1',
        inventoryId: 'inv-1',
        mpn: 'LM358DR',
        name: 'Op-Amp',
        quantity: 100,
      );
      // Below threshold.
      await insertComponent(
        id: 'c-2',
        inventoryId: 'inv-1',
        mpn: 'NE555',
        name: 'Timer',
        quantity: 2,
        lowStockThreshold: 5,
      );
      // Exactly at threshold counts as low.
      await insertComponent(
        id: 'c-3',
        inventoryId: 'inv-1',
        mpn: 'ATMEGA328P',
        name: 'MCU',
        quantity: 5,
        lowStockThreshold: 5,
      );

      final summaries = await db.watchInventorySummaries().first;

      expect(summaries, hasLength(1));
      final summary = summaries.single;
      expect(summary.componentCount, 3);
      expect(summary.totalUnits, 107);
      expect(summary.lowStockCount, 2);
      expect(summary.hasLowStock, isTrue);
    });

    test('reports zeroes for an inventory with no components', () async {
      await insertInventory('inv-empty', 'Home Lab');

      final summaries = await db.watchInventorySummaries().first;

      expect(summaries.single.componentCount, 0);
      expect(summaries.single.totalUnits, 0);
      expect(summaries.single.hasLowStock, isFalse);
    });

    test('keeps inventories separate', () async {
      await insertInventory('inv-1', 'Office');
      await insertInventory('inv-2', 'Home Lab');
      await insertComponent(
        id: 'c-1',
        inventoryId: 'inv-1',
        mpn: 'LM358DR',
        name: 'Op-Amp',
        quantity: 10,
      );
      await insertComponent(
        id: 'c-2',
        inventoryId: 'inv-2',
        mpn: 'LM358DR',
        name: 'Op-Amp',
        quantity: 3,
      );

      final summaries = await db.watchInventorySummaries().first;
      final byName = {for (final s in summaries) s.inventory.name: s};

      // The same MPN living in two inventories must not be merged.
      expect(byName['Office']!.totalUnits, 10);
      expect(byName['Home Lab']!.totalUnits, 3);
    });
  });

  group('component search', () {
    setUp(() async {
      await insertInventory('inv-1', 'Office');
      await insertComponent(
        id: 'c-1',
        inventoryId: 'inv-1',
        mpn: 'LM358DR',
        name: 'Dual Op-Amp',
        quantity: 10,
      );
      await insertComponent(
        id: 'c-2',
        inventoryId: 'inv-1',
        mpn: 'NE555P',
        name: 'Timer IC',
        quantity: 10,
      );
    });

    test('matches on part number case-insensitively', () async {
      final results = await db.watchComponents('inv-1', search: 'lm358').first;
      expect(results, hasLength(1));
      expect(results.single.mpn, 'LM358DR');
    });

    test('matches on name', () async {
      final results = await db.watchComponents('inv-1', search: 'timer').first;
      expect(results, hasLength(1));
      expect(results.single.mpn, 'NE555P');
    });

    test('returns everything for an empty search', () async {
      final results = await db.watchComponents('inv-1').first;
      expect(results, hasLength(2));
    });

    test('returns nothing for a miss', () async {
      final results = await db.watchComponents('inv-1', search: 'zzz').first;
      expect(results, isEmpty);
    });
  });

  group('pending operation queue', () {
    test('enqueues and drains in insertion order', () async {
      await db.enqueue(kind: 'insert', target: 'components', rowId: 'a');
      await db.enqueue(kind: 'update', target: 'components', rowId: 'b');

      expect(await db.pendingOpCount(), 2);

      final ops = await db.nextOps();
      expect(ops.map((o) => o.rowId), ['a', 'b']);
    });

    test('records a failure and increments attempts', () async {
      await db.enqueue(kind: 'insert', target: 'components', rowId: 'a');
      final op = (await db.nextOps()).single;

      await db.markOpFailed(op.id, 'insufficient stock');

      final updated = (await db.nextOps()).single;
      expect(updated.attempts, 1);
      expect(updated.lastError, 'insufficient stock');
    });

    test('deleting an op clears it from the queue', () async {
      await db.enqueue(kind: 'delete', target: 'components', rowId: 'a');
      final op = (await db.nextOps()).single;

      await db.deleteOp(op.id);

      expect(await db.pendingOpCount(), 0);
    });
  });

  group('refresh reconciliation', () {
    test('replaceSynced keeps rows that still have a queued operation', () async {
      await insertInventory('inv-local', 'Local only');
      await insertInventory('inv-synced', 'From server');
      await db.enqueue(
        kind: 'insert',
        target: 'inventories',
        rowId: 'inv-local',
      );

      // A refresh that does not include the locally-created inventory.
      await db.replaceSynced('inventories', db.cachedInventories, [
        CachedInventoriesCompanion.insert(
          id: 'inv-synced',
          companyId: 'company-1',
          name: 'From server',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      ]);

      final remaining = await db.watchInventories().first;
      final ids = remaining.map((i) => i.id).toSet();

      // The unsynced local row survives; the stale server row is replaced.
      expect(ids, contains('inv-local'));
      expect(ids, contains('inv-synced'));
      expect(remaining, hasLength(2));
    });

    test('replaceSynced drops rows the server no longer has', () async {
      await insertInventory('inv-deleted', 'Deleted elsewhere');

      await db.replaceSynced('inventories', db.cachedInventories, const []);

      expect(await db.watchInventories().first, isEmpty);
    });
  });

  group('clearAll', () {
    test('wipes every cached row including the queue', () async {
      await insertInventory('inv-1', 'Office');
      await insertComponent(
        id: 'c-1',
        inventoryId: 'inv-1',
        mpn: 'LM358DR',
        name: 'Op-Amp',
        quantity: 1,
      );
      await db.enqueue(kind: 'insert', target: 'components', rowId: 'c-1');

      await db.clearAll();

      expect(await db.watchInventories().first, isEmpty);
      expect(await db.watchAllComponents().first, isEmpty);
      expect(await db.pendingOpCount(), 0);
    });
  });

  group('vendor price cache', () {
    test('a stale row is reported as stale', () async {
      final old = DateTime.now().toUtc().subtract(const Duration(hours: 12));
      await db.into(db.cachedVendorPrices).insert(
        CachedVendorPricesCompanion.insert(
          id: 'p-1',
          componentId: 'c-1',
          vendor: Vendor.robu.wire,
          price: const Value(24.5),
          inStock: const Value(true),
          fetchedAt: old,
          updatedAt: old,
        ),
      );

      final price = (await db.vendorPricesFor('c-1')).single;

      expect(price.isStale(), isTrue);
      expect(price.price, 24.5);
      expect(price.inStock, isTrue);
    });

    test('a blocked scrape is stored with nulls and stays distinguishable',
        () async {
      final now = DateTime.now().toUtc();
      await db.into(db.cachedVendorPrices).insert(
        CachedVendorPricesCompanion.insert(
          id: 'p-2',
          componentId: 'c-1',
          vendor: Vendor.robu.wire,
          fetchedAt: now,
          updatedAt: now,
        ),
      );

      final price = (await db.vendorPricesFor('c-1')).single;

      expect(price.isUnavailable, isTrue);
      expect(price.isStale(), isFalse, reason: 'we did just try');
      // The key distinction: unknown is not the same as out of stock.
      expect(price.inStock, isNull);
      expect(price.inStock, isNot(false));
    });
  });
}
