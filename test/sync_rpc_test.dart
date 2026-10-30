import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventorymgnt/core/config/env.dart';
import 'package:inventorymgnt/data/local/app_database.dart';
import 'package:inventorymgnt/data/remote/backend.dart';
import 'package:inventorymgnt/data/remote/sync_service.dart';
import 'package:inventorymgnt/data/repositories/auth_repository.dart';
import 'package:inventorymgnt/data/repositories/inventory_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Live-backend regression test for the stock-adjust sync gap seen in the
/// browser E2E: the owner's `adjust_component_quantity` op stayed queued and the
/// remote quantity never moved, so a second member pulled stale stock.
///
///   flutter test test/sync_rpc_test.dart --dart-define-from-file=dart_define.json
void main() {
  test('adjustQuantity pushes the rpc op to the server', () async {
    expect(AppConfig.isBackendConfigured, isTrue,
        reason: 'run with --dart-define-from-file=dart_define.json');

    final client = sb.SupabaseClient(
      AppConfig.supabaseUrl,
      AppConfig.supabaseAnonKey,
    );
    final backend = Backend(client);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final sync = SyncService(backend, db);
    final auth = AuthRepository(backend, db, sync);
    final repo = InventoryRepository(db, sync);

    await auth.signIn('e2e-tester@example.com', 'E2E-Tester-Passw0rd!23');
    await sync.pull();

    final inventories = await (db.select(db.cachedInventories)).get();
    // ignore: avoid_print
    print('inventories: ${inventories.map((i) => i.name)}');
    final inventory = inventories.first;

    final mpn = 'SYNC-TEST-${DateTime.now().millisecondsSinceEpoch}';
    final component = await repo.addComponent(
      inventoryId: inventory.id,
      mpn: mpn,
      name: 'Sync probe',
      quantity: 10,
    );
    // ignore: avoid_print
    print('component created: ${component.id}');

    var remote = await backend.select('components', equals: {'id': component.id});
    // ignore: avoid_print
    print('remote after addComponent: ${remote.map((r) => r['quantity'])}');

    await repo.adjustQuantity(componentId: component.id, changeQty: 2);

    remote = await backend.select('components', equals: {'id': component.id});
    // ignore: avoid_print
    print('remote after adjustQuantity: ${remote.map((r) => r['quantity'])}');

    // Retry briefly — if the row appears late, the insert request itself was
    // delayed rather than lost.
    for (var i = 0; i < 6 && remote.isEmpty; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      remote = await backend.select('components', equals: {'mpn': mpn});
      // ignore: avoid_print
      print('retry $i: ${remote.map((r) => r['quantity'])}');
    }

    final ops = await db.nextOps();
    for (final op in ops) {
      // ignore: avoid_print
      print('PENDING ${op.kind} ${op.target} attempts=${op.attempts} '
          'err=${op.lastError}');
    }
    // ignore: avoid_print
    print('pending count: ${await db.pendingOpCount()}');

    expect(remote, isNotEmpty, reason: 'component insert must have pushed');
    expect((remote.first['quantity'] as num).toDouble(), 12.0,
        reason: 'remote quantity must include the +2 adjustment');

    await auth.signOut();
    await db.close();
    client.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
