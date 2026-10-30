import 'package:flutter/material.dart';

import 'vendor_webview_args.dart';

/// Fallback for platforms that are neither native (`dart:io`) nor web — the
/// cart flow cannot open a vendor session there.
class VendorWebViewScreen extends StatelessWidget {
  const VendorWebViewScreen({super.key, required this.args});

  final VendorWebViewArgs args;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(args.title)),
      body: const Center(
        child: Text('Opening vendor pages is not supported on this platform.'),
      ),
    );
  }
}
