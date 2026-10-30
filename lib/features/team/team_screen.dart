import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/permissions.dart';
import '../../core/theme.dart';
import '../../data/models/company.dart';
import '../../data/models/enums.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';

/// Team and company settings: invite code, roles, member management (spec §7.8).
class TeamScreen extends ConsumerWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final company = ref.watch(companyProvider).value;
    final members = ref.watch(membersProvider);
    final me = ref.watch(currentUserProvider).value;
    final permissions = ref.watch(permissionsProvider);

    return RefreshIndicator(
      onRefresh: () => ref.read(syncServiceProvider).sync(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _CompanyCard(company: company, permissions: permissions),
          const SizedBox(height: 16),

        SectionCard(
          title: 'Members'
              '${members.hasValue ? ' (${members.value!.length})' : ''}',
          child: AsyncView<List<AppUser>>(
            value: members,
            loading: const ListSkeleton(
              items: 3,
              cardHeight: 44,
              padding: EdgeInsets.zero,
            ),
            onRetry: () => ref.invalidate(membersProvider),
            isEmpty: (m) => m.isEmpty,
            emptyBuilder: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No members loaded yet. Pull to refresh.'),
            ),
            builder: (list) => Column(
              children: [
                for (final member in list) ...[
                  _MemberRow(
                    member: member,
                    isMe: member.id == me?.id,
                    permissions: permissions,
                  ),
                  if (member != list.last) const Divider(height: 16),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        SectionCard(
          title: 'Account',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (me != null)
                DetailRow(
                  label: 'Signed in as',
                  value: me.email,
                  icon: Icons.person_outline,
                ),
              if (me != null)
                DetailRow(
                  label: 'Your role',
                  value: me.role.label,
                  icon: Icons.badge_outlined,
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final ok = await confirm(
                    context,
                    title: 'Leave this company?',
                    message: 'You will lose access to its inventories and '
                        'projects until you are invited back.',
                    confirmLabel: 'Leave',
                  );
                  if (!ok || !context.mounted) return;
                  await runGuarded(
                    context,
                    () => ref.read(authRepositoryProvider).leaveCompany(),
                    successMessage: 'You have left the company.',
                  );
                },
                icon: const Icon(Icons.exit_to_app),
                label: const Text('Leave company'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final ok = await confirm(
                    context,
                    title: 'Sign out?',
                    message: 'Cached data for this company is removed from this '
                        'device.',
                    confirmLabel: 'Sign out',
                  );
                  if (!ok || !context.mounted) return;
                  await runGuarded(
                    context,
                    () => ref.read(authRepositoryProvider).signOut(),
                  );
                },
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ],
          ),
        ),
        ],
      ),
    );
  }
}

class _CompanyCard extends ConsumerWidget {
  const _CompanyCard({required this.company, required this.permissions});

  final Company? company;
  final Permissions permissions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (company == null) {
      return const SectionCard(
        title: 'Company',
        child: Text('No company loaded yet.'),
      );
    }

    final current = company!;

    return SectionCard(
      title: 'Invite your team',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Share this code. Anyone who signs up can join ${current.name} with it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    current.inviteCode,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 4,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: current.inviteCode));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invite code copied.')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy code',
                ),
              ],
            ),
          ),
          if (permissions.canManageTeam) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await confirm(
                  context,
                  title: 'Rotate the invite code?',
                  message: 'The current code stops working immediately. Anyone '
                      'you already invited keeps their access.',
                  confirmLabel: 'Rotate',
                );
                if (!ok || !context.mounted) return;
                await runGuarded(
                  context,
                  () => ref.read(authRepositoryProvider).regenerateInviteCode(),
                  successMessage: 'Invite code rotated.',
                );
              },
              icon: const Icon(Icons.autorenew),
              label: const Text('Rotate code'),
            ),
          ],
        ],
      ),
    );
  }
}

class _MemberRow extends ConsumerWidget {
  const _MemberRow({
    required this.member,
    required this.isMe,
    required this.permissions,
  });

  final AppUser member;
  final bool isMe;
  final Permissions permissions;

  Color _roleColor(BuildContext context) => switch (member.role) {
    UserRole.owner => context.appColors.success,
    UserRole.admin => context.appColors.warning,
    UserRole.member => context.appColors.neutral,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final roleColor = _roleColor(context);
    final canManage = permissions.canManageTeam && !isMe;

    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: roleColor.withValues(alpha: 0.15),
          child: Text(
            member.label.characters.first.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(color: roleColor),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      member.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 6),
                    Text(
                      '(you)',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                member.email,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        StatusChip(label: member.role.label, color: roleColor),
        if (canManage)
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'remove') {
                final ok = await confirm(
                  context,
                  title: 'Remove ${member.label}?',
                  message: 'They lose access to this company immediately. Their '
                      'account is not deleted.',
                  confirmLabel: 'Remove',
                );
                if (!ok || !context.mounted) return;
                await runGuarded(
                  context,
                  () => ref.read(authRepositoryProvider).removeMember(member.id),
                  successMessage: '${member.label} removed.',
                );
                return;
              }

              final role = UserRole.fromWire(value);
              await runGuarded(
                context,
                () => ref.read(authRepositoryProvider).updateMemberRole(member.id, role),
                successMessage: '${member.label} is now ${role.label.toLowerCase()}.',
              );
            },
            itemBuilder: (context) => [
              if (permissions.canPromoteToOwner)
                const PopupMenuItem(value: 'owner', child: Text('Make owner')),
              const PopupMenuItem(value: 'admin', child: Text('Make admin')),
              const PopupMenuItem(value: 'member', child: Text('Make member')),
              const PopupMenuDivider(),
              destructiveMenuItem(
                'remove',
                'Remove from company',
                icon: Icons.person_remove_outlined,
              ),
            ],
          ),
      ],
    );
  }
}
