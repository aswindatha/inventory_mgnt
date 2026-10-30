import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/providers.dart';
import '../common/widgets.dart';
import 'vendor_webview_args.dart';

/// Web variant of the vendor page: an embedded WebView does not exist here and
/// the storefronts send `X-Frame-Options` anyway, so the resolved add-to-cart
/// URL is opened in a new browser tab — still the user's own session, which is
/// the only place the add can actually happen.
///
/// There is no page-load probe in a foreign tab, so the item is marked
/// `added_to_cart` only when the user confirms it here — the same rule the
/// native probe enforces, applied manually.
class VendorWebViewScreen extends ConsumerWidget {
  const VendorWebViewScreen({super.key, required this.args});

  final VendorWebViewArgs args;

  Future<void> _openVendorPage(BuildContext context) async {
    final launched = await launchUrl(
      Uri.parse(args.url),
      webOnlyWindowName: '_blank',
    );
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the vendor page — allow pop-ups and '
              'try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(args.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              InfoBanner(
                message: args.cartItemId == null
                    ? 'The vendor page opens in a new browser tab.'
                    : 'The vendor page opens in a new browser tab. Finish the '
                        'add-to-cart there, then come back and confirm it here '
                        '— the app never marks an item as added on its own.',
                tone: BannerTone.info,
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.storefront_outlined,
                        size: 44,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        args.url,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () => _openVendorPage(context),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open vendor page'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: args.cartItemId == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await runGuarded(
                            context,
                            () => ref
                                .read(cartRepositoryProvider)
                                .markFailed(
                                  args.cartItemId!,
                                  'Could not be added on the vendor site.',
                                ),
                            successMessage: 'Marked as failed.',
                          );
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.close),
                        label: const Text("Couldn't add it"),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          await runGuarded(
                            context,
                            () => ref
                                .read(cartRepositoryProvider)
                                .markAdded(args.cartItemId!),
                            successMessage: 'Marked as added.',
                          );
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.check),
                        label: const Text('Mark as added'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
