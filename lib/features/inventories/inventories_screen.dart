import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/inventory.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';

class InventoriesScreen extends ConsumerWidget {
  const InventoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaries = ref.watch(inventorySummariesProvider);

    return Scaffold(
      body: AsyncView<List<InventorySummary>>(
        value: summaries,
        loading: const ListSkeleton(),
        onRetry: () => ref.invalidate(inventorySummariesProvider),
        isEmpty: (data) => data.isEmpty,
        emptyBuilder: () => EmptyState(
          icon: Icons.inventory_2_outlined,
          title: 'No inventories yet',
          message: 'An inventory is a physical site — "Office", "Home Lab", '
              '"Workshop". Create one to start tracking stock.',
          action: FilledButton.icon(
            onPressed: () => _showAddInventory(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('Add inventory'),
          ),
        ),
        builder: (data) => RefreshIndicator(
          onRefresh: () => ref.read(syncServiceProvider).sync(),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: data.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _InventoryCard(summary: data[i]),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _showAddInventory(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add inventory'),
      ),
    );
  }
}

class _InventoryCard extends StatelessWidget {
  const _InventoryCard({required this.summary});

  final InventorySummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inventory = summary.inventory;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/inventory/${inventory.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      inventory.name,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (summary.hasLowStock)
                    StatusChip(
                      label: 'Low stock',
                      color: context.appColors.warning,
                    ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right),
                ],
              ),
              if (inventory.locationNote != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.place_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        inventory.locationNote!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  _Stat(
                    label: 'Components',
                    value: '${summary.componentCount}',
                  ),
                  _Stat(
                    label: 'Total units',
                    value: formatQty(summary.totalUnits),
                  ),
                  _Stat(
                    label: 'Low stock',
                    value: '${summary.lowStockCount}',
                    highlight: summary.hasLowStock,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.highlight = false});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              color: highlight ? context.appColors.warning : null,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showAddInventory(BuildContext context, WidgetRef ref) async {
  final user = ref.read(currentUserProvider).value;
  if (user?.companyId == null) return;

  final result = await showAppSheet<({String name, String? note})>(
    context,
    child: const _InventoryFormSheet(),
  );
  if (result == null || !context.mounted) return;

  await runGuarded(
    context,
    () => ref.read(inventoryRepositoryProvider).createInventory(
      companyId: user!.companyId!,
      userId: user.id,
      name: result.name,
      locationNote: result.note,
    ),
    successMessage: 'Inventory created.',
  );
}

/// Shared add/edit form for an inventory.
class _InventoryFormSheet extends StatefulWidget {
  const _InventoryFormSheet({this.existing});

  final Inventory? existing;

  @override
  State<_InventoryFormSheet> createState() => _InventoryFormSheetState();
}

class _InventoryFormSheetState extends State<_InventoryFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _note =
      TextEditingController(text: widget.existing?.locationNote ?? '');

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
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
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null ? 'New inventory' : 'Edit inventory',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Office, Home Lab, Workshop…',
                prefixIcon: Icon(Icons.inventory_2_outlined),
              ),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Location note (optional)',
                hintText: 'Shelf B2, second floor…',
                prefixIcon: Icon(Icons.place_outlined),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                if (!(_formKey.currentState?.validate() ?? false)) return;
                Navigator.of(context).pop((
                  name: _name.text.trim(),
                  note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                ));
              },
              child: Text(widget.existing == null ? 'Create' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the edit sheet for an existing inventory. Exported for the detail
/// screen's app bar.
Future<void> showEditInventorySheet(
  BuildContext context,
  WidgetRef ref,
  Inventory inventory,
) async {
  final result = await showAppSheet<({String name, String? note})>(
    context,
    child: _InventoryFormSheet(existing: inventory),
  );
  if (result == null || !context.mounted) return;

  await runGuarded(
    context,
    () => ref.read(inventoryRepositoryProvider).updateInventory(
      id: inventory.id,
      name: result.name,
      locationNote: result.note,
    ),
    successMessage: 'Inventory updated.',
  );
}
