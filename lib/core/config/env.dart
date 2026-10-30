/// Compile-time configuration, supplied via `--dart-define`.
///
/// Nothing secret belongs here. The Supabase anon key is designed to be shipped
/// in clients — it only grants what the RLS policies in
/// `supabase/migrations/0002_rls.sql` allow. The service_role key bypasses RLS
/// entirely and must never be placed in this app.
class AppConfig {
  const AppConfig._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// False when the app is launched without `--dart-define` credentials. The UI
  /// surfaces this instead of throwing on every network call.
  static bool get isBackendConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static const String imageBucket = 'component-images';

  /// Desktop Chrome UA. Vendor storefronts routinely 403 non-browser agents;
  /// this is the identity the scrapers present (spec §5) and it is reused by
  /// cart automation (spec §6) so both look like the same client.
  static const String scraperUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const Duration scraperTimeout = Duration(seconds: 20);

  /// How long a `vendor_price_cache` row is considered fresh (spec §5).
  static const Duration priceCacheTtl = Duration(hours: 6);

  /// Politeness delay between cart-automation requests (spec §6: "rate-limit
  /// and stagger requests").
  static const Duration cartRequestSpacing = Duration(milliseconds: 1200);

  static const Duration metadataTimeout = Duration(seconds: 15);

  /// Optional: real part-catalogue lookups. Without these the app falls back to
  /// the deterministic offline catalogue, so the add-component flow still works.
  static const String digiKeyClientId = String.fromEnvironment('DIGIKEY_CLIENT_ID');
  static const String digiKeyClientSecret = String.fromEnvironment('DIGIKEY_CLIENT_SECRET');

  static bool get isDigiKeyConfigured =>
      digiKeyClientId.isNotEmpty && digiKeyClientSecret.isNotEmpty;
}
