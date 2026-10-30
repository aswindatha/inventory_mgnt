import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/failures.dart';
import '../../core/theme.dart';
import '../../data/models/enums.dart';
import '../../data/models/inventory.dart';
import '../../data/repositories/cart_repository.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';
import 'vendor_webview_screen.dart';

/// Adds a single component to a vendor cart.
Future<void> addSingleToVendorCart(
  BuildContext context,
  WidgetRef ref, {
  required Component component,
  num quantity = 1,
}) =>
    _runCartFlow(
      context,
      ref,
      components: [component],
      quantityPerItem: quantity,
      scopeLabel: component.name,
    );

/// Bulk "add all to cart" for an inventory or a project shortfall list (spec §6).
Future<void> addAllToVendorCart(
  BuildContext context,
  WidgetRef ref, {
  required List<Component> components,
  required String scopeLabel,
}) =>
    _runCartFlow(
      context,
      ref,
      components: components,
      quantityPerItem: 1,
      scopeLabel: scopeLabel,
    );

Future<void> _runCartFlow(
  BuildContext context,
  WidgetRef ref, {
  required List<Component> components,
  required num quantityPerItem,
  required String scopeLabel,
}) async {
  if (components.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nothing to add — no components in this list.')),
    );
    return;
  }

  final user = ref.read(currentUserProvider).value;
  if (user == null) return;

  final vendors = ref.read(cartRepositoryProvider).supportedVendors;
  if (vendors.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No supported vendors configured.')),
    );
    return;
  }

  final vendor = await _pickVendor(context, vendors, components.length);
  if (vendor == null || !context.mounted) return;

  List<PreparedCartItem>? prepared;
  try {
    prepared = await _withProgress(
      context,
      label: 'Resolving ${components.length} item'
          '${components.length == 1 ? '' : 's'} on ${vendor.label}…',
      action: () => ref.read(cartRepositoryProvider).queueAndPrepare(
        userId: user.id,
        components: components,
        vendor: vendor,
        quantityPerItem: quantityPerItem,
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is AppFailure ? e.userMessage : e.toString()),
        ),
      );
    }
    return;
  }

  if (prepared == null || !context.mounted) return;

  await _showOutcome(context, vendor: vendor, scopeLabel: scopeLabel, prepared: prepared);
}

Future<Vendor?> _pickVendor(
  BuildContext context,
  List<Vendor> vendors,
  int itemCount,
) {
  // One vendor: no point asking.
  if (vendors.length == 1) return Future.value(vendors.first);

  return showAppSheet<Vendor>(
    context,
    child: SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add to vendor cart',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '$itemCount item${itemCount == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          for (final vendor in vendors)
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: Text(vendor.label),
              subtitle: Text(
                vendor.host,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () => Navigator.of(context).pop(vendor),
            ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

Future<T?> _withProgress<T>(
  BuildContext context, {
  required String label,
  required Future<T> Function() action,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  );

  try {
    final result = await action();
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    return result;
  } catch (_) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    rethrow;
  }
}

Future<void> _showOutcome(
  BuildContext context, {
  required Vendor vendor,
  required String scopeLabel,
  required List<PreparedCartItem> prepared,
}) async {
  final ready = prepared.where((p) => p.isReady).toList();
  final manual = prepared.where((p) => p.needsManual).toList();
  final unavailable = prepared.where((p) => p.isUnavailable).toList();

  await showAppSheet<void>(
    context,
    child: SafeArea(
      child: Builder(
        builder: (sheetContext) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ready for ${vendor.label}',
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              scopeLabel,
              style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            _OutcomeRow(
              icon: Icons.shopping_cart_checkout,
              color: context.appColors.success,
              label: '${ready.length} ready to add',
              detail: ready.isEmpty
                  ? null
                  : 'Opening each one lands it in your own vendor session.',
            ),
            if (manual.isNotEmpty)
              _OutcomeRow(
                icon: Icons.touch_app_outlined,
                color: context.appColors.warning,
                label: '${manual.length} need a manual add',
                detail: manual.first.message ??
                    'The product page could be opened but not an add-to-cart link.',
              ),
            if (unavailable.isNotEmpty)
              _OutcomeRow(
                icon: Icons.block_outlined,
                color: context.appColors.danger,
                label: '${unavailable.length} could not be resolved',
                detail: unavailable.first.message ??
                    'Usually a missing cached product link, or bot protection.',
              ),

            const SizedBox(height: 8),
            if (prepared.any((p) => p.canOpen)) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _openNext(context, prepared.where((p) => p.canOpen).toList(), 0);
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open vendor pages'),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Review in Purchasing'),
            ),
            const SizedBox(height: 4),
            Text(
              'The app never marks an item as added until the vendor site '
              'confirms it.',
              textAlign: TextAlign.center,
              style: Theme.of(sheetContext).textTheme.labelSmall?.copyWith(
                color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      ),
    ),
  );
}

/// Opens vendor pages one after another; each returns to the list so the user
/// can see progress rather than being dropped back at the start.
void _openNext(BuildContext context, List<PreparedCartItem> items, int index) {
  if (index >= items.length) return;
  final item = items[index];

  context.push(
    '/vendor-webview',
    extra: VendorWebViewArgs(
      url: item.url!,
      title: '${item.vendor.label} · ${item.mpn}',
      vendor: item.vendor,
      cartItemId: item.cartItemId,
    ),
  );
}

class _OutcomeRow extends StatelessWidget {
  const _OutcomeRow({
    required this.icon,
    required this.color,
    required this.label,
    this.detail,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
