import 'dart:typed_data';

/// The web build has no writable file system for the image cache — component
/// images resolve from their remote `image_url` only. Returning null keeps
/// `local_image_path` empty rather than fabricating a path that cannot load.
Future<String?> writeLocalImage(
  String componentId,
  Uint8List bytes,
  String extension,
) async =>
    null;

Future<void> evictLocalImage(String localPath) async {}
