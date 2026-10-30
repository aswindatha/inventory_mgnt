import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/env.dart';
import '../core/permissions.dart';
import '../data/local/app_database.dart';
import '../data/models/company.dart';
import '../data/models/enums.dart';
import '../data/models/inventory.dart';
import '../data/models/project.dart';
import '../data/models/vendor.dart';
import '../data/remote/backend.dart';
import '../data/remote/sync_service.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/cart_repository.dart';
import '../data/repositories/inventory_repository.dart';
import '../data/repositories/price_repository.dart';
import '../data/repositories/project_repository.dart';
import '../services/cart/cart_automation_service.dart';
import '../services/images/image_store.dart';
import '../services/metadata/metadata_service.dart';
import '../services/scraper/scraper_registry.dart';

// =============================================================================
// Infrastructure
//
// `appDatabase` and `backend` are overridden in main() once Supabase has been
// initialised. The throwing defaults make a missing override a loud startup
// error rather than a silent null.
// =============================================================================

final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => throw StateError('appDatabaseProvider must be overridden in main()'),
);

final backendProvider = Provider<Backend>(
  (ref) => throw StateError('backendProvider must be overridden in main()'),
);

final syncServiceProvider = Provider<SyncService>(
  (ref) => SyncService(ref.watch(backendProvider), ref.watch(appDatabaseProvider)),
);

final scraperRegistryProvider = Provider<ScraperRegistry>((ref) => ScraperRegistry());

final cartAutomationProvider = Provider<CartAutomationService>(
  (ref) => CartAutomationService(),
);

final metadataServiceProvider = Provider<MetadataService>((ref) => MetadataService());

final imageStoreProvider = Provider<ImageStore>(
  (ref) => ImageStore(ref.watch(backendProvider)),
);

// =============================================================================
// Repositories
// =============================================================================

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    ref.watch(backendProvider),
    ref.watch(appDatabaseProvider),
    ref.watch(syncServiceProvider),
  ),
);

final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => InventoryRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(syncServiceProvider),
  ),
);

final projectRepositoryProvider = Provider<ProjectRepository>(
  (ref) => ProjectRepository(
    ref.watch(backendProvider),
    ref.watch(appDatabaseProvider),
    ref.watch(syncServiceProvider),
  ),
);

final priceRepositoryProvider = Provider<PriceRepository>(
  (ref) => PriceRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(syncServiceProvider),
    ref.watch(scraperRegistryProvider),
  ),
);

final cartRepositoryProvider = Provider<CartRepository>(
  (ref) => CartRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(syncServiceProvider),
    ref.watch(cartAutomationProvider),
  ),
);

// =============================================================================
// Session
// =============================================================================

final backendConfiguredProvider = Provider<bool>(
  (ref) => ref.watch(backendProvider).isConfigured,
);

final currentUserProvider = StreamProvider<AppUser?>(
  (ref) => ref.watch(authRepositoryProvider).watchCurrentUser(),
);

final companyProvider = StreamProvider<Company?>(
  (ref) => ref.watch(authRepositoryProvider).watchCompany(),
);

final membersProvider = StreamProvider<List<AppUser>>(
  (ref) => ref.watch(authRepositoryProvider).watchMembers(),
);

/// Capability flags for the signed-in user, derived from their role.
final permissionsProvider = Provider<Permissions>((ref) {
  final user = ref.watch(currentUserProvider).value;
  return Permissions(user?.role);
});

// =============================================================================
// Inventories & components
// =============================================================================

final inventorySummariesProvider = StreamProvider<List<InventorySummary>>(
  (ref) => ref.watch(inventoryRepositoryProvider).watchSummaries(),
);

final inventoryProvider = StreamProvider.family<Inventory?, String>(
  (ref, id) => ref.watch(inventoryRepositoryProvider).watchInventory(id),
);

typedef ComponentQuery = ({String inventoryId, String search});

final componentsProvider = StreamProvider.family<List<Component>, ComponentQuery>(
  (ref, query) => ref
      .watch(inventoryRepositoryProvider)
      .watchComponents(query.inventoryId, search: query.search),
);

final componentProvider = StreamProvider.family<Component?, String>(
  (ref, id) => ref.watch(inventoryRepositoryProvider).watchComponent(id),
);

final transactionsProvider = StreamProvider.family<List<StockTransaction>, String>(
  (ref, componentId) => ref.watch(inventoryRepositoryProvider).watchTransactions(componentId),
);

/// Every component across every inventory, for the "add to project" picker.
final allComponentsProvider = StreamProvider<List<Component>>(
  (ref) => ref.watch(appDatabaseProvider).watchAllComponents(),
);

// =============================================================================
// Projects
// =============================================================================

final projectsProvider = StreamProvider<List<Project>>(
  (ref) => ref.watch(projectRepositoryProvider).watchProjects(),
);

final projectProvider = StreamProvider.family<Project?, String>(
  (ref, id) => ref.watch(projectRepositoryProvider).watchProject(id),
);

final projectLinesProvider = StreamProvider.family<List<ProjectLine>, String>(
  (ref, id) => ref.watch(projectRepositoryProvider).watchProjectLines(id),
);

// =============================================================================
// Vendor pricing & cart
// =============================================================================

final vendorPricesProvider = StreamProvider.family<List<VendorPrice>, String>(
  (ref, componentId) => ref.watch(priceRepositoryProvider).watchPrices(componentId),
);

final cartItemsProvider = StreamProvider<List<CartReviewItem>>(
  (ref) => ref.watch(cartRepositoryProvider).watchCartItems(),
);

final supportedVendorsProvider = Provider<List<Vendor>>(
  (ref) => ref.watch(scraperRegistryProvider).supportedVendors,
);

// =============================================================================
// Sync status
// =============================================================================

final pendingOpCountProvider = StreamProvider<int>(
  (ref) => ref.watch(appDatabaseProvider).watchPendingOpCount(),
);

/// True when the app has no backend credentials and is running purely on its
/// local cache.
final offlineOnlyProvider = Provider<bool>((ref) => !AppConfig.isBackendConfigured);
