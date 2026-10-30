import '../../core/json.dart';
import 'enums.dart';
import 'inventory.dart';

class Project {
  const Project({
    required this.id,
    required this.companyId,
    required this.name,
    this.description,
    this.status = ProjectStatus.planning,
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String companyId;
  final String name;
  final String? description;
  final ProjectStatus status;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Project.fromMap(Map<String, dynamic> map) => Project(
    id: parseString(map['id']),
    companyId: parseString(map['company_id']),
    name: parseString(map['name']),
    description: parseStringOrNull(map['description']),
    status: ProjectStatus.fromWire(parseStringOrNull(map['status'])),
    createdBy: parseStringOrNull(map['created_by']),
    createdAt: parseTimestamp(map['created_at']),
    updatedAt: parseTimestamp(map['updated_at']),
  );

  Map<String, Object?> toInsertMap(String companyId, String userId) => {
    'id': id,
    'company_id': companyId,
    'name': name,
    'description': description,
    'status': status.wire,
    'created_by': userId,
  };

  Project copyWith({String? name, String? description, ProjectStatus? status}) =>
      Project(
        id: id,
        companyId: companyId,
        name: name ?? this.name,
        description: description ?? this.description,
        status: status ?? this.status,
        createdBy: createdBy,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

/// A component allocated to a project, referencing one specific inventory's
/// stock row (spec §2 — the same part can live in "Office" and "Home Lab").
class ProjectComponent {
  const ProjectComponent({
    required this.id,
    required this.projectId,
    required this.componentId,
    required this.inventoryId,
    this.quantityRequired = 0,
    this.quantityAllocated = 0,
    this.description,
    this.status = ProjectComponentStatus.planned,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String componentId;
  final String inventoryId;
  final num quantityRequired;
  final num quantityAllocated;

  /// Free text: why this part is used and where it goes in the project.
  final String? description;

  final ProjectComponentStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  num get shortfall => (quantityRequired - quantityAllocated).clamp(0, double.infinity);

  factory ProjectComponent.fromMap(Map<String, dynamic> map) => ProjectComponent(
    id: parseString(map['id']),
    projectId: parseString(map['project_id']),
    componentId: parseString(map['component_id']),
    inventoryId: parseString(map['inventory_id']),
    quantityRequired: parseNum(map['quantity_required']),
    quantityAllocated: parseNum(map['quantity_allocated']),
    description: parseStringOrNull(map['description']),
    status: ProjectComponentStatus.fromWire(parseStringOrNull(map['status'])),
    createdAt: parseTimestamp(map['created_at']),
    updatedAt: parseTimestamp(map['updated_at']),
  );

  Map<String, Object?> toInsertMap() => {
    'id': id,
    'project_id': projectId,
    'component_id': componentId,
    'inventory_id': inventoryId,
    'quantity_required': quantityRequired,
    'quantity_allocated': quantityAllocated,
    'description': description,
    'status': status.wire,
  };

  ProjectComponent copyWith({
    num? quantityRequired,
    num? quantityAllocated,
    String? description,
    ProjectComponentStatus? status,
  }) => ProjectComponent(
    id: id,
    projectId: projectId,
    componentId: componentId,
    inventoryId: inventoryId,
    quantityRequired: quantityRequired ?? this.quantityRequired,
    quantityAllocated: quantityAllocated ?? this.quantityAllocated,
    description: description ?? this.description,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// A `project_components` row joined with its component and inventory names, so
/// the Project Detail screen renders without N+1 lookups.
class ProjectLine {
  const ProjectLine({
    required this.line,
    required this.component,
    required this.inventoryName,
  });

  final ProjectComponent line;
  final Component component;
  final String inventoryName;

  num get onHand => component.quantity;

  /// Stock available in the source inventory is short of what the line needs.
  bool get isShort => onHand < line.quantityRequired;

  num get missing => (line.quantityRequired - onHand).clamp(0, double.infinity);
}

class DeductedLine {
  const DeductedLine({
    required this.componentId,
    required this.mpn,
    required this.name,
    required this.quantity,
    required this.remaining,
  });

  final String componentId;
  final String mpn;
  final String name;
  final num quantity;
  final num remaining;

  factory DeductedLine.fromMap(Map<String, dynamic> map) => DeductedLine(
    componentId: parseString(map['component_id']),
    mpn: parseString(map['mpn']),
    name: parseString(map['name']),
    quantity: parseNum(map['quantity']),
    remaining: parseNum(map['remaining']),
  );
}

class ShortfallLine {
  const ShortfallLine({
    required this.componentId,
    required this.mpn,
    required this.name,
    required this.required,
    required this.available,
    required this.missing,
  });

  final String componentId;
  final String mpn;
  final String name;
  final num required;
  final num available;
  final num missing;

  factory ShortfallLine.fromMap(Map<String, dynamic> map) => ShortfallLine(
    componentId: parseString(map['component_id']),
    mpn: parseString(map['mpn']),
    name: parseString(map['name']),
    required: parseNum(map['required']),
    available: parseNum(map['available']),
    missing: parseNum(map['missing']),
  );
}

/// Decoded return value of `proceed_with_project()`.
///
/// [committed] is false when the server refused to deduct anything because at
/// least one line was short — in which case [shortfalls] is populated and
/// [deducted] is empty.
class ProceedResult {
  const ProceedResult({
    required this.projectId,
    required this.committed,
    this.deducted = const [],
    this.shortfalls = const [],
  });

  final String projectId;
  final bool committed;
  final List<DeductedLine> deducted;
  final List<ShortfallLine> shortfalls;

  bool get hasShortfalls => shortfalls.isNotEmpty;

  factory ProceedResult.fromMap(Map<String, dynamic> map) => ProceedResult(
    projectId: parseString(map['project_id']),
    committed: parseBool(map['committed']),
    deducted: (map['deducted'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => DeductedLine.fromMap(Map<String, dynamic>.from(e)))
        .toList(),
    shortfalls: (map['shortfalls'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => ShortfallLine.fromMap(Map<String, dynamic>.from(e)))
        .toList(),
  );
}
