import '../../core/json.dart';
import 'enums.dart';

class Inventory {
  const Inventory({
    required this.id,
    required this.companyId,
    required this.name,
    this.locationNote,
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String companyId;
  final String name;
  final String? locationNote;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Inventory.fromMap(Map<String, dynamic> map) => Inventory(
    id: parseString(map['id']),
    companyId: parseString(map['company_id']),
    name: parseString(map['name']),
    locationNote: parseStringOrNull(map['location_note']),
    createdBy: parseStringOrNull(map['created_by']),
    createdAt: parseTimestamp(map['created_at']),
    updatedAt: parseTimestamp(map['updated_at']),
  );

  /// `id` must be sent: it is generated client-side so queued writes and remote
  /// rows agree. Without it Postgres assigns its own uuid and every queued
  /// update/RPC/FK that references this row's local id silently misses.
  Map<String, Object?> toInsertMap(String companyId, String userId) => {
    'id': id,
    'company_id': companyId,
    'name': name,
    'location_note': locationNote,
    'created_by': userId,
  };

  Inventory copyWith({String? name, String? locationNote}) => Inventory(
    id: id,
    companyId: companyId,
    name: name ?? this.name,
    locationNote: locationNote ?? this.locationNote,
    createdBy: createdBy,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// Home-screen card data: an inventory plus its rollup stock numbers.
class InventorySummary {
  const InventorySummary({
    required this.inventory,
    this.componentCount = 0,
    this.lowStockCount = 0,
    this.totalUnits = 0,
  });

  final Inventory inventory;
  final int componentCount;
  final int lowStockCount;
  final num totalUnits;

  bool get hasLowStock => lowStockCount > 0;
}

class Component {
  const Component({
    required this.id,
    required this.inventoryId,
    required this.mpn,
    required this.name,
    this.manufacturer,
    this.footprint,
    this.dimensions,
    this.imageUrl,
    this.localImagePath,
    this.quantity = 0,
    this.unit = 'pcs',
    this.lowStockThreshold = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String inventoryId;
  final String mpn;
  final String name;
  final String? manufacturer;
  final String? footprint;
  final String? dimensions;

  /// Canonical, shareable URL in Supabase Storage (spec §4).
  final String? imageUrl;

  /// Per-device on-disk cache path. Local-only — never sent to the server.
  final String? localImagePath;

  final num quantity;
  final String unit;
  final num lowStockThreshold;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isLowStock => quantity <= lowStockThreshold;

  bool get hasImage => (localImagePath?.isNotEmpty ?? false) || (imageUrl?.isNotEmpty ?? false);

  factory Component.fromMap(Map<String, dynamic> map) => Component(
    id: parseString(map['id']),
    inventoryId: parseString(map['inventory_id']),
    mpn: parseString(map['mpn']),
    name: parseString(map['name']),
    manufacturer: parseStringOrNull(map['manufacturer']),
    footprint: parseStringOrNull(map['footprint']),
    dimensions: parseStringOrNull(map['dimensions']),
    imageUrl: parseStringOrNull(map['image_url']),
    localImagePath: parseStringOrNull(map['local_image_path']),
    quantity: parseNum(map['quantity']),
    unit: parseString(map['unit'], fallback: 'pcs'),
    lowStockThreshold: parseNum(map['low_stock_threshold']),
    createdAt: parseTimestamp(map['created_at']),
    updatedAt: parseTimestamp(map['updated_at']),
  );

  /// `quantity` is deliberately omitted: the `guard_component_quantity` trigger
  /// rejects direct UPDATEs to it. Stock moves via `adjust_component_quantity()`.
  Map<String, Object?> toWriteMap() => {
    'inventory_id': inventoryId,
    'mpn': mpn,
    'name': name,
    'manufacturer': manufacturer,
    'footprint': footprint,
    'dimensions': dimensions,
    'image_url': imageUrl,
    'unit': unit,
    'low_stock_threshold': lowStockThreshold,
  };

  /// INSERT is allowed to set an opening balance — the guard trigger only fires
  /// on UPDATE, so a component can be created with its starting stock in one
  /// round trip instead of insert-then-adjust.
  Map<String, Object?> toInsertMap(String inventoryId) => {
    'id': id,
    ...toWriteMap(),
    'inventory_id': inventoryId,
    'quantity': quantity,
  };

  Component copyWith({
    String? mpn,
    String? name,
    String? manufacturer,
    String? footprint,
    String? dimensions,
    String? imageUrl,
    String? localImagePath,
    num? quantity,
    String? unit,
    num? lowStockThreshold,
    DateTime? updatedAt,
  }) => Component(
    id: id,
    inventoryId: inventoryId,
    mpn: mpn ?? this.mpn,
    name: name ?? this.name,
    manufacturer: manufacturer ?? this.manufacturer,
    footprint: footprint ?? this.footprint,
    dimensions: dimensions ?? this.dimensions,
    imageUrl: imageUrl ?? this.imageUrl,
    localImagePath: localImagePath ?? this.localImagePath,
    quantity: quantity ?? this.quantity,
    unit: unit ?? this.unit,
    lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// One row of the append-only stock audit trail.
///
/// These are written exclusively by the `adjust_component_quantity` and
/// `proceed_with_project` routines — clients have no INSERT policy on the
/// table, so the trail cannot be forged or skipped.
class StockTransaction {
  const StockTransaction({
    required this.id,
    required this.componentId,
    this.projectId,
    this.userId,
    required this.changeQty,
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final String componentId;
  final String? projectId;
  final String? userId;
  final num changeQty;
  final TransactionReason reason;
  final DateTime createdAt;

  bool get isIncrease => changeQty > 0;

  factory StockTransaction.fromMap(Map<String, dynamic> map) => StockTransaction(
    id: parseString(map['id']),
    componentId: parseString(map['component_id']),
    projectId: parseStringOrNull(map['project_id']),
    userId: parseStringOrNull(map['user_id']),
    changeQty: parseNum(map['change_qty']),
    reason: TransactionReason.fromWire(parseStringOrNull(map['reason'])),
    createdAt: parseTimestamp(map['created_at']),
  );
}
