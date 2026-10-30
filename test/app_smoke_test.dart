import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventorymgnt/app.dart';
import 'package:inventorymgnt/data/local/app_database.dart';
import 'package:inventorymgnt/data/remote/backend.dart';
import 'package:inventorymgnt/providers/providers.dart';

/// Boots the real widget tree with an unconfigured backend.
///
/// This is the cheapest meaningful smoke test: it exercises `main()`'s provider
/// wiring, the router's redirect, and the first screen a credential-less launch
/// lands on. Anything that throws during the first frame shows up here rather
/// than on a device.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Widget harness() => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      // No Supabase.initialize() call, so this is the credential-less path.
      backendProvider.overrideWithValue(Backend()),
    ],
    child: const InventoryApp(),
  );

  /// Unmounts the tree inside the test so the ProviderScope tears down while
  /// fake_async can still flush timers. Without this, drift's deferred
  /// stream-close schedules a Timer during the framework's own unmount and the
  /// test fails on "Timer is still pending".
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('launches to the auth funnel, not the home shell', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('Electronics Inventory'), findsWidgets);
    // The router must not let an unauthenticated session reach the tabs.
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Inventories'), findsNothing);

    await unmount(tester);
  });

  testWidgets('explains how to configure the backend', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('Backend not configured'), findsOneWidget);
    expect(find.textContaining('0001_schema.sql'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('does not render the credential form when unconfigured',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // Showing a form that cannot possibly work would be worse than hiding it.
    expect(find.widgetWithText(TextFormField, 'Email'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Password'), findsNothing);

    await unmount(tester);
  });
}
