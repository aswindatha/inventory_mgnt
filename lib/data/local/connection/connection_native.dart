import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Android / iOS / desktop: the cache is a real SQLite file in the app's
/// documents directory, opened on a background isolate so first access does
/// not jank the UI.
QueryExecutor openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'inventory_cache.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
