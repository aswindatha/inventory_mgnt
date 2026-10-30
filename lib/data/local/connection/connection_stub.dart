import 'package:drift/drift.dart';

/// Fallback for platforms that are neither native (`dart:io`) nor web. Drift
/// cannot open a database here — this branch is only reachable on platforms the
/// app does not ship to.
QueryExecutor openConnection() {
  throw UnsupportedError('No drift database backend for this platform.');
}
