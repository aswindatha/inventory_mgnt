import 'dart:math';

import '../../core/config/env.dart';

/// Component specifications resolved from an external part database (spec §4).
class ComponentMetadata {
  const ComponentMetadata({
    required this.mpn,
    this.name,
    this.manufacturer,
    this.footprint,
    this.dimensions,
    this.imageUrl,
    this.source = 'unknown',
    this.isMock = false,
  });

  final String mpn;
  final String? name;
  final String? manufacturer;
  final String? footprint;
  final String? dimensions;
  final String? imageUrl;

  /// Which provider produced this, surfaced in the UI so mock data is never
  /// mistaken for a real catalogue lookup.
  final String source;

  final bool isMock;

  bool get hasAnything =>
      name != null || manufacturer != null || footprint != null || imageUrl != null;
}

/// A source of component metadata.
abstract class ComponentMetadataProvider {
  String get name;

  /// False when credentials are absent, in which case [lookup] is skipped.
  bool get isConfigured;

  /// Returns null when the part is unknown. Implementations must not throw for
  /// a missing part or an API error — return null and let the caller fall back.
  Future<ComponentMetadata?> lookup(String mpn);
}

/// Deterministic offline provider.
///
/// Generates plausible electronics data seeded by the part number, so the same
/// MPN always resolves to the same values. This keeps the add-component flow
/// fully usable without API credentials and gives tests a stable fixture.
class MockMetadataProvider implements ComponentMetadataProvider {
  const MockMetadataProvider();

  @override
  String get name => 'Offline catalogue';

  @override
  bool get isConfigured => true;

  static const _manufacturers = [
    'Texas Instruments',
    'STMicroelectronics',
    'Microchip Technology',
    'NXP Semiconductors',
    'Vishay Intertechnology',
    'Murata Electronics',
    'ON Semiconductor',
    'Espressif Systems',
  ];

  static const _footprints = [
    'SOIC-8',
    'TQFN-16',
    '0805',
    '0603',
    'TO-220',
    'SOT-23',
    'QFN-32',
    'DIP-8',
  ];

  static const _dimensions = [
    '4.90 x 3.90 x 1.75 mm',
    '2.00 x 1.25 x 0.60 mm',
    '10.16 x 4.57 x 9.53 mm',
    '7.00 x 7.00 x 0.90 mm',
    '3.00 x 3.00 x 0.75 mm',
  ];

  static const _kinds = [
    'Precision Op-Amp',
    'Buck Converter',
    'Low-Dropout Regulator',
    'N-Channel MOSFET',
    'Ceramic Capacitor',
    'Thick Film Resistor',
    'ARM Cortex-M MCU',
    'Wi-Fi SoC Module',
    'Schottky Diode',
    'Inductor',
  ];

  @override
  Future<ComponentMetadata?> lookup(String mpn) async {
    final clean = mpn.trim();
    if (clean.isEmpty) return null;

    // Seed from the MPN so results are stable across runs.
    final seed = clean.toUpperCase().codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff);
    final random = Random(seed);

    final kind = _kinds[random.nextInt(_kinds.length)];
    final manufacturer = _manufacturers[random.nextInt(_manufacturers.length)];
    final footprint = _footprints[random.nextInt(_footprints.length)];
    final dimensions = _dimensions[random.nextInt(_dimensions.length)];

    return ComponentMetadata(
      mpn: clean.toUpperCase(),
      name: '$kind ${clean.toUpperCase()}',
      manufacturer: manufacturer,
      footprint: footprint,
      dimensions: dimensions,
      // No image URL: the offline provider has no real asset to point at, and
      // inventing one would produce broken images in the UI.
      imageUrl: null,
      source: name,
      isMock: true,
    );
  }
}

/// Marker for providers that need network access, used to decide whether a
/// lookup can be attempted at all.
mixin NetworkMetadataProvider on ComponentMetadataProvider {
  Duration get timeout => AppConfig.metadataTimeout;
}
