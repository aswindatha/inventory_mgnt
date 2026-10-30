import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Web: sqlite3 compiled to WASM, with drift picking the best storage the
/// browser offers (OPFS in a shared/dedicated worker, IndexedDB as fallback).
///
/// Requires `sqlite3.wasm` and `drift_worker.dart.js` next to `index.html` —
/// the worker is compiled from `tool/drift_worker.dart`.
QueryExecutor openConnection() {
  return DatabaseConnection.delayed(
    Future(() async {
      final result = await WasmDatabase.open(
        databaseName: 'inventory_cache',
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.dart.js'),
      );
      return result.resolvedExecutor;
    }),
  );
}
