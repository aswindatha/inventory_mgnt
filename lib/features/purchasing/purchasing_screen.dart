import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/enums.dart';
import '../../data/models/vendor.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';
import 'vendor_webview_screen.dart';

/// Cart review: everything queued across vendors, with per-item status and a
/// retry path for the ones that failed (spec §7.7).
class PurchasingScreen extends ConsumerWidget {
  const PurchasingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(cartItemsProvider);

    return Scaffold(
      body: AsyncView<List<CartReviewItem>>(
        value: items,
        loading: const ListSkeleton(),
        onRetry: () => ref.invalidate(cartItemsProvider),
        isEmpty: (data) => data.isEmpty,
        emptyBuilder: () => const EmptyState(
          icon: Icons.shopping_cart_outlined,
          title: 'Nothing queued',
          message: 'Use "Add all to vendor cart" from an inventory, or "Buy the '
              'shortfall" from a project, and the items land here.',
        ),
        builder: (data) {
          final byVendor = <Vendor, List<CartReviewItem>>{};
          for (final item in data) {
            byVendor.putIfAbsent(item.item.vendor, () => []).add(item);
          }

          return RefreshIndicator(
            onRefresh: () => ref.read(syncServiceProvider).sync(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                for (final entry in byVendor.entries) ...[
                  _VendorSection(vendor: entry.key, items: entry.value),
                  const SizedBox(height: 20),
                ],
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Clear confirmed items?',
                      message: 'Removes everything already added to a vendor '
                          'cart from this list. Items still pending or failed '
                          'stay.',
                      confirmLabel: 'Clear',
                      destructive: false,
                    );
                    if (!ok || !context.mounted) return;
                    await runGuarded(
                      context,
                      () => ref.read(cartRepositoryProvider).clearAdded(),
                      successMessage: 'Cleared.',
                    );
                  },
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('Clear confirmed items'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _VendorSection extends ConsumerWidget {
  const _VendorSection({required this.vendor, required this.items});

  final Vendor vendor;
  final List<CartReviewItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final added = items.where((i) => i.item.status == CartItemStatus.addedToCart).length;
    final failed = items.where((i) => i.item.status == CartItemStatus.failed).length;
    final pending = items.length - added - failed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.storefront_outlined, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(vendor.label, style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            Text(
              '$pending pending · $added added · $failed failed',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final item in items) ...[
          _CartItemCard(item: item),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _CartItemCard extends ConsumerWidget {
  const _CartItemCard({required this.item});

  final CartReviewItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cart = item.item;

    final (label, color) = switch (cart.status) {
      CartItemStatus.addedToCart => ('Added', context.appColors.success),
      CartItemStatus.failed => ('Failed', context.appColors.danger),
      CartItemStatus.pending => ('Pending', context.appColors.warning),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.component.name,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                StatusChip(label: label, color: color),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${item.component.mpn} · ${formatQty(cart.quantity)} '
              '${item.component.unit} · ${item.inventoryName}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (cart.error != null) ...[
              const SizedBox(height: 8),
              Text(
                cart.error!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: context.appColors.danger,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                if (item.productUrl != null && item.productUrl!.isNotEmpty)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push(
                        '/vendor-webview',
                        extra: VendorWebViewArgs(
                          url: item.productUrl!,
                          title: '${cart.vendor.label} · ${item.component.mpn}',
                          vendor: cart.vendor,
                          cartItemId: cart.status == CartItemStatus.addedToCart
                              ? null
                              : cart.id,
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Open'),
                    ),
                  )
                else
                  Expanded(
                    child: Text(
                      'No cached product link — refresh its price from the '
                      'component screen.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                if (cart.status != CartItemStatus.addedToCart)
                  IconButton(
                    onPressed: () async {
                      final ok = await confirm(
                        context,
                        title: 'Mark as added?',
                        message: 'Only do this if the item really is in the '
                            'vendor cart.',
                        confirmLabel: 'Mark added',
                        destructive: false,
                      );
                      if (!ok || !context.mounted) return;
                      await runGuarded(
                        context,
                        () => ref.read(cartRepositoryProvider).markAdded(cart.id),
                      );
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    tooltip: 'Mark as added',
                  ),
                if (cart.status == CartItemStatus.failed)
                  IconButton(
                    onPressed: () => runGuarded(
                      context,
                      () => ref.read(cartRepositoryProvider).resetToPending(cart.id),
                    ),
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Retry',
                  ),
                IconButton(
                  onPressed: () => runGuarded(
                    context,
                    () => ref.read(cartRepositoryProvider).remove(cart.id),
                  ),
                  icon: Icon(Icons.delete_outline, color: context.appColors.danger),
                  tooltip: 'Remove from list',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
