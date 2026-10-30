import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/failures.dart';
import '../../data/remote/backend.dart';
import 'local_image_files.dart';

/// Result of resolving a component image.
///
/// [localPath] is a device-only cache path used for instant offline rendering;
/// [publicUrl] is the canonical, shareable Supabase Storage URL stored in the
/// database so every user on every device resolves the same image (spec §4).
typedef StoredImage = ({String? localPath, String? publicUrl});

/// Downloads component images once, then keeps two copies: a local file for
/// offline rendering and an object-storage URL for everyone else.
class ImageStore {
  ImageStore(this._backend, {Dio? dio})
    : _dio = dio ?? Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        responseType: ResponseType.bytes,
        validateStatus: (s) => s != null && s < 400,
      ));

  final Backend _backend;
  final Dio _dio;

  static const int maxImageBytes = 5 * 1024 * 1024; // matches the bucket limit

  /// Fetches [imageUrl], caches it locally and uploads it to object storage.
  ///
  /// Neither half is fatal on its own: if the upload fails the component still
  /// gets a local image, and if the download fails the caller keeps whatever
  /// `image_url` the metadata provider supplied.
  Future<StoredImage> store({
    required String imageUrl,
    required String companyId,
    required String componentId,
  }) async {
    Uint8List bytes;
    try {
      bytes = await _download(imageUrl);
    } on AppFailure catch (e) {
      throw NetworkFailure('Could not download the component image: ${e.userMessage}');
    }

    final localPath = await writeLocalImage(
      componentId,
      bytes,
      _extensionFor(imageUrl),
    );

    String? publicUrl;
    try {
      publicUrl = await _backend.uploadImage(
        companyId: companyId,
        fileName: '$componentId${_extensionFor(imageUrl)}',
        bytes: bytes,
        contentType: _contentTypeFor(imageUrl),
      );
    } on AppFailure {
      // Storage may be unconfigured or unreachable. A local image is still
      // useful, and the metadata provider's original URL remains as a fallback.
      publicUrl = null;
    }

    return (localPath: localPath, publicUrl: publicUrl);
  }

  Future<Uint8List> _download(String url) async {
    try {
      final response = await _dio.get<List<int>>(url);
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const NetworkFailure('The image response was empty.');
      }
      if (data.length > maxImageBytes) {
        throw const NetworkFailure('That image is larger than the 5 MB limit.');
      }
      return Uint8List.fromList(data);
    } on DioException catch (e) {
      throw NetworkFailure(e.message ?? 'Image download failed.', cause: e);
    }
  }

  /// Removes the cached file for a component, if one exists. A no-op where the
  /// platform has no local image cache (web).
  Future<void> evictLocal(String localPath) => evictLocalImage(localPath);

  static String _extensionFor(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.png' || '.jpg' || '.jpeg' || '.webp' || '.gif' => ext,
      _ => '.jpg',
    };
  }

  static String _contentTypeFor(String url) => switch (_extensionFor(url)) {
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.gif' => 'image/gif',
    _ => 'image/jpeg',
  };
}
