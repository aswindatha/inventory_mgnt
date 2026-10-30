import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:postgrest/postgrest.dart' show PostgrestList, PostgrestTransformBuilder;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../core/config/env.dart';
import '../../core/failures.dart';
import '../../core/io/socket_exception.dart';

/// Thin, typed wrapper over [sb.SupabaseClient].
///
/// Its only jobs are (a) to keep the rest of the app free of Supabase types and
/// (b) to translate transport errors into [AppFailure]s. Business rules live in
/// the repositories; authorisation lives in the database.
class Backend {
  /// [client] is null when the app was launched without `--dart-define`
  /// credentials. Everything then fails with [BackendNotConfiguredFailure]
  /// rather than crashing at startup, so the UI stays explorable.
  Backend([this._client]);

  final sb.SupabaseClient? _client;

  sb.SupabaseClient get _c =>
      _client ?? (throw const BackendNotConfiguredFailure());

  /// The raw client, for the rare caller that needs it. Throws when unconfigured.
  sb.SupabaseClient get raw => _c;

  bool get isConfigured => _client != null && AppConfig.isBackendConfigured;

  String? get currentUserId => _client?.auth.currentUser?.id;

  // ===========================================================================
  // Auth
  // ===========================================================================

  Stream<sb.AuthState> get authStateChanges =>
      _client?.auth.onAuthStateChange ?? const Stream.empty();

  /// Where Supabase auth emails (confirm sign-up, reset password) send the user
  /// after verification. On web that's the origin the app is served from, so a
  /// `localhost:8080` build deep-links back to itself; on native it's the
  /// `io.inventorymgnt://login-callback` intent filter. `AUTH_REDIRECT_URL`
  /// overrides both (e.g. point a mobile build at a hosted web deployment).
  /// Whatever this resolves to must also be listed in Supabase → Authentication
  /// → URL Configuration → Redirect URLs, or Supabase falls back to Site URL.
  static String? get _authRedirectUrl {
    const override = String.fromEnvironment('AUTH_REDIRECT_URL');
    if (override.isNotEmpty) return override;
    return kIsWeb ? Uri.base.origin : 'io.inventorymgnt://login-callback';
  }

  Future<sb.User> signInWithPassword(String email, String password) async {
    try {
      final res = await _c.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      final user = res.user;
      if (user == null) {
        throw const AuthFailure('Sign in failed: no user returned.');
      }
      return user;
    } on sb.AuthException catch (e) {
      throw AuthFailure(_authMessage(e), cause: e);
    } catch (e) {
      throw _mapTransport(e);
    }
  }

  Future<sb.User?> signUpWithPassword(
    String email,
    String password, {
    String? displayName,
  }) async {
    try {
      final res = await _c.auth.signUp(
        email: email.trim(),
        password: password,
        data: displayName == null ? null : {'display_name': displayName},
        emailRedirectTo: _authRedirectUrl,
      );
      return res.user;
    } on sb.AuthException catch (e) {
      throw AuthFailure(_authMessage(e), cause: e);
    } catch (e) {
      throw _mapTransport(e);
    }
  }

