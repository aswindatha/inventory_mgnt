import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/enums.dart';
import '../../data/models/inventory.dart';
import '../../data/models/vendor.dart';
import '../../providers/providers.dart';
import '../common/local_file_image.dart';
import '../common/widgets.dart';
import '../purchasing/cart_actions.dart';

class ComponentDetailScreen extends ConsumerStatefulWidget {
  const ComponentDetailScreen({super.key, required this.componentId});

  final String componentId;

  @override
  ConsumerState<ComponentDetailScreen> createState() =>
      _ComponentDetailScreenState();
}

class _ComponentDetailScreenState extends ConsumerState<ComponentDetailScreen> {
  /// Vendors currently being re-scraped, so the UI can shimmer just those rows.
  final Set<Vendor> _refreshing = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshStalePrices());
    // The audit trail is not part of the routine sync; fetch it on demand.
    unawaited(ref.read(inventoryRepositoryProvider).refreshTransactions(widget.componentId));
  }

  /// Cache-first: renders whatever is stored, and only goes to the network for
  /// vendors whose cached row is missing or older than the TTL (spec §5).
  Future<void> _refreshStalePrices() async {
    final component = await ref.read(appDatabaseProvider).componentById(widget.componentId);
    if (component == null || !mounted) return;

    final cached = await ref.read(priceRepositoryProvider).pricesFor(component.id);
    final vendors = ref.read(supportedVendorsProvider);

    for (final vendor in vendors) {
      final existing = cached.where((p) => p.vendor == vendor).firstOrNull;
      if (existing != null && !existing.isStale()) continue;
      await _refreshVendor(component, vendor);
    }
  }

  Future<void> _refreshVendor(Component component, Vendor vendor) async {
    if (!mounted || _refreshing.contains(vendor)) return;
    setState(() => _refreshing.add(vendor));

    try {
      await ref.read(priceRepositoryProvider).getOrRefresh(
        componentId: component.id,
        mpn: component.mpn,
        vendor: vendor,
        force: true,
      );
    } finally {
      if (mounted) setState(() => _refreshing.remove(vendor));
    }
  }

  @override
  Widget build(BuildContext context) {
    final component = ref.watch(componentProvider(widget.componentId));
    final permissions = ref.watch(permissionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(component.value?.name ?? 'Component'),
        actions: [
          component.value == null
              ? const SizedBox.shrink()
              : PopupMenuButton<String>(
                  onSelected: (value) async {
                    final current = component.value!;
                    switch (value) {
                      case 'edit':
                        await _showEditSheet(current);
                      case 'delete':
                        final ok = await confirm(
                          context,
                          title: 'Delete ${current.mpn}?',
                          message: 'This removes the component and its stock '
                              'history. Project lines using it are removed too.',
                        );
                        if (!ok || !context.mounted) return;
                        final done = await runGuarded(
                          context,
                          () => ref
                              .read(inventoryRepositoryProvider)
                              .deleteComponent(current.id),
                          successMessage: 'Component deleted.',
                        );
                        if (done && context.mounted) {
                          if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go('/inventory/${current.inventoryId}');
                          }
                        }
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit details')),
                    if (permissions.canEditComponents)
                      destructiveMenuItem('delete', 'Delete component'),
                  ],
                ),
        ],
      ),
      body: AsyncView<Component?>(
        value: component,
        loading: const ListSkeleton(items: 3, cardHeight: 150),
        onRetry: () => ref.invalidate(componentProvider(widget.componentId)),
        isEmpty: (data) => data == null,
        emptyBuilder: () => const EmptyState(
          icon: Icons.search_off,
          title: 'Component not found',
          message: 'It may have been deleted on another device.',
        ),
        builder: (data) => _body(data!),
      ),
    );
  }

  Widget _body(Component component) {
    return RefreshIndicator(
      onRefresh: () => ref.read(syncServiceProvider).sync(),
      child: ListView(
        padding: const EdgeInsets.all(16),
      children: [
        _Header(component: component),
        const SizedBox(height: 16),

        SectionCard(
          title: 'Specifications',
          child: Column(
            children: [
              DetailRow(label: 'MPN', value: component.mpn, icon: Icons.qr_code_2),
              if (component.manufacturer != null)
                DetailRow(
                  label: 'Manufacturer',
                  value: component.manufacturer!,
                  icon: Icons.factory_outlined,
                ),
              if (component.footprint != null)
                DetailRow(
                  label: 'Footprint',
                  value: component.footprint!,
                  icon: Icons.dashboard_outlined,
                ),
              if (component.dimensions != null)
                DetailRow(
                  label: 'Dimensions',
                  value: component.dimensions!,
                  icon: Icons.straighten,
                ),
              DetailRow(
                label: 'Low stock at',
                value: '${formatQty(component.lowStockThreshold)} ${component.unit}',
                icon: Icons.trending_down,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        _StockCard(component: component),
        const SizedBox(height: 16),

        _VendorPricesCard(
          component: component,
          refreshing: _refreshing,
          onRefresh: (vendor) => _refreshVendor(component, vendor),
        ),
        const SizedBox(height: 16),

        _TransactionsCard(componentId: component.id),
        ],
      ),
    );
  }

  Future<void> _showEditSheet(Component component) async {
    final saved = await showAppSheet<bool>(
      context,
      child: _EditComponentSheet(component: component),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Component updated.')),
      );
    }
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.component});

  final Component component;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final localPath = component.localImagePath;
    final url = component.imageUrl;

    Widget placeholder() => Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(Icons.memory, size: 36, color: theme.colorScheme.onSurfaceVariant),
    );

    Widget image;
    if (localPath != null && localPath.isNotEmpty) {
      image = ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: localFileImage(
          localPath,
          width: 96,
          height: 96,
          fallback: placeholder,
        ),
      );
    } else if (url != null && url.isNotEmpty) {
      image = ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: CachedNetworkImage(
          imageUrl: url,
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          placeholder: (_, _) => placeholder(),
          errorWidget: (_, _, _) => placeholder(),
        ),
      );
    } else {
      image = placeholder();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            image,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(component.name, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    component.mpn,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  StockBadge(
                    quantity: component.quantity,
                    unit: component.unit,
                    isLow: component.isLowStock,
                  ),
                  if (component.isLowStock) ...[
                    const SizedBox(height: 8),
                    Text(
                      'At or below the low stock threshold.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: context.appColors.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StockCard extends ConsumerWidget {
  const _StockCard({required this.component});

  final Component component;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionCard(
      title: 'Stock',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '${formatQty(component.quantity)} ${component.unit}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const Spacer(),
              Text(
                'Updated ${formatRelativeTime(component.updatedAt)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _adjust(context, ref, -1),
                  icon: const Icon(Icons.remove),
                  label: const Text('1'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _adjust(context, ref, 1),
                  icon: const Icon(Icons.add),
                  label: const Text('1'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showAdjustSheet(context, ref),
                  icon: const Icon(Icons.tune),
                  label: const Text('Custom'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => addSingleToVendorCart(
              context,
              ref,
              component: component,
              quantity: component.lowStockThreshold > 0
                  ? (component.lowStockThreshold - component.quantity).clamp(1, double.infinity)
                  : 1,
            ),
            icon: const Icon(Icons.add_shopping_cart),
            label: const Text('Order more'),
          ),
        ],
      ),
    );
  }

  Future<void> _adjust(BuildContext context, WidgetRef ref, num delta) async {
    await runGuarded(
      context,
      () => ref.read(inventoryRepositoryProvider).adjustQuantity(
        componentId: component.id,
        changeQty: delta,
        reason: TransactionReason.manualAdjust,
      ),
    );
  }

  Future<void> _showAdjustSheet(BuildContext context, WidgetRef ref) async {
    final result = await showAppSheet<num>(
      context,
      child: _AdjustSheet(component: component),
    );
    if (result == null || !context.mounted) return;

    await runGuarded(
      context,
      () => ref.read(inventoryRepositoryProvider).adjustQuantity(
        componentId: component.id,
        changeQty: result,
        reason: TransactionReason.manualAdjust,
      ),
      successMessage: result > 0
          ? 'Added ${formatQty(result)} ${component.unit}.'
          : 'Removed ${formatQty(result.abs())} ${component.unit}.',
    );
  }
}

class _AdjustSheet extends StatefulWidget {
  const _AdjustSheet({required this.component});

  final Component component;

  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends State<_AdjustSheet> {
  final _amount = TextEditingController();
  bool _add = true;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Adjust stock', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Currently ${formatQty(widget.component.quantity)} ${widget.component.unit}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Add'), icon: Icon(Icons.add)),
              ButtonSegment(
                value: false,
                label: Text('Remove'),
                icon: Icon(Icons.remove),
              ),
            ],
            selected: {_add},
            onSelectionChanged: (s) => setState(() => _add = s.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Quantity',
              suffixText: widget.component.unit,
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Recorded as a manual adjustment in the stock history.',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              final parsed = num.tryParse(_amount.text.trim());
              if (parsed == null || parsed <= 0) {
                setState(() => _error = 'Enter a positive number');
                return;
              }
              if (!_add && parsed > widget.component.quantity) {
                setState(() => _error =
                    'Only ${formatQty(widget.component.quantity)} in stock');
                return;
              }
              Navigator.of(context).pop(_add ? parsed : -parsed);
            },
            child: const Text('Apply adjustment'),
          ),
        ],
      ),
    );
  }
}

