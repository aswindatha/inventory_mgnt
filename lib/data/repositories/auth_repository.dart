import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../core/failures.dart';
import '../local/app_database.dart';
import '../models/company.dart';
import '../models/enums.dart';
import '../remote/backend.dart';
import '../remote/sync_service.dart';

/// Authentication and the company lifecycle: sign up, sign in, then either
/// create a company (becoming owner) or join one by invite code.
class AuthRepository {
  AuthRepository(this._backend, this._db, this._sync);

  final Backend _backend;
  final AppDatabase _db;
  final SyncService _sync;

  String? get userId => _backend.currentUserId;

  /// Emits the signed-in user, reacting to auth events.
  ///
  /// This must be driven by [Backend.authStateChanges] rather than a one-shot
  /// read of the current session. At first build there is no session, so a
  /// one-shot read pins the stream to `null` forever and a user who just signed
  /// in stays stuck on the sign-in screen — the router never sees a user appear.
  ///
  /// A provisional profile is emitted the moment a session exists, so the router
  /// can leave the auth funnel before the first pull lands; the cached row (which
  /// carries `company_id`) then takes over and routes to onboarding or home.
  Stream<AppUser?> watchCurrentUser() {
    // Without credentials there is no auth stream at all — `authStateChanges`
    // never emits, so dependents would sit in AsyncLoading forever and the
    // router would never reach the sign-in screen. Resolve to signed-out.
    if (!_backend.isConfigured) return Stream<AppUser?>.value(null);

    // asyncExpand cannot be used here: it concatenates inner streams, and the
    // drift watch below never ends — every later auth event (sign-out, a
    // different user signing in) would queue behind the first user's watch
    // forever. This manual switch cancels the previous user watch on every
    // auth change so only the current session's identity is emitted.
    late StreamController<AppUser?> controller;
    StreamSubscription<sb.User?>? authSub;
    StreamSubscription<AppUser?>? userSub;

    controller = StreamController<AppUser?>(
      onListen: () {
        authSub = _backend.authStateChanges
            .map((state) => state.session?.user)
            .distinct((a, b) => a?.id == b?.id)
            .listen((authUser) {
              unawaited(userSub?.cancel());
              userSub = null;
              if (authUser == null) {
                controller.add(null);
                return;
              }
              userSub = _db.watchUser(authUser.id).listen((cached) {
                final session = _backend.raw.auth.currentSession;
                // Validate against the live session, not the event that opened
                // this watch. Cancelling the old subscription is async, so a
                // queued emission can land after the session has already moved
                // — after sign-out the cache is empty (emit signed-out), and
                // after an account switch a stale watch must be dropped or the
                // previous user's profile leaks onto the new session.
                if (session == null) {
                  controller.add(null);
                } else if (session.user.id == authUser.id) {
                  controller.add(cached ?? _provisionalUser(authUser));
                }
              });
            });
      },
      onCancel: () async {
        await userSub?.cancel();
        await authSub?.cancel();
      },
    );
    return controller.stream;
  }

  static AppUser _provisionalUser(sb.User authUser) => AppUser(
    id: authUser.id,
    email: authUser.email ?? '',
    displayName: authUser.userMetadata?['display_name'] as String?,
    createdAt: DateTime.now().toUtc(),
  );

  Future<AppUser?> currentUser() async {
    final id = _backend.currentUserId;
    if (id == null) return null;
    return _db.user(id);
  }

  Stream<Company?> watchCompany() =>
      _db.watchCompany().map((row) => row == null ? null : AppDatabase.toCompany(row));

  Stream<List<AppUser>> watchMembers() =>
      _db.watchMembers().map((rows) => rows.map(AppDatabase.toAppUser).toList());

  // ===========================================================================
  // Session
  // ===========================================================================

  Future<void> signIn(String email, String password) async {
    _requireConfigured();
    await _backend.signInWithPassword(email, password);
    await _afterSignIn();
  }

