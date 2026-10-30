import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<Directory> _imageDir() async {
  final dir = await getApplicationDocumentsDirectory();
  final images = Directory(p.join(dir.path, 'component_images'));
  if (!await images.exists()) {
    await images.create(recursive: true);
  }
  return images;
}

/// Writes [bytes] to the on-device image cache and returns the file path.
Future<String?> writeLocalImage(
  String componentId,
  Uint8List bytes,
  String extension,
) async {
  final dir = await _imageDir();
  final file = File(p.join(dir.path, '$componentId$extension'));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Removes the cached file for a component, if one exists.
Future<void> evictLocalImage(String localPath) async {
  final file = File(localPath);
  if (await file.exists()) {
    await file.delete();
  }
}
