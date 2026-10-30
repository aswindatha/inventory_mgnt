import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
import 'features/auth/onboarding_screen.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/components/add_component_screen.dart';
import 'features/components/component_detail_screen.dart';
import 'features/home/home_shell.dart';
import 'features/inventories/inventory_detail_screen.dart';
import 'features/projects/add_project_component_screen.dart';
import 'features/projects/project_detail_screen.dart';
import 'features/purchasing/vendor_webview_screen.dart';
import 'providers/providers.dart';

class InventoryApp extends ConsumerWidget {
  const InventoryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    return MaterialApp.router(
      title: 'Electronics Inventory',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
      // Cap the app column on wide windows (desktop web) so lists and forms
      // stay a readable width; on phones this is a no-op.
      builder: (context, child) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.maxContentWidth),
          child: child,
        ),
      ),
    );
  }
}

final _routerProvider = Provider<GoRouter>((ref) {
  // go_router only re-evaluates `redirect` when something tells it to. Without
  // this, signing in updates the session but the app never navigates away from
  // the sign-in screen.
  final refresh = ValueNotifier<int>(0);
  ref.listen(currentUserProvider, (previous, next) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    // Redirect is synchronous, so it reads the cache-backed session state
    // rather than awaiting the network.
    redirect: (context, state) {
      final location = state.matchedLocation;
      final user = ref.read(currentUserProvider).value;
      final isAuthRoute = location == '/sign-in' || location == '/onboarding';

      // Still resolving the session (and no cached answer yet): stay put rather
      // than flashing the sign-in screen at a returning user.
      if (user == null && ref.read(currentUserProvider).isLoading) return null;

      if (user == null) {
        return location == '/sign-in' ? null : '/sign-in';
      }
      if (!user.hasCompany) {
        return location == '/onboarding' ? null : '/onboarding';
      }
      // Fully onboarded: keep them out of the auth funnel.
      if (isAuthRoute) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/sign-in',
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const HomeShell(),
      ),
      GoRoute(
        path: '/inventory/:id',
        builder: (context, state) => InventoryDetailScreen(
          inventoryId: state.pathParameters['id']!,
        ),
        routes: [
          GoRoute(
            path: 'add-component',
            builder: (context, state) => AddComponentScreen(
              inventoryId: state.pathParameters['id']!,
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/component/:id',
        builder: (context, state) => ComponentDetailScreen(
          componentId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/project/:id',
        builder: (context, state) => ProjectDetailScreen(
          projectId: state.pathParameters['id']!,
        ),
        routes: [
          GoRoute(
            path: 'add-component',
            builder: (context, state) => AddProjectComponentScreen(
              projectId: state.pathParameters['id']!,
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/vendor-webview',
        builder: (context, state) {
          final args = state.extra;
          if (args is! VendorWebViewArgs) {
            return const Scaffold(
              body: Center(child: Text('Nothing to open.')),
            );
          }
          return VendorWebViewScreen(args: args);
        },
      ),
    ],
  );
});
