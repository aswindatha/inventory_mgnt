import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventorymgnt/app.dart';
import 'package:inventorymgnt/core/theme.dart';
import 'package:inventorymgnt/data/local/app_database.dart';
import 'package:inventorymgnt/data/models/company.dart';
import 'package:inventorymgnt/data/models/enums.dart';
import 'package:inventorymgnt/data/remote/backend.dart';
import 'package:inventorymgnt/features/components/add_component_screen.dart';
import 'package:inventorymgnt/providers/providers.dart';

/// End-to-end journeys through the real widget tree: the actual router,
/// repositories and drift cache (in-memory), with the backend unconfigured so
/// every write is local-first and the sync push is a safe no-op.
///
/// This is the level that proves the UX wiring — navigation stack, sheets,
/// list updates — rather than individual widgets.
void main() {
  late AppDatabase db;

  final user = AppUser(
    id: 'u1',
    email: 'owner@example.com',
    displayName: 'Owner',
    companyId: 'c1',
    role: UserRole.owner,
    createdAt: DateTime(2024),
  );

  final company = Company(
    id: 'c1',
    name: 'Test Co',
    inviteCode: 'ABCD1234',
    createdAt: DateTime(2024),
  );

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Widget harness() => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      // No Supabase.initialize() — the sync push is a guarded no-op and all
      // reads/writes stay inside the in-memory drift cache.
      backendProvider.overrideWithValue(Backend()),
      currentUserProvider.overrideWith((ref) => Stream.value(user)),
      companyProvider.overrideWith((ref) => Stream.value(company)),
      membersProvider.overrideWith((ref) => Stream.value([user])),
      // No scrapers in tests: the price card renders its empty state and no
      // network call is attempted.
      supportedVendorsProvider.overrideWithValue(const <Vendor>[]),
      // A nonzero pending-op count mounts an indeterminate progress spinner in
      // the app bar, which keeps scheduling frames and would hang every
      // pumpAndSettle. The badge itself is not under test here.
      pendingOpCountProvider.overrideWith((ref) => Stream.value(0)),
    ],
    child: const InventoryApp(),
  );

  /// Unmounts inside the test so the ProviderScope tears down while fake_async
  /// can still flush drift's deferred stream-close timers.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  /// pumpAndSettle with a tight timeout — a stuck animation fails fast and the
  /// stack points at the guilty line instead of burning the 10-minute default.
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 30),
  );

  /// Phone-sized viewport: bottom NavigationBar. The default test surface is
  /// 800px wide, which triggers the desktop NavigationRail instead.
  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('inventory journey: create, navigate, add component, back',
      (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // Signed-in shell: company in the app bar, bottom nav, and no back
    // affordance on the root tab.
    expect(find.text('Test Co'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    expect(find.text('No inventories yet'), findsOneWidget);

    // Create an inventory through the real bottom sheet.
    await tester.tap(find.text('Add inventory').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Workshop',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Workshop'), findsOneWidget);
    expect(find.text('Inventory created.'), findsOneWidget);

    // Drill in — the pushed detail route must expose a back button.
    await tester.tap(find.text('Workshop'));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('No components yet'), findsOneWidget);

    // Add a component through the real form.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Manufacturer part number'),
      'LM358',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Dual op amp',
    );
    final addButton = find.widgetWithText(FilledButton, 'Add component');
    // Dismiss the lingering 'Inventory created.' snackbar — it overlays the
    // bottom edge where the submit button sits — and center the button in the
    // viewport rather than leaving it at the bottom edge.
    ScaffoldMessenger.of(
      tester.element(find.byType(AddComponentScreen)),
    ).hideCurrentSnackBar();
    await Scrollable.ensureVisible(
      tester.element(addButton),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    // Lands on the component detail (the add form was replaced, not stacked).
    expect(find.text('Dual op amp'), findsWidgets);
    expect(find.text('Added LM358.'), findsOneWidget);
    expect(find.text('Vendor pricing'), findsOneWidget);

    // Back once -> the inventory we came from; back again -> the home tab.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Workshop'), findsWidgets);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('project journey: tab switch, create, drill in', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();
    expect(find.text('No projects yet'), findsOneWidget);

    await tester.tap(find.text('Add project').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Line follower',
    );
    await tester.tap(find.text('Create project'));
    await tester.pumpAndSettle();
    expect(find.text('Line follower'), findsOneWidget);

    await tester.tap(find.text('Line follower'));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    // Empty projects collapse to an EmptyState with an add-cta — the
    // header/readiness summary only renders once lines exist.
    expect(find.text('No components yet'), findsOneWidget);
    expect(find.text('Add component'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('wide layout uses a rail; team and purchasing render',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(harness());
    await settle(tester);

    // >= 720px: rail, not the bottom bar.
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(find.text('Team'));
    await settle(tester);
    expect(find.text('ABCD1234'), findsOneWidget);
    expect(find.text('Members (1)'), findsOneWidget);
    // The email legitimately shows twice: the member row and the Account card.
    expect(find.text('owner@example.com'), findsNWidgets(2));
    expect(find.text('(you)'), findsOneWidget);

    await tester.tap(find.text('Purchasing'));
    await settle(tester);
    expect(find.text('Nothing queued'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('modal sheets respect the desktop width cap', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add inventory').first);
    await tester.pumpAndSettle();

    // The default surface is 800 wide — the sheet surface must cap at 560.
    // (The BottomSheet widget itself stays full width; its constraints wrap
    // the Material inside, so measure the sheet's Material.)
    final size = tester.getSize(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(size.width, lessThanOrEqualTo(560));

    await unmount(tester);
  });

  testWidgets('status colors resolve per brightness', (tester) async {
    late AppColors light;
    late AppColors dark;

    Widget probe(ThemeMode mode, void Function(AppColors) capture) {
      return MaterialApp(
        themeMode: mode,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: Builder(
          builder: (context) {
            capture(context.appColors);
            return const SizedBox();
          },
        ),
      );
    }

    // AnimatedTheme lerps theme extensions over ~200ms — the first frame
    // still reports the previous palette, so settle past the transition.
    await tester.pumpWidget(probe(ThemeMode.light, (c) => light = c));
    await tester.pumpAndSettle();
    await tester.pumpWidget(probe(ThemeMode.dark, (c) => dark = c));
    await tester.pumpAndSettle();

    expect(light.warning, AppTheme.warning);
    expect(light.success, AppTheme.success);
    expect(dark.warning, isNot(light.warning));
    // Dark variants must stay legible on dark surfaces: higher luminance.
    expect(
      dark.warning.computeLuminance(),
      greaterThan(light.warning.computeLuminance()),
    );
    expect(
      dark.success.computeLuminance(),
      greaterThan(light.success.computeLuminance()),
    );
    expect(
      dark.danger.computeLuminance(),
      greaterThan(light.danger.computeLuminance()),
    );
  });
}