/// Live vendor price and stock, cache-first (spec §5).
class _VendorPricesCard extends ConsumerWidget {
  const _VendorPricesCard({
    required this.component,
    required this.refreshing,
    required this.onRefresh,
  });

  final Component component;
  final Set<Vendor> refreshing;
  final Future<void> Function(Vendor vendor) onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vendors = ref.watch(supportedVendorsProvider);
    final pricesAsync = ref.watch(vendorPricesProvider(component.id));

    return SectionCard(
      title: 'Vendor pricing',
      child: vendors.isEmpty
          ? const Text('No vendor scrapers registered.')
          : AsyncView(
              value: pricesAsync,
              loading: const ListSkeleton(
                items: 2,
                cardHeight: 56,
                padding: EdgeInsets.zero,
              ),
              onRetry: () =>
                  ref.invalidate(vendorPricesProvider(component.id)),
              builder: (prices) => Column(
                children: [
                  for (final vendor in vendors) ...[
                    _VendorRow(
                      vendor: vendor,
                      price: prices.where((p) => p.vendor == vendor).firstOrNull,
                      isLoading: refreshing.contains(vendor),
                      onRefresh: () => onRefresh(vendor),
                    ),
                    if (vendor != vendors.last) const Divider(height: 24),
                  ],
                ],
              ),
            ),
    );
  }
}

