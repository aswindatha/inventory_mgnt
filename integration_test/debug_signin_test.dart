import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:inventorymgnt/app.dart';
import 'package:inventorymgnt/core/config/env.dart';
import 'package:inventorymgnt/data/local/app_database.dart';
import 'package:inventorymgnt/data/remote/backend.dart';
import 'package:inventorymgnt/providers/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Throwaway diagnostic: boots the app, signs in, and dumps what is actually on
/// screen so the real E2E finders can be written against reality.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('diagnose the post-sign-in state', (tester) async {
    await sb.Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
    final backend = Backend(sb.Supabase.instance.client);
    final db = AppDatabase.forTesting(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          backendProvider.overrideWithValue(backend),
        ],
        child: const InventoryApp(),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    void dumpTexts(String label) {
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .toList();
      debugPrint('>>> $label: $texts');
    }

    dumpTexts('BEFORE SIGN-IN');

    // Sign in.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'e2e-tester@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'E2E-Tester-Passw0rd!23',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));

    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    debugPrint('>>> session after sign-in: '
        '${sb.Supabase.instance.client.auth.currentSession != null}');
    debugPrint('>>> currentUser id: '
        '${sb.Supabase.instance.client.auth.currentUser?.id}');

    dumpTexts('AFTER SIGN-IN');

    final cachedUser = await db.user(
      sb.Supabase.instance.client.auth.currentUser?.id ?? '',
    );
    debugPrint('>>> cached user: id=${cachedUser?.id} '
        'companyId=${cachedUser?.companyId} role=${cachedUser?.role}');

    final cachedCompany = await db.company();
    debugPrint('>>> cached company: ${cachedCompany?.name}');

    await backend.signOut();
    await db.close();
  });
}
