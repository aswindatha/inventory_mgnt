import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/failures.dart';
import '../local/app_database.dart';
import '../models/enums.dart';
import '../models/project.dart';
import '../remote/backend.dart';
import '../remote/sync_service.dart';

/// Projects and the components allocated to them.
///
/// A project belongs to the company, not to one inventory, so its lines can
/// pull from any inventory the company owns (spec §2).
class ProjectRepository {
  ProjectRepository(this._backend, this._db, this._sync);

  final Backend _backend;
  final AppDatabase _db;
  final SyncService _sync;

  static const _uuid = Uuid();

  // ===========================================================================
  // Projects
  // ===========================================================================

  Stream<List<Project>> watchProjects() => _db.watchProjects();

  Stream<Project?> watchProject(String id) => _db.watchProject(id);

  Stream<List<ProjectLine>> watchProjectLines(String projectId) =>
      _db.watchProjectLines(projectId);

  Future<Project> createProject({
    required String companyId,
    required String userId,
    required String name,
    String? description,
    ProjectStatus status = ProjectStatus.planning,
  }) async {
    if (name.trim().isEmpty) {
      throw const ValidationFailure('Project name is required.');
    }

    final now = DateTime.now().toUtc();
    final project = Project(
      id: _uuid.v4(),
      companyId: companyId,
      name: name.trim(),
      description: description?.trim().isEmpty ?? true ? null : description!.trim(),
      status: status,
      createdBy: userId,
      createdAt: now,
      updatedAt: now,
    );

    await _db.into(_db.cachedProjects).insert(
      CachedProjectsCompanion.insert(
        id: project.id,
        companyId: project.companyId,
        name: project.name,
        description: Value(project.description),
        status: Value(project.status.wire),
        createdBy: Value(project.createdBy),
        createdAt: now,
        updatedAt: now,
        syncStatus: Value(SyncStatus.pendingCreate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'insert',
      target: 'projects',
      rowId: project.id,
      payload: project.toInsertMap(companyId, userId),
    );
    await _sync.push();

    return project;
  }

  Future<void> updateProject({
    required String id,
    required String name,
    String? description,
    required ProjectStatus status,
  }) async {
    if (name.trim().isEmpty) {
      throw const ValidationFailure('Project name is required.');
    }

    final cleanDescription = description?.trim();
    final clean = cleanDescription?.isEmpty ?? true ? null : cleanDescription;

    await (_db.update(_db.cachedProjects)..where((t) => t.id.equals(id))).write(
      CachedProjectsCompanion(
        name: Value(name.trim()),
        description: Value(clean),
        status: Value(status.wire),
        updatedAt: Value(DateTime.now().toUtc()),
        syncStatus: Value(SyncStatus.pendingUpdate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'update',
      target: 'projects',
      rowId: id,
      payload: {'name': name.trim(), 'description': clean, 'status': status.wire},
    );
    await _sync.push();
  }

  /// Owner/admin only — the RLS policy rejects it for members.
  Future<void> deleteProject(String id) async {
    await (_db.delete(_db.cachedProjects)..where((t) => t.id.equals(id))).go();
    await (_db.delete(_db.cachedProjectComponents)
          ..where((t) => t.projectId.equals(id)))
        .go();

    await _db.enqueue(kind: 'delete', target: 'projects', rowId: id);
    await _sync.push();
  }

  // ===========================================================================
  // Project components
  // ===========================================================================

  /// Adds a component from any company inventory to the project.
  Future<void> addComponentToProject({
    required String projectId,
    required String componentId,
    required String inventoryId,
    required num quantityRequired,
    String? description,
  }) async {
    if (quantityRequired <= 0) {
      throw const ValidationFailure('Quantity required must be greater than zero.');
    }

    final alreadyOnProject = await (_db.select(_db.cachedProjectComponents)
          ..where((t) => t.projectId.equals(projectId) & t.componentId.equals(componentId)))
        .getSingleOrNull();

    if (alreadyOnProject != null) {
      throw const ValidationFailure('That component is already on this project.');
    }

    final now = DateTime.now().toUtc();
    final line = ProjectComponent(
      id: _uuid.v4(),
      projectId: projectId,
      componentId: componentId,
      inventoryId: inventoryId,
      quantityRequired: quantityRequired,
      description: description?.trim().isEmpty ?? true ? null : description!.trim(),
      createdAt: now,
      updatedAt: now,
    );

    await _db.into(_db.cachedProjectComponents).insert(
      CachedProjectComponentsCompanion.insert(
        id: line.id,
        projectId: line.projectId,
        componentId: line.componentId,
        inventoryId: line.inventoryId,
        quantityRequired: Value(line.quantityRequired.toDouble()),
        description: Value(line.description),
        createdAt: now,
        updatedAt: now,
        syncStatus: Value(SyncStatus.pendingCreate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'insert',
      target: 'project_components',
      rowId: line.id,
      payload: line.toInsertMap(),
    );
    await _sync.push();
  }

  Future<void> updateProjectComponent({
    required String id,
    required num quantityRequired,
    String? description,
    ProjectComponentStatus? status,
  }) async {
    if (quantityRequired < 0) {
      throw const ValidationFailure('Quantity cannot be negative.');
    }

    final cleanDescription = description?.trim();
    final clean = cleanDescription?.isEmpty ?? true ? null : cleanDescription;

    await (_db.update(_db.cachedProjectComponents)..where((t) => t.id.equals(id)))
        .write(
      CachedProjectComponentsCompanion(
        quantityRequired: Value(quantityRequired.toDouble()),
        description: Value(clean),
        status: Value(status?.wire ?? ProjectComponentStatus.planned.wire),
        updatedAt: Value(DateTime.now().toUtc()),
        syncStatus: Value(SyncStatus.pendingUpdate.wire),
      ),
    );

    await _db.enqueue(
      kind: 'update',
      target: 'project_components',
      rowId: id,
      payload: {
        'quantity_required': quantityRequired,
        'description': clean,
        'status': status?.wire ?? ProjectComponentStatus.planned.wire,
      },
    );
    await _sync.push();
  }

  Future<void> removeProjectComponent(String id) async {
    await (_db.delete(_db.cachedProjectComponents)..where((t) => t.id.equals(id))).go();
    await _db.enqueue(kind: 'delete', target: 'project_components', rowId: id);
    await _sync.push();
  }

  // ===========================================================================
  // Proceed with project (spec §3.6)
  // ===========================================================================

  /// Deducts each line's `quantity_required` from its source inventory and
  /// records a `project_deduction` audit row per line.
  ///
  /// This is a server-side routine and is **not** queued: it is an interactive
  /// action whose whole point is to report back which lines are short, so a
  /// deferred run would give the user nothing to act on. Offline it fails with a
  /// clear message instead of silently queueing.
  ///
  /// With [allowPartial] false (the default) the server deducts nothing at all
  /// if any line is short, and returns the shortfall list.
  Future<ProceedResult> proceedWithProject(
    String projectId, {
    bool allowPartial = false,
  }) async {
    if (!_backend.isConfigured || _backend.currentUserId == null) {
      throw const NetworkFailure(
        'Proceeding with a project needs a connection so stock is deducted '
        'atomically. Reconnect and try again.',
      );
    }

    final raw = await _backend.rpc<Map<String, dynamic>>(
      'proceed_with_project',
      {'p_project_id': projectId, 'p_allow_partial': allowPartial},
    );

    final result = ProceedResult.fromMap(raw);

    // Reconcile local stock with what the server actually did.
    await _sync.pull();

    return result;
  }
}
