import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../providers/providers.dart';
import '../common/widgets.dart';
import 'vendor_webview_args.dart';

/// Opens a vendor page in the user's own session.
///
/// This is where a cart add actually happens. An HTTP request from the app
/// cannot populate the cart in the user's browser session, so the resolved
/// add-to-cart URL is opened here instead — and the item is only recorded as
/// added once the page itself confirms it (spec §6).
class VendorWebViewScreen extends ConsumerStatefulWidget {
  const VendorWebViewScreen({super.key, required this.args});

  final VendorWebViewArgs args;

  @override
  ConsumerState<VendorWebViewScreen> createState() => _VendorWebViewScreenState();
}

class _VendorWebViewScreenState extends ConsumerState<VendorWebViewScreen> {
  late final WebViewController _controller;

  bool _loading = true;
  bool _confirmed = false;
  String? _error;

  /// Runs after each page settles. Looks for the markers both storefronts emit
  /// once an item is genuinely in the cart.
  static const String _probeScript = '''
    (function () {
      try {
        var text = (document.body && document.body.innerText || '').toLowerCase();
        var path = window.location.pathname.toLowerCase();
        var selectors = [
          '.woocommerce-cart-form',
          '.cart_item',
          '.woocommerce-message',
          '.cart__items',
          '[data-cart-item]',
          '.cart-drawer__items'
        ];
        var hasItemNode = selectors.some(function (s) { return document.querySelector(s) !== null; });
        var onCartPage = path.indexOf('/cart') === 0 || path.indexOf('/cart') === 0;
        var saysAdded = text.indexOf('added to your cart') !== -1 ||
                        text.indexOf('has been added to your cart') !== -1 ||
                        text.indexOf('item added to your cart') !== -1;
        return JSON.stringify({
          confirmed: saysAdded || (onCartPage && hasItemNode),
          url: window.location.href
        });
      } catch (e) {
        return JSON.stringify({ confirmed: false, url: window.location.href });
      }
    })();
  ''';

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Theme.of(context).colorScheme.surface)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) async {
            if (mounted) setState(() => _loading = false);
            await _probe();
          },
          onWebResourceError: (error) {
            // Sub-resource failures (ads, trackers) are noise; only surface a
            // failure to load the main document.
            if (error.isForMainFrame ?? true) {
              if (mounted) {
                setState(() {
                  _loading = false;
                  _error = error.description;
                });
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.args.url));
  }

  Future<void> _probe() async {
    if (_confirmed) return;

    try {
      final raw = await _controller.runJavaScriptReturningResult(_probeScript);
      final decoded = raw.toString().replaceAll(RegExp(r'^"|"$'), '').replaceAll(r'\"', '"');
      if (!decoded.contains('"confirmed":true')) return;

      if (!mounted) return;
      setState(() => _confirmed = true);

      final cartItemId = widget.args.cartItemId;
      if (cartItemId != null) {
        await ref.read(cartRepositoryProvider).markAdded(cartItemId);
      }
    } catch (_) {
      // The probe is best-effort; a failure just means we cannot auto-confirm,
      // and the user can mark it themselves.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.args.title),
        actions: [
          IconButton(
            onPressed: () => _controller.reload(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            InfoBanner(
              message: 'Could not load the vendor page: $_error',
              tone: BannerTone.danger,
            )
          else if (_confirmed)
            const InfoBanner(
              message: 'Item confirmed in the vendor cart. Finish checkout on '
                  'the vendor site.',
              tone: BannerTone.success,
              icon: Icons.check_circle_outline,
            )
          else
            const InfoBanner(
              message: 'Complete the add-to-cart on the vendor page. The app '
                  'records it automatically once the site confirms.',
              tone: BannerTone.info,
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
      bottomNavigationBar: widget.args.cartItemId == null
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
                                  widget.args.cartItemId!,
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
                        onPressed: _confirmed
                            ? () => Navigator.of(context).pop()
                            : () async {
                                await runGuarded(
                                  context,
                                  () => ref
                                      .read(cartRepositoryProvider)
                                      .markAdded(widget.args.cartItemId!),
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
