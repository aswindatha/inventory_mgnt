import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../data/models/inventory.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';

/// Picks a component for a project from any inventory the company owns.
class AddProjectComponentScreen extends ConsumerStatefulWidget {
  const AddProjectComponentScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<AddProjectComponentScreen> createState() =>
      _AddProjectComponentScreenState();
}

class _AddProjectComponentScreenState
    extends ConsumerState<AddProjectComponentScreen> {
  final _search = TextEditingController();
  String _term = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final components = ref.watch(allComponentsProvider);
    final inventories = ref.watch(inventorySummariesProvider).value ?? const [];
    final inventoryNames = {
      for (final s in inventories) s.inventory.id: s.inventory.name,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Add component to project')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _term = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search across every inventory',
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
              emptyBuilder: () => const EmptyState(
                icon: Icons.memory_outlined,
                title: 'No components anywhere yet',
                message: 'Add components to an inventory first, then attach them '
                    'to this project.',
              ),
              builder: (data) {
                final filtered = data.where((c) {
                  if (_term.trim().isEmpty) return true;
                  final term = _term.toLowerCase();
                  return c.name.toLowerCase().contains(term) ||
                      c.mpn.toLowerCase().contains(term) ||
                      (c.manufacturer?.toLowerCase().contains(term) ?? false);
                }).toList();

                if (filtered.isEmpty) {
                  return EmptyState(
                    icon: Icons.search_off,
                    title: 'Nothing matches "$_term"',
                    message: 'Try a different part number or clear the search.',
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final component = filtered[i];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.memory_outlined),
                        title: Text(component.name),
                        subtitle: Text(
                          '${component.mpn} · '
                          '${inventoryNames[component.inventoryId] ?? 'Unknown inventory'}',
                        ),
                        trailing: StockBadge(
                          quantity: component.quantity,
                          unit: component.unit,
                          isLow: component.isLowStock,
                        ),
                        onTap: () => _addToProject(component),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addToProject(Component component) async {
    final result = await showAppSheet<({num quantity, String? description})>(
      context,
      child: _AddLineSheet(component: component),
    );
    if (result == null || !mounted) return;

    final added = await runGuarded(
      context,
      () => ref.read(projectRepositoryProvider).addComponentToProject(
        projectId: widget.projectId,
        componentId: component.id,
        inventoryId: component.inventoryId,
        quantityRequired: result.quantity,
        description: result.description,
      ),
      successMessage: '${component.mpn} added to the project.',
    );

    if (added && mounted) context.pop();
  }
}

class _AddLineSheet extends StatefulWidget {
  const _AddLineSheet({required this.component});

  final Component component;

  @override
  State<_AddLineSheet> createState() => _AddLineSheetState();
}

class _AddLineSheetState extends State<_AddLineSheet> {
  final _formKey = GlobalKey<FormState>();
  final _quantity = TextEditingController(text: '1');
  final _description = TextEditingController();

  @override
  void dispose() {
    _quantity.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final component = widget.component;

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
              Text(component.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '${component.mpn} · '
                '${formatQty(component.quantity)} ${component.unit} on hand',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantity,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Quantity required',
                  suffixText: component.unit,
                ),
                validator: (v) {
                  final parsed = num.tryParse((v ?? '').trim());
                  if (parsed == null) return 'Enter a number';
                  if (parsed <= 0) return 'Must be greater than zero';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Why / where it is used',
                  hintText: 'Left wheel encoder mount',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  if (!(_formKey.currentState?.validate() ?? false)) return;
                  Navigator.of(context).pop((
                    quantity: num.parse(_quantity.text.trim()),
                    description: _description.text.trim().isEmpty
                        ? null
                        : _description.text.trim(),
                  ));
                },
                child: const Text('Add to project'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
