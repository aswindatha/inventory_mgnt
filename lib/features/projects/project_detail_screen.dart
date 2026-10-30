import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/enums.dart';
import '../../data/models/project.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';
import '../purchasing/cart_actions.dart';
import 'projects_screen.dart';

class ProjectDetailScreen extends ConsumerWidget {
  const ProjectDetailScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref.watch(projectProvider(projectId));
    final lines = ref.watch(projectLinesProvider(projectId));
    final permissions = ref.watch(permissionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(project.value?.name ?? 'Project'),
        actions: [
          if (project.value != null)
            PopupMenuButton<String>(
              onSelected: (value) async {
                final current = project.value!;
                switch (value) {
                  case 'edit':
                    await _editProject(context, ref, current);
                  case 'delete':
                    final ok = await confirm(
                      context,
                      title: 'Delete "${current.name}"?',
                      message: 'The project and its component list are removed. '
                          'Stock already deducted is not restored.',
                    );
                    if (!ok || !context.mounted) return;
                    final done = await runGuarded(
                      context,
                      () => ref.read(projectRepositoryProvider).deleteProject(current.id),
                      successMessage: 'Project deleted.',
                    );
                    if (done && context.mounted) {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/');
                      }
                    }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit project')),
                if (permissions.canDeleteProject)
                  destructiveMenuItem('delete', 'Delete project'),
              ],
            ),
        ],
      ),
      body: AsyncView<Project?>(
        value: project,
        onRetry: () => ref.invalidate(projectProvider(projectId)),
        isEmpty: (data) => data == null,
        emptyBuilder: () => const EmptyState(
          icon: Icons.search_off,
          title: 'Project not found',
          message: 'It may have been deleted on another device.',
        ),
        builder: (data) => Column(
          children: [
            Expanded(
              child: AsyncView<List<ProjectLine>>(
                value: lines,
                loading: const ListSkeleton(),
                isEmpty: (l) => l.isEmpty,
                emptyBuilder: () => EmptyState(
                  icon: Icons.add_circle_outline,
                  title: 'No components yet',
                  message: 'Add the parts this project needs, from any of your '
                      'inventories.',
                  action: FilledButton.icon(
                    onPressed: () => context.push('/project/$projectId/add-component'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add component'),
                  ),
                ),
                builder: (list) => RefreshIndicator(
                  onRefresh: () => ref.read(syncServiceProvider).sync(),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      _ProjectHeader(project: data!),
                      const SizedBox(height: 16),
                      _ProjectSummary(lines: list),
                      const SizedBox(height: 16),
                      Text(
                        'Components',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      for (final line in list) ...[
                        _ProjectLineCard(line: line, projectId: projectId),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            _BottomActions(projectId: projectId),
          ],
        ),
      ),
    );
  }

  Future<void> _editProject(BuildContext context, WidgetRef ref, Project project) async {
    final result = await showAppSheet<
        ({String name, String? description, ProjectStatus status})>(
      context,
      child: ProjectFormSheet(existing: project),
    );
    if (result == null || !context.mounted) return;

    await runGuarded(
      context,
      () => ref.read(projectRepositoryProvider).updateProject(
        id: project.id,
        name: result.name,
        description: result.description,
        status: result.status,
      ),
      successMessage: 'Project updated.',
    );
  }
}

class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(project.name, style: theme.textTheme.titleMedium),
                ),
                StatusChip(
                  label: project.status.label,
                  color: projectStatusColor(context, project.status),
                ),
              ],
            ),
            if (project.description != null) ...[
              const SizedBox(height: 8),
              Text(project.description!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProjectSummary extends StatelessWidget {
  const _ProjectSummary({required this.lines});

  final List<ProjectLine> lines;

  @override
  Widget build(BuildContext context) {
    final short = lines.where((l) => l.isShort).toList();
    final totalMissing = short.fold<num>(0, (sum, l) => sum + l.missing);

    return SectionCard(
      title: 'Readiness',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  short.isEmpty
                      ? 'All ${lines.length} line'
                            '${lines.length == 1 ? '' : 's'} can be fulfilled from stock.'
                      : '${short.length} of ${lines.length} line'
                            '${lines.length == 1 ? '' : 's'} short by '
                            '${formatQty(totalMissing)} unit'
                            '${totalMissing == 1 ? '' : 's'}.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (short.isNotEmpty)
                StatusChip(label: 'Short', color: context.appColors.warning),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProjectLineCard extends ConsumerWidget {
  const _ProjectLineCard({required this.line, required this.projectId});

  final ProjectLine line;
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pc = line.line;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/component/${line.component.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      line.component.name,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  StatusChip(
                    label: pc.status.label,
                    color: switch (pc.status) {
                      ProjectComponentStatus.planned => context.appColors.neutral,
                      ProjectComponentStatus.allocated => context.appColors.warning,
                      ProjectComponentStatus.purchased => context.appColors.success,
                      ProjectComponentStatus.used => context.appColors.primary,
                    },
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<String>(
                    onSelected: (value) async {
                      switch (value) {
                        case 'edit':
                          await _editLine(context, ref);
                        case 'remove':
                          final ok = await confirm(
                            context,
                            title: 'Remove ${line.component.mpn}?',
                            message: 'The component stays in its inventory.',
                            confirmLabel: 'Remove',
                          );
                          if (!ok || !context.mounted) return;
                          await runGuarded(
                            context,
                            () => ref
                                .read(projectRepositoryProvider)
                                .removeProjectComponent(pc.id),
                            successMessage: 'Removed from project.',
                          );
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit line')),
                      destructiveMenuItem('remove', 'Remove'),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${line.component.mpn} · from ${line.inventoryName}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (pc.description != null) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.notes,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        pc.description!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  _Metric(
                    label: 'Required',
                    value: formatQty(pc.quantityRequired),
                    color: null,
                  ),
                  _Metric(
                    label: 'Allocated',
                    value: formatQty(pc.quantityAllocated),
                    color: null,
                  ),
                  _Metric(
                    label: 'On hand',
                    value: formatQty(line.onHand),
                    color: line.isShort
                        ? context.appColors.warning
                        : context.appColors.success,
                  ),
                  if (line.isShort)
                    _Metric(
                      label: 'Short',
                      value: formatQty(line.missing),
                      color: context.appColors.danger,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editLine(BuildContext context, WidgetRef ref) async {
    final result = await showAppSheet<
        ({num quantity, String? description, ProjectComponentStatus status})>(
      context,
      child: _LineEditSheet(line: line),
    );
    if (result == null || !context.mounted) return;

    await runGuarded(
      context,
      () => ref.read(projectRepositoryProvider).updateProjectComponent(
        id: line.line.id,
        quantityRequired: result.quantity,
        description: result.description,
        status: result.status,
      ),
      successMessage: 'Line updated.',
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

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
              fontWeight: FontWeight.w600,
              color: color,
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

class _BottomActions extends ConsumerWidget {
  const _BottomActions({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(projectLinesProvider(projectId)).value ?? const [];
    final outstanding =
        lines.where((l) => l.line.status == ProjectComponentStatus.planned ||
                l.line.status == ProjectComponentStatus.allocated)
            .toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.push('/project/$projectId/add-component'),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: outstanding.isEmpty
                    ? null
                    : () => _proceed(context, ref, lines),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Proceed with project'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Deducts stock for every outstanding line.
  ///
  /// Runs all-or-nothing first: if anything is short, nothing is deducted and
  /// the user chooses between buying the shortfall, committing a partial run, or
  /// backing out (spec §3.6).
  Future<void> _proceed(
    BuildContext context,
    WidgetRef ref,
    List<ProjectLine> lines,
  ) async {
    final result = await runGuardedValue(
      context,
      () => ref.read(projectRepositoryProvider).proceedWithProject(projectId),
    );
    if (result == null || !context.mounted) return;

    if (!result.hasShortfalls) {
      await _showSuccess(context, result);
      return;
    }

    final choice = await _showShortfallDialog(context, result);
    if (!context.mounted) return;

    switch (choice) {
      case _ShortfallChoice.buy:
        final shortIds = result.shortfalls.map((s) => s.componentId).toSet();
        final components = lines
            .where((l) => shortIds.contains(l.component.id))
            .map((l) => l.component)
            .toList();
        await addAllToVendorCart(
          context,
          ref,
          components: components,
          scopeLabel: 'Shortfall for this project',
        );

      case _ShortfallChoice.partial:
        final partial = await runGuardedValue(
          context,
          () => ref
              .read(projectRepositoryProvider)
              .proceedWithProject(projectId, allowPartial: true),
        );
        if (partial == null || !context.mounted) return;
        await _showSuccess(context, partial);

      case _ShortfallChoice.cancel:
      case null:
        break;
    }
  }

  Future<void> _showSuccess(BuildContext context, ProceedResult result) async {
    if (result.deducted.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to deduct.')),
      );
      return;
    }

    final total = result.deducted.fold<num>(0, (sum, d) => sum + d.quantity);

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Project stock deducted'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${formatQty(total)} units across '
                  '${result.deducted.length} line'
                  '${result.deducted.length == 1 ? '' : 's'}.'),
              const SizedBox(height: 12),
              for (final line in result.deducted)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    '${line.mpn} — ${formatQty(line.quantity)} '
                    '(${formatQty(line.remaining)} left)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<_ShortfallChoice?> _showShortfallDialog(
    BuildContext context,
    ProceedResult result,
  ) {
    return showDialog<_ShortfallChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Not enough stock'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Nothing has been deducted yet. These lines are short:',
              ),
              const SizedBox(height: 12),
              for (final s in result.shortfalls)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.mpn,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        'need ${formatQty(s.required)}, '
                        'have ${formatQty(s.available)}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: context.appColors.warning,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_ShortfallChoice.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_ShortfallChoice.partial),
            child: const Text('Use what is available'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_ShortfallChoice.buy),
            icon: const Icon(Icons.shopping_cart_outlined),
            label: const Text('Buy the shortfall'),
          ),
        ],
      ),
    );
  }
}

enum _ShortfallChoice { buy, partial, cancel }

class _LineEditSheet extends StatefulWidget {
  const _LineEditSheet({required this.line});

  final ProjectLine line;

  @override
  State<_LineEditSheet> createState() => _LineEditSheetState();
}

class _LineEditSheetState extends State<_LineEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _quantity =
      TextEditingController(text: formatQty(widget.line.line.quantityRequired));
  late final TextEditingController _description =
      TextEditingController(text: widget.line.line.description ?? '');
  late ProjectComponentStatus _status = widget.line.line.status;

  @override
  void dispose() {
    _quantity.dispose();
    _description.dispose();
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.line.component.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.line.component.mpn} · ${widget.line.inventoryName}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantity,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Quantity required',
                  suffixText: widget.line.component.unit,
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
                  hintText: 'Motor driver on the rear chassis',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Status', style: Theme.of(context).textTheme.labelLarge),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final status in ProjectComponentStatus.values)
                    ChoiceChip(
                      label: Text(status.label),
                      selected: _status == status,
                      onSelected: (_) => setState(() => _status = status),
                    ),
                ],
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
                    status: _status,
                  ));
                },
                child: const Text('Save line'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
