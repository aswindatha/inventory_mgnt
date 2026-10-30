import 'component_metadata.dart';
import 'digikey_provider.dart';

/// Resolves component specifications by MPN, trying real catalogue providers
/// first and falling back to the deterministic offline catalogue.
///
/// The fallback is always available, so this never returns null for a non-empty
/// part number. Callers must check [ComponentMetadata.isMock] and label the
/// result accordingly — approximate data presented as a real catalogue match
/// would be worse than no data.
class MetadataService {
  MetadataService({List<ComponentMetadataProvider>? providers})
    : providers = providers ?? _defaultProviders;

  static final List<ComponentMetadataProvider> _defaultProviders = [
    DigiKeyMetadataProvider(),
    const MockMetadataProvider(),
  ];

  final List<ComponentMetadataProvider> providers;

  /// Providers that could actually be queried right now.
  List<ComponentMetadataProvider> get availableProviders =>
      providers.where((p) => p.isConfigured).toList(growable: false);

  Future<ComponentMetadata?> lookup(String mpn) async {
    final clean = mpn.trim();
    if (clean.isEmpty) return null;

    for (final provider in providers) {
      if (!provider.isConfigured) continue;
      final result = await provider.lookup(clean);
      if (result != null && result.hasAnything) return result;
    }

    return null;
  }
}