class _VendorRow extends StatelessWidget {
  const _VendorRow({
    required this.vendor,
    required this.price,
    required this.isLoading,
    required this.onRefresh,
  });

  final Vendor vendor;
  final VendorPrice? price;
  final bool isLoading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = price;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                vendor.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (isLoading)
              const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              IconButton(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh, size: 18),
                visualDensity: VisualDensity.compact,
                tooltip: 'Re-check price',
              ),
          ],
        ),
        const SizedBox(height: 6),

        if (isLoading && current == null)
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShimmerBox(width: 90, height: 20),
              SizedBox(height: 8),
              ShimmerBox(width: 140),
            ],
          )
        else if (current == null)
          Text(
            'Not checked yet.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          Row(
            children: [
              Text(
                formatCurrency(current.price, currency: current.currency),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              _StockPill(inStock: current.inStock),
              const Spacer(),
              Text(
                formatLastFetched(current.fetchedAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),

        if (current != null && current.isUnavailable && !isLoading) ...[
          const SizedBox(height: 6),
          Text(
            'Price unavailable (Bot Protection). The vendor refused an '
            'automated request — check the site directly.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: context.appColors.warning,
            ),
          ),
        ],
        if (current?.productUrl != null) ...[
          const SizedBox(height: 6),
          SelectableText(
            current!.productUrl!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
            maxLines: 1,
          ),
        ],
      ],
    );
  }
}

