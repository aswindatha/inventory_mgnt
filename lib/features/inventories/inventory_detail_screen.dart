import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../data/models/inventory.dart';
import '../../providers/providers.dart';
import '../common/local_file_image.dart';
import '../common/widgets.dart';
import '../purchasing/cart_actions.dart';
import 'inventories_screen.dart';

class InventoryDetailScreen extends ConsumerStatefulWidget {
  const InventoryDetailScreen({super.key, required this.inventoryId});

  final String inventoryId;

  @override
  ConsumerState<InventoryDetailScreen> createState() => _InventoryDetailScreenState();
}

class _InventoryDetailScreenState extends ConsumerState<InventoryDetailScreen> {
  final _search = TextEditingController();
  String _term = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(inventoryProvider(widget.inventoryId)).value;
    final components = ref.watch(
      componentsProvider((inventoryId: widget.inventoryId, search: _term)),
    );
    final permissions = ref.watch(permissionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(inventory?.name ?? 'Inventory'),
        actions: [
          if (inventory != null) ...[
            PopupMenuButton<String>(
              onSelected: (value) async {
                switch (value) {
                  case 'edit':
                    await showEditInventorySheet(context, ref, inventory);
                  case 'bulk-cart':
                    await addAllToVendorCart(
                      context,
                      ref,
                      components: components.value ?? const [],
                      scopeLabel: inventory.name,
                    );
                  case 'delete':
                    if (!permissions.canDeleteInventory) return;
                    final ok = await confirm(
                      context,
                      title: 'Delete "${inventory.name}"?',
                      message: 'Every component in this inventory is deleted '
                          'too, and any project line using them is removed. '
                          'This cannot be undone.',
                    );
                    if (!ok || !context.mounted) return;
                    final deleted = await runGuarded(
                      context,
                      () => ref
                          .read(inventoryRepositoryProvider)
                          .deleteInventory(inventory.id),
                      successMessage: 'Inventory deleted.',
                    );
                    if (deleted && context.mounted) {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/');
                      }
                    }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit details')),
                const PopupMenuItem(
                  value: 'bulk-cart',
                  child: Text('Add all to vendor cart'),
                ),
                if (permissions.canDeleteInventory)
                  destructiveMenuItem('delete', 'Delete inventory'),
              ],
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _term = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search MPN, name, manufacturer, footprint',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _term.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _term = '');
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: AsyncView<List<Component>>(
              value: components,
              loading: const ListSkeleton(),
              isEmpty: (data) => data.isEmpty,
              emptyBuilder: () => EmptyState(
                icon: _term.isEmpty ? Icons.memory_outlined : Icons.search_off,
                title: _term.isEmpty ? 'No components yet' : 'Nothing matches "$_term"',
                message: _term.isEmpty
                    ? 'Add a component by its manufacturer part number and the '
                          'app can look up its specs.'
                    : 'Try a different part number or clear the search.',
                action: _term.isEmpty
                    ? FilledButton.icon(
                        onPressed: () => context.push(
                          '/inventory/${widget.inventoryId}/add-component',
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('Add component'),
                      )
                    : null,
              ),
              builder: (data) => RefreshIndicator(
                onRefresh: () => ref.read(syncServiceProvider).sync(),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  itemCount: data.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _ComponentTile(component: data[i]),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => context.push('/inventory/${widget.inventoryId}/add-component'),
        icon: const Icon(Icons.add),
        label: const Text('Add component'),
      ),
    );
  }
}

class _ComponentTile extends ConsumerWidget {
  const _ComponentTile({required this.component});

  final Component component;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/component/${component.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _Thumbnail(component: component),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      component.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        component.mpn,
                        if (component.manufacturer != null) component.manufacturer!,
                        if (component.footprint != null) component.footprint!,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  StockBadge(
                    quantity: component.quantity,
                    unit: component.unit,
                    isLow: component.isLowStock,
                  ),
                  const SizedBox(height: 4),
                  if (component.lowStockThreshold > 0)
                    Text(
                      'min ${formatQty(component.lowStockThreshold)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// Local file when we have one, otherwise the network copy, otherwise an icon.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.component});

  final Component component;

  @override
  Widget build(BuildContext context) {
    const size = 46.0;
    final localPath = component.localImagePath;

    Widget fallback() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        Icons.memory,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

    if (localPath != null && localPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: localFileImage(
          localPath,
          width: size,
          height: size,
          fallback: fallback,
        ),
      );
    }

    final url = component.imageUrl;
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          imageUrl: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, _) => fallback(),
          errorWidget: (_, _, _) => fallback(),
        ),
      );
    }

    return fallback();
  }
}
