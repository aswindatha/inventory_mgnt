import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';
import '../inventories/inventories_screen.dart';
import '../projects/projects_screen.dart';
import '../purchasing/purchasing_screen.dart';
import '../team/team_screen.dart';

/// Top-level shell. Inventories and Projects are separate tabs because a project
/// belongs to the company and can draw stock from any inventory (spec §3.5).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  bool _syncing = false;

  static const _tabs = [
    (Icons.inventory_2_outlined, Icons.inventory_2, 'Inventories'),
    (Icons.science_outlined, Icons.science, 'Projects'),
    (Icons.shopping_cart_outlined, Icons.shopping_cart, 'Purchasing'),
    (Icons.group_outlined, Icons.group, 'Team'),
  ];

  Future<void> _sync() async {
    setState(() => _syncing = true);
    final outcome = await ref.read(syncServiceProvider).sync();
    if (!mounted) return;
    setState(() => _syncing = false);

    final messenger = ScaffoldMessenger.of(context);
    if (!outcome.ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(outcome.error ?? 'Could not sync.')),
      );
    } else if (outcome.pushed > 0 || outcome.failed > 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Synced ${outcome.pushed} change${outcome.pushed == 1 ? '' : 's'}'
            '${outcome.failed > 0 ? ', ${outcome.failed} failed' : ''}.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingOpCountProvider).value ?? 0;
    final company = ref.watch(companyProvider).value;
    final offlineOnly = ref.watch(offlineOnlyProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Narrow (phones, phone-sized browser windows): bottom NavigationBar.
        // Wide (desktop web): a side NavigationRail, which uses the horizontal
        // space that would otherwise be dead.
        final wide = constraints.maxWidth >= AppLayout.wideNavBreakpoint;

        final content = Column(
          children: [
            if (offlineOnly)
              const InfoBanner(
                message: 'Running on the local cache. Set SUPABASE_URL and '
                    'SUPABASE_ANON_KEY to share data with your team.',
                tone: BannerTone.warning,
              ),
            if (pending > 0)
              InfoBanner(
                message: '$pending change${pending == 1 ? '' : 's'} queued for sync.',
                tone: BannerTone.info,
              ),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: const [
                  InventoriesScreen(),
                  ProjectsScreen(),
                  PurchasingScreen(),
                  TeamScreen(),
                ],
              ),
            ),
          ],
        );

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Electronics Inventory'),
                if (company != null)
                  Text(
                    company.name,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            actions: [
              SyncIndicator(pendingCount: pending),
              IconButton(
                onPressed: _syncing || offlineOnly ? null : _sync,
                icon: _syncing
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                tooltip: offlineOnly ? 'Backend not configured' : 'Sync now',
              ),
            ],
          ),
          body: wide
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final (icon, selectedIcon, label) in _tabs)
                          NavigationRailDestination(
                            icon: Icon(icon),
                            selectedIcon: Icon(selectedIcon),
                            label: Text(label),
                          ),
                      ],
                    ),
                    const VerticalDivider(thickness: 1, width: 1),
                    Expanded(child: content),
                  ],
                )
              : content,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (final (icon, selectedIcon, label) in _tabs)
                      NavigationDestination(
                        icon: Icon(icon),
                        selectedIcon: Icon(selectedIcon),
                        label: label,
                      ),
                  ],
                ),
        );
      },
    );
  }
}