class _StockPill extends StatelessWidget {
  const _StockPill({required this.inStock});

  final bool? inStock;

  @override
  Widget build(BuildContext context) {
    // Null means "we could not tell", which is deliberately distinct from
    // "out of stock".
    final (label, color) = switch (inStock) {
      true => ('In stock', context.appColors.success),
      false => ('Out of stock', context.appColors.danger),
      null => ('Unknown', context.appColors.neutral),
    };
    return StatusChip(label: label, color: color);
  }
}

class _TransactionsCard extends ConsumerWidget {
  const _TransactionsCard({required this.componentId});

  final String componentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txAsync = ref.watch(transactionsProvider(componentId));

    return SectionCard(
      title: 'Stock history',
      child: AsyncView(
        value: txAsync,
        loading: const ListSkeleton(
          items: 4,
          cardHeight: 24,
          padding: EdgeInsets.zero,
        ),
        onRetry: () => ref.invalidate(transactionsProvider(componentId)),
        builder: (transactions) => transactions.isEmpty
            ? Text(
                'No movements recorded yet.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              )
            : Column(
              children: [
                for (final tx in transactions.take(20))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          tx.isIncrease ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 15,
                          color: tx.isIncrease
                              ? context.appColors.success
                              : context.appColors.danger,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${tx.isIncrease ? '+' : ''}${formatQty(tx.changeQty)}',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: tx.isIncrease
                                ? context.appColors.success
                                : context.appColors.danger,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            tx.reason.label,
                            style: Theme.of(context).textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          formatRelativeTime(tx.createdAt),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
      ),
    );
  }
}

class _EditComponentSheet extends ConsumerStatefulWidget {
  const _EditComponentSheet({required this.component});

  final Component component;

  @override
  ConsumerState<_EditComponentSheet> createState() => _EditComponentSheetState();
}

class _EditComponentSheetState extends ConsumerState<_EditComponentSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _mpn =
      TextEditingController(text: widget.component.mpn);
  late final TextEditingController _name =
      TextEditingController(text: widget.component.name);
  late final TextEditingController _manufacturer =
      TextEditingController(text: widget.component.manufacturer ?? '');
  late final TextEditingController _footprint =
      TextEditingController(text: widget.component.footprint ?? '');
  late final TextEditingController _dimensions =
      TextEditingController(text: widget.component.dimensions ?? '');
  late final TextEditingController _unit =
      TextEditingController(text: widget.component.unit);
  late final TextEditingController _threshold = TextEditingController(
    text: formatQty(widget.component.lowStockThreshold),
  );

  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _mpn,
      _name,
      _manufacturer,
      _footprint,
      _dimensions,
      _unit,
      _threshold,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    final ok = await runGuarded(
      context,
      () => ref.read(inventoryRepositoryProvider).updateComponent(
        id: widget.component.id,
        mpn: _mpn.text,
        name: _name.text,
        manufacturer: _manufacturer.text,
        footprint: _footprint.text,
        dimensions: _dimensions.text,
        imageUrl: widget.component.imageUrl,
        unit: _unit.text,
        lowStockThreshold: num.parse(_threshold.text.trim()),
      ),
    );

    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit component', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              TextFormField(
                controller: _mpn,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'MPN',
                  prefixIcon: Icon(Icons.qr_code_2),
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _manufacturer,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Manufacturer',
                  prefixIcon: Icon(Icons.factory_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _footprint,
                decoration: const InputDecoration(labelText: 'Footprint'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _dimensions,
                decoration: const InputDecoration(labelText: 'Dimensions'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _unit,
                      decoration: const InputDecoration(labelText: 'Unit'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _threshold,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Low stock at'),
                      validator: (v) {
                        final parsed = num.tryParse((v ?? '').trim());
                        if (parsed == null) return 'Enter a number';
                        if (parsed < 0) return 'Cannot be negative';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: const Text('Save changes'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
