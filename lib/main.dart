import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'app.dart';
import 'core/config/env.dart';
import 'data/local/app_database.dart';
import 'data/remote/backend.dart';
import 'providers/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase();

  // The app is expected to launch without credentials too — it then runs on its
  // local cache alone and the sign-in screen explains how to point it at a
  // backend. Crashing at startup would make the UI impossible to work on.
  var backend = Backend();
  if (AppConfig.isBackendConfigured) {
    await sb.Supabase.initialize(
      url: AppConfig.supabaseUrl,
      // Supabase renamed anon keys to publishable keys; `anonKey` still works
      // but is deprecated. The dart-define name is kept as SUPABASE_ANON_KEY
      // because that is what the dashboard and every tutorial call it.
      publishableKey: AppConfig.supabaseAnonKey,
    );
    backend = Backend(sb.Supabase.instance.client);
  }

  runApp(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        backendProvider.overrideWithValue(backend),
      ],
      child: const InventoryApp(),
    ),
  );
}