  /// Returns false when Supabase requires email confirmation before the account
  /// becomes usable — the caller should tell the user to check their inbox.
  Future<bool> signUp(String email, String password, {String? displayName}) async {
    _requireConfigured();
    final user = await _backend.signUpWithPassword(
      email,
      password,
      displayName: displayName,
    );
    if (user == null) {
      throw const AuthFailure('Sign up failed: no user returned.');
    }

    // With "Confirm email" enabled Supabase returns a user but no session.
    final hasSession = _backend.raw.auth.currentSession != null;
    if (hasSession) {
      await _afterSignIn();
    }
    return hasSession;
  }

  Future<void> signOut() async {
    await _backend.signOut();
    // Cached rows belong to the previous tenant; drop them so the next sign-in
    // cannot read another company's data.
    await _db.clearAll();
  }

  Future<void> sendPasswordReset(String email) async {
    _requireConfigured();
    await _backend.sendPasswordReset(email);
  }

  /// Seeds the local cache after a successful sign-in.
  Future<void> _afterSignIn() async {
    final id = _backend.currentUserId;
    if (id == null) return;

    // Mirror the auth identity immediately so the router has something to route
    // on before the first pull completes.
    final existing = await _db.user(id);
    if (existing == null) {
      final authUser = _backend.raw.auth.currentUser;
      if (authUser != null) {
        await _db.cacheUser(
          AppUser(
            id: authUser.id,
            email: authUser.email ?? '',
            displayName: authUser.userMetadata?['display_name'] as String?,
            createdAt: DateTime.now().toUtc(),
          ),
        );
      }
    }

    await _sync.sync();
  }

  // ===========================================================================
  // Company lifecycle
  // ===========================================================================

  /// Creates a company and makes the caller its owner. The RPC also seeds a
  /// "Main Inventory" so the home screen is never empty.
  Future<Company> createCompany(String name) async {
    _requireConfigured();
    if (name.trim().isEmpty) {
      throw const ValidationFailure('Company name is required.');
    }

    final row = await _backend.rpc<Map<String, dynamic>>(
      'create_company',
      {'p_name': name.trim()},
    );
    await _sync.sync();
    return Company.fromMap(row);
  }

  Future<Company> joinCompany(String inviteCode) async {
    _requireConfigured();
    final code = inviteCode.trim().toUpperCase();
    if (code.isEmpty) {
      throw const ValidationFailure('Enter an invite code.');
    }

    final row = await _backend.rpc<Map<String, dynamic>>(
      'join_company_by_invite',
      {'p_code': code},
    );
    await _sync.sync();
    return Company.fromMap(row);
  }

  /// Rotates the company invite code, invalidating the previous one.
  Future<String> regenerateInviteCode() async {
    _requireConfigured();
    final code = await _backend.rpc<String>('regenerate_invite_code');
    await _sync.pull();
    return code;
  }

  Future<void> updateMemberRole(String userId, UserRole role) async {
    _requireConfigured();
    await _backend.rpc<Object?>('update_member_role', {
      'p_user_id': userId,
      'p_role': role.wire,
    });
    await _sync.pull();
  }

  Future<void> removeMember(String userId) async {
    _requireConfigured();
    await _backend.rpc<Object?>('remove_user_from_company', {'p_user_id': userId});
    await _sync.pull();
  }

  Future<void> leaveCompany() async {
    _requireConfigured();
    await _backend.rpc<Object?>('leave_company');
    await _sync.pull();
  }

  /// Renames the company. A plain table update, so it goes through the queue and
  /// therefore works offline.
  Future<void> renameCompany(String companyId, String name) async {
    if (name.trim().isEmpty) {
      throw const ValidationFailure('Company name is required.');
    }

    await (_db.update(_db.cachedCompanies)..where((t) => t.id.equals(companyId))).write(
      CachedCompaniesCompanion(name: Value(name.trim())),
    );

    await _db.enqueue(
      kind: 'update',
      target: 'companies',
      rowId: companyId,
      payload: {'name': name.trim()},
    );
    await _sync.push();
  }

  void _requireConfigured() {
    if (!_backend.isConfigured) throw const BackendNotConfiguredFailure();
  }
}
