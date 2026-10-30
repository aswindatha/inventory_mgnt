import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/failures.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/repositories/inventory_repository.dart';
import '../../providers/providers.dart';
import '../../services/metadata/component_metadata.dart';
import '../common/widgets.dart';

/// Adds a component to an inventory, with an MPN lookup that pre-fills the
/// specifications (spec §4).
class AddComponentScreen extends ConsumerStatefulWidget {
  const AddComponentScreen({super.key, required this.inventoryId});

  final String inventoryId;

  @override
  ConsumerState<AddComponentScreen> createState() => _AddComponentScreenState();
}

class _AddComponentScreenState extends ConsumerState<AddComponentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _mpn = TextEditingController();
  final _name = TextEditingController();
  final _manufacturer = TextEditingController();
  final _footprint = TextEditingController();
  final _dimensions = TextEditingController();
  final _quantity = TextEditingController(text: '0');
  final _unit = TextEditingController(text: 'pcs');
  final _threshold = TextEditingController(
    text: formatQty(InventoryRepository.defaultLowStockThreshold),
  );

  ComponentMetadata? _metadata;
  bool _lookingUp = false;
  bool _saving = false;
  String? _lookupMessage;

  @override
  void dispose() {
    for (final c in [
      _mpn,
      _name,
      _manufacturer,
      _footprint,
      _dimensions,
      _quantity,
      _unit,
      _threshold,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _lookup() async {
    final mpn = _mpn.text.trim();
    if (mpn.isEmpty) {
      setState(() => _lookupMessage = 'Enter a part number to look up.');
      return;
    }

    setState(() {
      _lookingUp = true;
      _lookupMessage = null;
    });

    try {
      final result = await ref.read(metadataServiceProvider).lookup(mpn);
      if (!mounted) return;

      if (result == null) {
        setState(() => _lookupMessage = 'No catalogue match for "$mpn". '
            'Fill the details in by hand.');
        return;
      }

      setState(() {
        _metadata = result;
        if (result.name != null) _name.text = result.name!;
        if (result.manufacturer != null) _manufacturer.text = result.manufacturer!;
        if (result.footprint != null) _footprint.text = result.footprint!;
        if (result.dimensions != null) _dimensions.text = result.dimensions!;
        _lookupMessage = null;
      });
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);
    try {
      final repo = ref.read(inventoryRepositoryProvider);

      final component = await repo.addComponent(
        inventoryId: widget.inventoryId,
        mpn: _mpn.text,
        name: _name.text,
        manufacturer: _manufacturer.text,
        footprint: _footprint.text,
        dimensions: _dimensions.text,
        imageUrl: _metadata?.imageUrl,
        quantity: num.tryParse(_quantity.text.trim()) ?? 0,
        unit: _unit.text,
        lowStockThreshold: num.tryParse(_threshold.text.trim()),
      );

      // Pull the image down once, cache it locally and mirror it to storage so
      // every teammate resolves the same picture (spec §4).
      final imageUrl = _metadata?.imageUrl;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        final user = ref.read(currentUserProvider).value;
        final companyId = user?.companyId;
        if (companyId != null) {
          try {
            final stored = await ref.read(imageStoreProvider).store(
              imageUrl: imageUrl,
              companyId: companyId,
              componentId: component.id,
            );
            if (stored.localPath != null) {
              await repo.setLocalImagePath(component.id, stored.localPath);
            }
            if (stored.publicUrl != null) {
              await repo.updateComponent(
                id: component.id,
                mpn: component.mpn,
                name: component.name,
                manufacturer: component.manufacturer,
                footprint: component.footprint,
                dimensions: component.dimensions,
                imageUrl: stored.publicUrl,
                unit: component.unit,
                lowStockThreshold: component.lowStockThreshold,
              );
            }
          } on AppFailure {
            // The component is saved; a failed image fetch is not worth
            // blocking on. It can be re-fetched from the detail screen.
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${component.mpn}.')),
      );
      context.pushReplacement('/component/${component.id}');
    } on AppFailure catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.userMessage), backgroundColor: context.appColors.danger),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: context.appColors.danger),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(inventoryProvider(widget.inventoryId)).value;
    final metadata = _metadata;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add component'),
        bottom: inventory == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      inventory.name,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title: 'Part number',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _mpn,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Manufacturer part number',
                      hintText: 'e.g. LM358DR',
                      prefixIcon: Icon(Icons.qr_code_2),
                    ),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Part number is required' : null,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _lookingUp ? null : _lookup,
                    icon: _lookingUp
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.travel_explore),
                    label: const Text('Look up specifications'),
                  ),
                  if (_lookupMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _lookupMessage!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (metadata != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        StatusChip(
                          label: metadata.isMock
                              ? 'Offline catalogue (approximate)'
                              : metadata.source,
                          color: metadata.isMock
                              ? context.appColors.warning
                              : context.appColors.success,
                        ),
                        if (metadata.imageUrl != null) ...[
                          const SizedBox(width: 8),
                          StatusChip(
                            label: 'Image found',
                            color: context.appColors.success,
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            SectionCard(
              title: 'Specifications',
              child: Column(
                children: [
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      prefixIcon: Icon(Icons.label_outline),
                    ),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Name is required' : null,
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
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _footprint,
                          decoration: const InputDecoration(labelText: 'Footprint'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _dimensions,
                          decoration: const InputDecoration(labelText: 'Dimensions'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            SectionCard(
              title: 'Stock',
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _quantity,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Opening quantity'),
                          validator: _numberValidator(allowZero: true),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _unit,
                          decoration: const InputDecoration(labelText: 'Unit'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _threshold,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Low stock threshold',
                      helperText: 'Flag the item once stock drops to this level',
                    ),
                    validator: _numberValidator(allowZero: true),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('Add component'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rejects blanks, non-numbers and negatives; [allowZero] permits an opening
/// quantity of zero, which is legitimate for a part you are about to order.
FormFieldValidator<String> _numberValidator({bool allowZero = false}) {
  return (String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return 'Required';
    final parsed = num.tryParse(text);
    if (parsed == null) return 'Enter a number';
    if (parsed < 0) return 'Cannot be negative';
    if (!allowZero && parsed == 0) return 'Must be greater than zero';
    return null;
  };
}
