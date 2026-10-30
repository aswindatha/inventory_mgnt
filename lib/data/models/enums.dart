/// Wire-format enums shared by the domain models, the drift cache and the
/// Postgres enum types created in `supabase/migrations/0001_schema.sql`.
///
/// Each enum exposes [wire] (the exact string Postgres stores) and a
/// `fromWire` parser. Keeping the mapping in one place means a rename in Dart
/// can never silently drift out of sync with the database.
library;

enum UserRole {
  owner,
  admin,
  member;

  String get wire => name;

  static UserRole fromWire(String? value) => switch (value) {
    'owner' => UserRole.owner,
    'admin' => UserRole.admin,
    _ => UserRole.member,
  };

  String get label => switch (this) {
    UserRole.owner => 'Owner',
    UserRole.admin => 'Admin',
    UserRole.member => 'Member',
  };
}

enum ProjectStatus {
  planning,
  active,
  completed,
  archived;

  String get wire => name;

  static ProjectStatus fromWire(String? value) => switch (value) {
    'active' => ProjectStatus.active,
    'completed' => ProjectStatus.completed,
    'archived' => ProjectStatus.archived,
    _ => ProjectStatus.planning,
  };

  String get label => switch (this) {
    ProjectStatus.planning => 'Planning',
    ProjectStatus.active => 'Active',
    ProjectStatus.completed => 'Completed',
    ProjectStatus.archived => 'Archived',
  };
}

enum ProjectComponentStatus {
  planned,
  allocated,
  purchased,
  used;

  String get wire => name;

  static ProjectComponentStatus fromWire(String? value) => switch (value) {
    'allocated' => ProjectComponentStatus.allocated,
    'purchased' => ProjectComponentStatus.purchased,
    'used' => ProjectComponentStatus.used,
    _ => ProjectComponentStatus.planned,
  };

  String get label => switch (this) {
    ProjectComponentStatus.planned => 'Planned',
    ProjectComponentStatus.allocated => 'Allocated',
    ProjectComponentStatus.purchased => 'Purchased',
    ProjectComponentStatus.used => 'Used',
  };
}

enum TransactionReason {
  manualAdjust,
  projectAllocation,
  purchaseReceived,
  projectDeduction;

  /// Postgres spells these with underscores.
  String get wire => switch (this) {
    TransactionReason.manualAdjust => 'manual_adjust',
    TransactionReason.projectAllocation => 'project_allocation',
    TransactionReason.purchaseReceived => 'purchase_received',
    TransactionReason.projectDeduction => 'project_deduction',
  };

  static TransactionReason fromWire(String? value) => switch (value) {
    'project_allocation' => TransactionReason.projectAllocation,
    'purchase_received' => TransactionReason.purchaseReceived,
    'project_deduction' => TransactionReason.projectDeduction,
    _ => TransactionReason.manualAdjust,
  };

  String get label => switch (this) {
    TransactionReason.manualAdjust => 'Manual adjustment',
    TransactionReason.projectAllocation => 'Allocated to project',
    TransactionReason.purchaseReceived => 'Purchase received',
    TransactionReason.projectDeduction => 'Deducted for project',
  };
}

enum Vendor {
  robu,
  robocraze,
  other;

  String get wire => name;

  static Vendor fromWire(String? value) => switch (value) {
    'robu' => Vendor.robu,
    'robocraze' => Vendor.robocraze,
    _ => Vendor.other,
  };

  String get label => switch (this) {
    Vendor.robu => 'Robu.in',
    Vendor.robocraze => 'Robocraze',
    Vendor.other => 'Other',
  };

  /// Host used by the scraper and the cart-automation WebView fallback.
  String get host => switch (this) {
    Vendor.robu => 'robu.in',
    Vendor.robocraze => 'robocraze.com',
    Vendor.other => '',
  };
}

enum CartItemStatus {
  pending,
  addedToCart,
  failed;

  String get wire => switch (this) {
    CartItemStatus.pending => 'pending',
    CartItemStatus.addedToCart => 'added_to_cart',
    CartItemStatus.failed => 'failed',
  };

  static CartItemStatus fromWire(String? value) => switch (value) {
    'added_to_cart' => CartItemStatus.addedToCart,
    'failed' => CartItemStatus.failed,
    _ => CartItemStatus.pending,
  };

  String get label => switch (this) {
    CartItemStatus.pending => 'Pending',
    CartItemStatus.addedToCart => 'Added to cart',
    CartItemStatus.failed => 'Failed',
  };
}

/// Local-cache-only bookkeeping. Never sent to the server: the server is the
/// source of truth and has no meaningful notion of a "pending" row.
enum SyncStatus {
  synced,
  pendingCreate,
  pendingUpdate,
  pendingDelete;

  int get wire => index;

  static SyncStatus fromWire(int? value) =>
      value != null && value >= 0 && value < SyncStatus.values.length
      ? SyncStatus.values[value]
      : SyncStatus.synced;

  bool get isPending => this != SyncStatus.synced;
}
