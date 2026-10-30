import 'dart:io';

import 'package:flutter/widgets.dart';

/// The device-cached copy of a component image, written by the image store.
Widget localFileImage(
  String path, {
  required double width,
  required double height,
  required Widget Function() fallback,
}) {
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => fallback(),
  );
}
