import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventorymgnt/core/config/env.dart';
import 'package:inventorymgnt/data/local/app_database.dart';
import 'package:inventorymgnt/data/remote/backend.dart';
import 'package:inventorymgnt/data/remote/sync_service.dart';
import 'package:inventorymgnt/data/repositories/auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Live-backend regression test for the identity leak seen in the browser E2E:
/// sign in as A -> sign out -> sign in as B left the provider emitting A's
/// profile, so the onboarding banner showed the previous user.
///
/// Needs the real project:
///   flutter test test/auth_switch_test.dart --dart-define-from-file=dart_define.json
///
/// Requires e2e-tester + e2e-member to exist (supabase/tests/create_e2e_*.sql).
void main() {
  test('sign-out -> sign-in as another user emits the new user', () async {
    expect(AppConfig.isBackendConfigured, isTrue,
        reason: 'run with --dart-define-from-file=dart_define.json');

    final client = sb.SupabaseClient(
      AppConfig.supabaseUrl,
      AppConfig.supabaseAnonKey,
    );
    final backend = Backend(client);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = AuthRepository(backend, db, SyncService(backend, db));

    final emitted = <String?>[];
    final sub = repo.watchCurrentUser().listen((u) {
      emitted.add(u?.label ?? '<null>');
      // ignore: avoid_print
      print('EMIT ${u?.id} ${u?.email} "${u?.displayName}"');
    });

    await repo.signIn('e2e-tester@example.com', 'E2E-Tester-Passw0rd!23');
    await Future<void>.delayed(const Duration(seconds: 2));
    // ignore: avoid_print
    print('after owner sign-in: $emitted');

    await repo.signOut();
    await Future<void>.delayed(const Duration(seconds: 2));
    // ignore: avoid_print
    print('after owner sign-out: $emitted');

    await repo.signIn('e2e.member.tester@gmail.com', 'E2E-Member-Passw0rd!45');
    await Future<void>.delayed(const Duration(seconds: 2));
    // ignore: avoid_print
    print('after member sign-in: $emitted');

    expect(emitted.last, 'E2E Member',
        reason: 'the provider must emit the member identity, not the previous '
            "account's");

    await sub.cancel();
    await db.close();
    client.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
