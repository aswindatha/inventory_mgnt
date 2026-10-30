// Web worker hosting the drift WASM database.
//
// Compiled to `web/drift_worker.dart.js` — `WasmDatabase.open` in
// `lib/data/local/connection/connection_web.dart` spawns it when the browser
// supports running the database off the main thread (OPFS or shared IndexedDB).
// Rebuild after upgrading drift:
//
//   dart compile js -O2 -o web/drift_worker.dart.js tool/drift_worker.dart
import 'package:drift/wasm.dart';

void main() => WasmDatabase.workerMainForOpen();
