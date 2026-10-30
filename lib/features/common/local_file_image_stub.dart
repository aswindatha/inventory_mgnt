import 'package:flutter/widgets.dart';

/// Web has no local image cache, so `local_image_path` is never populated
/// there — this branch exists only so callers compile. Render the fallback.
Widget localFileImage(
  String path, {
  required double width,
  required double height,
  required Widget Function() fallback,
}) =>
    fallback();
