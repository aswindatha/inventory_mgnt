import 'package:dio/dio.dart';

import '../../core/config/env.dart';
import 'component_metadata.dart';

/// Real part-catalogue lookups against the Digi-Key Product Information API v4.
///
/// Requires `--dart-define=DIGIKEY_CLIENT_ID=... --dart-define=DIGIKEY_CLIENT_SECRET=...`.
/// When either is missing [isConfigured] is false and the caller skips straight
/// to the offline catalogue.
///
/// Every failure mode — no credentials, expired token, rate limit, unknown part,
/// network error — resolves to `null` rather than an exception. A metadata
/// lookup is an assist, never a blocker for adding a component by hand.
class DigiKeyMetadataProvider implements ComponentMetadataProvider {
  DigiKeyMetadataProvider({Dio? dio})
    : _dio = dio ?? Dio(BaseOptions(
        connectTimeout: AppConfig.metadataTimeout,
        receiveTimeout: AppConfig.metadataTimeout,
        validateStatus: (s) => s != null && s < 500,
      ));

  final Dio _dio;

  String? _accessToken;
  DateTime? _tokenExpiry;

  @override
  String get name => 'Digi-Key';

  @override
  bool get isConfigured => AppConfig.isDigiKeyConfigured;

  @override
  Future<ComponentMetadata?> lookup(String mpn) async {
    if (!isConfigured) return null;

    final clean = mpn.trim();
    if (clean.isEmpty) return null;

    try {
      final token = await _token();
      if (token == null) return null;

      final response = await _dio.post<Map<String, dynamic>>(
        'https://api.digikey.com/products/v4/search/keyword',
        data: {'Keywords': clean, 'Limit': 1, 'Offset': 0},
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'X-DIGIKEY-Client-Id': AppConfig.digiKeyClientId,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );

      if (response.statusCode != 200) return null;

      final products = response.data?['Products'];
      if (products is! List || products.isEmpty) return null;

      final product = products.first;
      if (product is! Map) return null;

      return _toMetadata(clean, product.cast<String, dynamic>());
    } catch (_) {
      // Metadata is best-effort; a failure here must not surface as an error.
      return null;
    }
  }

  Future<String?> _token() async {
    final expiry = _tokenExpiry;
    if (_accessToken != null && expiry != null && DateTime.now().isBefore(expiry)) {
      return _accessToken;
    }

    final response = await _dio.post<Map<String, dynamic>>(
      'https://api.digikey.com/v1/oauth2/token',
      data: {
        'grant_type': 'client_credentials',
        'client_id': AppConfig.digiKeyClientId,
        'client_secret': AppConfig.digiKeyClientSecret,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Accept': 'application/json'},
      ),
    );

    if (response.statusCode != 200) return null;

    final token = response.data?['access_token'] as String?;
    final expiresIn = response.data?['expires_in'];
    if (token == null) return null;

    _accessToken = token;
    // Refresh a minute early so a token cannot expire mid-flight.
    _tokenExpiry = DateTime.now().add(
      Duration(seconds: (expiresIn is num ? expiresIn.toInt() : 600) - 60),
    );
    return token;
  }

  ComponentMetadata _toMetadata(String mpn, Map<String, dynamic> product) {
    final description = product['Description'];
    final name = description is Map
        ? description['ProductDescription']?.toString()
        : description?.toString();

    final manufacturer = product['Manufacturer'];
    final manufacturerName = manufacturer is Map
        ? manufacturer['Name']?.toString()
        : manufacturer?.toString();

    String? footprint;
    String? dimensions;

    final parameters = product['Parameters'];
    if (parameters is List) {
      for (final parameter in parameters) {
        if (parameter is! Map) continue;
        final label = parameter['ParameterText']?.toString().toLowerCase() ?? '';
        final value = parameter['ValueText']?.toString();
        if (value == null || value.isEmpty) continue;

        if (footprint == null &&
            (label.contains('package') || label.contains('case') || label.contains('footprint'))) {
          footprint = value;
        } else if (dimensions == null &&
            (label.contains('size') || label.contains('dimension'))) {
          dimensions = value;
        }
      }
    }

    return ComponentMetadata(
      mpn: product['ManufacturerProductNumber']?.toString() ?? mpn,
      name: name,
      manufacturer: manufacturerName,
      footprint: footprint,
      dimensions: dimensions,
      imageUrl: product['PhotoUrl']?.toString() ?? product['PrimaryPhoto']?.toString(),
      source: this.name,
      isMock: false,
    );
  }
}