  Future<void> signOut() async {
    try {
      await _c.auth.signOut();
    } on sb.AuthException catch (e) {
      throw AuthFailure(_authMessage(e), cause: e);
    } catch (e) {
      throw _mapTransport(e);
    }
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _c.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: _authRedirectUrl,
      );
    } on sb.AuthException catch (e) {
      throw AuthFailure(_authMessage(e), cause: e);
    } catch (e) {
      throw _mapTransport(e);
    }
  }

  // ===========================================================================
  // Table access
  // ===========================================================================

  Future<List<Map<String, dynamic>>> select(
    String table, {
    Map<String, Object?> equals = const {},
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    try {
      var filter = _c.from(table).select();
      for (final entry in equals.entries) {
        final value = entry.value;
        if (value == null) continue;
        filter = filter.eq(entry.key, value);
      }

      // `.order()` and `.limit()` return a transform builder rather than a
      // filter builder, so the chain has to change type partway through.
      PostgrestTransformBuilder<PostgrestList> query = filter;
      if (orderBy != null) {
        query = query.order(orderBy, ascending: ascending);
      }
      if (limit != null) {
        query = query.limit(limit);
      }

      final rows = await query;
      return rows.cast<Map<String, dynamic>>();
    } catch (e) {
      throw _mapError(e);
    }
  }

  Future<Map<String, dynamic>> insert(
    String table,
    Map<String, Object?> payload,
  ) async {
    try {
      final row = await _c.from(table).insert(payload).select().single();
      return row;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// Inserts and ignores the returned row — used by the sync queue, which only
  /// needs the write to have landed.
  Future<void> insertMany(String table, List<Map<String, Object?>> payloads) async {
    if (payloads.isEmpty) return;
    try {
      await _c.from(table).insert(payloads);
    } catch (e) {
      throw _mapError(e);
    }
  }

  Future<void> update(
    String table,
    String id,
    Map<String, Object?> payload,
  ) async {
    if (payload.isEmpty) return;
    try {
      await _c.from(table).update(payload).eq('id', id);
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// Upserts a row.
  ///
  /// [onConflict] is required whenever the table's real key is not `id` —
  /// `vendor_price_cache` is keyed on `(component_id, vendor)`, and PostgREST
  /// would otherwise try to match on the primary key and insert a duplicate.
  Future<void> upsert(
    String table,
    Map<String, Object?> payload, {
    String? onConflict,
  }) async {
    try {
      await _c.from(table).upsert(payload, onConflict: onConflict);
    } catch (e) {
      throw _mapError(e);
    }
  }

  Future<void> delete(String table, String id) async {
    try {
      await _c.from(table).delete().eq('id', id);
    } catch (e) {
      throw _mapError(e);
    }
  }

  // ===========================================================================
  // RPC
  // ===========================================================================

  Future<T> rpc<T>(String function, [Map<String, Object?> params = const {}]) async {
    try {
      final result = await _c.rpc(function, params: params);
      return result as T;
    } catch (e) {
      throw _mapError(e);
    }
  }

  // ===========================================================================
  // Storage
  // ===========================================================================

  /// Uploads to `<bucket>/<companyId>/<fileName>` and returns the public URL.
  /// The path prefix is what the storage RLS policy keys on, so a client cannot
  /// write into another company's folder.
  Future<String> uploadImage({
    required String companyId,
    required String fileName,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    try {
      final path = '$companyId/$fileName';
      await _c.storage.from(AppConfig.imageBucket).uploadBinary(
        path,
        bytes,
        fileOptions: sb.FileOptions(contentType: contentType, upsert: true),
      );
      return _c.storage.from(AppConfig.imageBucket).getPublicUrl(path);
    } catch (e) {
      throw _mapError(e);
    }
  }

  // ===========================================================================
  // Error mapping
  // ===========================================================================

  AppFailure _mapError(Object error) {
    if (error is AppFailure) return error;

    if (error is sb.PostgrestException) {
      final message = error.message;
      return switch (error.code) {
        // RLS policy or guard trigger rejection.
        '42501' => PermissionFailure(_humanise(message), cause: error),
        // CHECK violation — carries our "insufficient stock: have X, need Y".
        '23514' => ValidationFailure(_humanise(message), cause: error),
        // Unique violation.
        '23505' => ValidationFailure(_humanise(message), cause: error),
        // RAISE ... ERRCODE 'P0002'.
        'P0002' => NotFoundFailure(_humanise(message), cause: error),
        '22023' => ValidationFailure(_humanise(message), cause: error),
        _ => UnexpectedFailure(_humanise(message), cause: error),
      };
    }

    if (error is sb.AuthException) {
      return AuthFailure(_authMessage(error), cause: error);
    }

    return _mapTransport(error);
  }

  AppFailure _mapTransport(Object error) {
    if (error is AppFailure) return error;
    if (error is SocketException) {
      return NetworkFailure('No connection. Changes are queued and will sync.', cause: error);
    }
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout => NetworkFailure('The request timed out.', cause: error),
        DioExceptionType.connectionError => NetworkFailure(
          'No connection. Changes are queued and will sync.',
          cause: error,
        ),
        _ => UnexpectedFailure(error.message ?? 'Request failed.', cause: error),
      };
    }
    return UnexpectedFailure(error.toString(), cause: error);
  }

  /// Postgres `RAISE EXCEPTION 'insufficient stock: have 3, need 5'` arrives
  /// with a `ERROR:` prefix and trailing context. Strip it for display.
  String _humanise(String raw) {
    var message = raw.replaceFirst(RegExp(r'^ERROR:\s*'), '').trim();
    final contextIdx = message.indexOf('\nCONTEXT:');
    if (contextIdx >= 0) message = message.substring(0, contextIdx).trim();
    final detailIdx = message.indexOf('\nDETAIL:');
    if (detailIdx >= 0) message = message.substring(0, detailIdx).trim();
    return message.isEmpty ? 'The request was rejected.' : message;
  }

  String _authMessage(sb.AuthException e) {
    final raw = e.message.toLowerCase();
    if (raw.contains('invalid login credentials')) {
      return 'Incorrect email or password.';
    }
    if (raw.contains('email not confirmed')) {
      return 'Confirm your email address before signing in.';
    }
    if (raw.contains('user already registered')) {
      return 'An account with that email already exists.';
    }
    if (raw.contains('password should be at least')) {
      return 'Password is too short.';
    }
    if (raw.contains('rate limit') || raw.contains('too many')) {
      return 'Too many attempts. Wait a moment and try again.';
    }
    return e.message;
  }
}
