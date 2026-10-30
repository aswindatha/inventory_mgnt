import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inventorymgnt/app.dart';
import 'package:inventorymgnt/core/config/env.dart';
import 'package:inventorymgnt/data/local/app_database.dart';
import 'package:inventorymgnt/data/remote/backend.dart';
import 'package:inventorymgnt/providers/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// On-device end-to-end run against the real Supabase project.
///
/// Setup:
///   psql "$SUPABASE_DB_URL" -f supabase/tests/create_e2e_user.sql
///   psql "$SUPABASE_DB_URL" -f supabase/tests/reset_e2e_user.sql
///
/// Run:
///   flutter test integration_test/full_journey_test.dart \
///     -d `DEVICE_ID` --dart-define-from-file=dart_define.json
///
/// Deliberately ONE test walking the whole journey. Splitting it into separate
/// tests meant signing out and back in between each one, which left the shared
/// Supabase singleton in a state where the next sign-in did not propagate — a
/// test-harness artefact, not an app bug, but it made real failures impossible
/// to read.
///
/// The local cache is in-memory, so every read has to come from the server —
/// which is the integration under test. Writes are local-first, so assertions
/// check both the UI and what actually reached Postgres.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const e2eEmail = 'e2e-tester@example.com';
  const e2ePassword = 'E2E-Tester-Passw0rd!23';

  late AppDatabase db;
  late Backend backend;

  setUpAll(() async {
    expect(
      AppConfig.isBackendConfigured,
      isTrue,
      reason: 'Run with --dart-define-from-file=dart_define.json',
    );
    await sb.Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
    backend = Backend(sb.Supabase.instance.client);
  });

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async {
    await backend.signOut();
    await db.close();
  });

  /// Advances time without requiring the tree to become quiescent.
  ///
  /// `pumpAndSettle` cannot be used on screens showing `ShimmerBox`, which
  /// animates forever by design.
  Future<void> settle(
    WidgetTester tester, {
    int frames = 12,
    Duration step = const Duration(milliseconds: 250),
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  /// Everything currently rendered, so a failed finder says what *was* there.
  List<String> visibleText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .toList();

  void expectVisible(WidgetTester tester, String text) {
    final finder = find.text(text);
    if (finder.evaluate().isEmpty) {
      fail('Expected to see "$text" but the screen shows: '
          '${visibleText(tester)}\n'
          'Current route: ${_currentRoute(tester)}');
    }
  }

  Future<void> enterField(WidgetTester tester, String label, String value) async {
    final finder = find.widgetWithText(TextFormField, label);
    if (finder.evaluate().isEmpty) {
      fail('No "$label" field on screen. Visible: ${visibleText(tester)}');
    }
    await tester.enterText(finder.first, value);
    await tester.pump();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    if (finder.evaluate().isEmpty) {
      fail('Nothing to tap labelled "$text". Visible: ${visibleText(tester)}');
    }
    await tester.tap(finder.first);
    await settle(tester);
  }

  testWidgets('full journey against the live backend', (tester) async {
    // ---------------------------------------------------------------- boot ---
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          backendProvider.overrideWithValue(backend),
        ],
        child: const InventoryApp(),
      ),
    );
    await settle(tester);

    // Configured backend: the credential form is shown, and the
    // "Backend not configured" banner must NOT be.
    expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
    expect(find.text('Backend not configured'), findsNothing);

    // ------------------------------------------------------------- sign in ---
    await enterField(tester, 'Email', e2eEmail);
    await enterField(tester, 'Password', e2ePassword);
    await tapText(tester, 'Sign in');
    await settle(tester, frames: 30, step: const Duration(milliseconds: 500));

    debugPrint('>>> after sign-in: ${visibleText(tester)}');
    expectVisible(tester, 'Set up your workspace');

    // ------------------------------------------------------ create company ---
    final stamp = DateTime.now().millisecondsSinceEpoch % 1000000;
    final companyName = 'E2E Co $stamp';

    await enterField(tester, 'Company name', companyName);
    await tapText(tester, 'Create company');
    await settle(tester, frames: 30, step: const Duration(milliseconds: 500));

    debugPrint('>>> after create company: ${visibleText(tester)}');
    expectVisible(tester, 'Main Inventory');
    expect(find.byType(NavigationBar), findsOneWidget);

    // It really landed in Postgres, not just the cache.
    final companies = await backend.select('companies');
    expect(companies, hasLength(1), reason: 'one company for the e2e user');
    expect(companies.single['name'], companyName);

    // ------------------------------------------------------ add component ---
    await tapText(tester, 'Main Inventory');
    await settle(tester);
    expectVisible(tester, 'No components yet');

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Component'));
    await settle(tester);
    expectVisible(tester, 'Add component');

    final mpn = 'E2E-LM358-$stamp';
    await enterField(tester, 'Manufacturer part number', mpn);

    // The MPN lookup must not crash; the offline catalogue always answers.
    await tapText(tester, 'Look up specifications');
    await settle(tester, frames: 12, step: const Duration(milliseconds: 400));

    await enterField(tester, 'Name', 'E2E Test Op-Amp');
    await enterField(tester, 'Opening quantity', '40');

    await tapText(tester, 'Add component');
    await settle(tester, frames: 30, step: const Duration(milliseconds: 500));

    debugPrint('>>> after add component: ${visibleText(tester)}');
    expectVisible(tester, 'E2E Test Op-Amp');
    expectVisible(tester, '40 pcs');

    final components = await backend.select('components', equals: {'mpn': mpn});
    expect(components, hasLength(1));
    expect(components.single['quantity'], 40);

    // ---------------------------------------------------- adjust the stock ---
    // Exercises adjust_component_quantity end to end — the routine that was
    // completely broken until the app.internal flag fix.
    await tapText(tester, '1');
    await settle(tester, frames: 16, step: const Duration(milliseconds: 400));

    final afterAdjust = await backend.select('components', equals: {'mpn': mpn});
    expect(
      afterAdjust.single['quantity'],
      41,
      reason: 'adjust_component_quantity must move stock and stay audited',
    );

    // ---------------------------------------------------- create a project ---
    await tester.pageBack();
    await settle(tester);
    await tester.pageBack();
    await settle(tester);

    await tapText(tester, 'Projects');
    await settle(tester, frames: 16, step: const Duration(milliseconds: 400));
    expectVisible(tester, 'No projects yet');

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Project'));
    await settle(tester);
    final projectName = 'E2E Project $stamp';
    await enterField(tester, 'Name', projectName);
    await tapText(tester, 'Create project');
    await settle(tester, frames: 24, step: const Duration(milliseconds: 500));

    final projects = await backend.select('projects');
    expect(projects, hasLength(1));
    expect(projects.single['name'], projectName);

    // ------------------------------------------- add component to project ---
    await tapText(tester, 'Add component');
    await settle(tester, frames: 16, step: const Duration(milliseconds: 400));
    expectVisible(tester, 'Search across every inventory');

    await tapText(tester, 'E2E Test Op-Amp');
    await settle(tester);
    await enterField(tester, 'Quantity required', '10');
    await tapText(tester, 'Add to project');
    await settle(tester, frames: 24, step: const Duration(milliseconds: 500));

    final projectComponents = await backend.select('project_components');
    expect(projectComponents, hasLength(1));
    expect(projectComponents.single['quantity_required'], 10);

    // ------------------------------------------------ proceed with project ---
    await tapText(tester, 'Proceed with project');
    await settle(tester, frames: 30, step: const Duration(milliseconds: 500));

    // 41 on hand minus 10 required.
    final afterProceed = await backend.select('components', equals: {'mpn': mpn});
    expect(
      afterProceed.single['quantity'],
      31,
      reason: 'proceed_with_project must deduct stock',
    );

    final transactions = await backend.select(
      'stock_transactions',
      equals: {'component_id': afterProceed.single['id']},
    );
    expect(
      transactions.map((t) => t['reason']),
      contains('project_deduction'),
      reason: 'the deduction must be audited',
    );

    debugPrint('>>> journey complete');
  });
}

String _currentRoute(WidgetTester tester) {
  try {
    final router = tester.widget<Router<Object?>>(find.byType(Router<Object?>));
    final delegate = router.routerDelegate;
    if (delegate is GoRouterDelegate) {
      return '${delegate.currentConfiguration.uri}';
    }
    return '(unknown)';
  } catch (_) {
    return '(unknown)';
  }
}
