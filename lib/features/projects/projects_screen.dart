import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/enums.dart';
import '../../data/models/project.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';

class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);

    return Scaffold(
      body: AsyncView<List<Project>>(
        value: projects,
        loading: const ListSkeleton(),
        onRetry: () => ref.invalidate(projectsProvider),
        isEmpty: (data) => data.isEmpty,
        emptyBuilder: () => EmptyState(
          icon: Icons.science_outlined,
          title: 'No projects yet',
          message: 'A project draws components from any of your inventories and '
              'tracks what each part is used for.',
          action: FilledButton.icon(
            onPressed: () => _showCreateSheet(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('Add project'),
          ),
        ),
        builder: (data) => RefreshIndicator(
          onRefresh: () => ref.read(syncServiceProvider).sync(),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: data.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _ProjectCard(project: data[i]),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => _showCreateSheet(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add project'),
      ),
    );
  }
}

/// Terminal states read differently from in-flight ones: `active` is the
/// healthy green, `completed`/`used` are primary, waiting states neutral.
Color projectStatusColor(BuildContext context, ProjectStatus status) =>
    switch (status) {
      ProjectStatus.planning => context.appColors.neutral,
      ProjectStatus.active => context.appColors.success,
      ProjectStatus.completed => context.appColors.primary,
      ProjectStatus.archived => context.appColors.neutral,
    };

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/project/${project.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      project.name,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusChip(
                    label: project.status.label,
                    color: projectStatusColor(context, project.status),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right),
                ],
              ),
              if (project.description != null) ...[
                const SizedBox(height: 6),
                Text(
                  project.description!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 10),
              Text(
                'Created ${formatRelativeTime(project.createdAt)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showCreateSheet(BuildContext context, WidgetRef ref) async {
  final user = ref.read(currentUserProvider).value;
  if (user?.companyId == null) return;

  final result = await showAppSheet<
      ({String name, String? description, ProjectStatus status})>(
    context,
    child: const ProjectFormSheet(),
  );
  if (result == null || !context.mounted) return;

  await runGuarded(
    context,
    () => ref.read(projectRepositoryProvider).createProject(
      companyId: user!.companyId!,
      userId: user.id,
      name: result.name,
      description: result.description,
      status: result.status,
    ),
    successMessage: 'Project created.',
  );
}

/// Add/edit form for a project. Exported so the detail screen reuses it.
class ProjectFormSheet extends StatefulWidget {
  const ProjectFormSheet({super.key, this.existing});

  final Project? existing;

  @override
  State<ProjectFormSheet> createState() => _ProjectFormSheetState();
}

class _ProjectFormSheetState extends State<ProjectFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.existing?.description ?? '');
  late ProjectStatus _status = widget.existing?.status ?? ProjectStatus.planning;

  @override
  void dispose() {
    _name.dispose();
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
                widget.existing == null ? 'New project' : 'Edit project',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Line follower, Weather station…',
                  prefixIcon: Icon(Icons.science_outlined),
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
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
                  for (final status in ProjectStatus.values)
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
                    name: _name.text.trim(),
                    description: _description.text.trim().isEmpty
                        ? null
                        : _description.text.trim(),
                    status: _status,
                  ));
                },
                child: Text(widget.existing == null ? 'Create project' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
