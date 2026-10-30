import '../data/models/enums.dart';

/// What the signed-in user is allowed to do.
///
/// This mirrors the RLS policies in `supabase/migrations/0002_rls.sql`. It
/// exists so the UI can hide affordances the user cannot use — it is *not* the
/// security boundary. The database is. If these two ever disagree, the database
/// wins and the user gets an error, which is the correct failure mode.
class Permissions {
  const Permissions(this.role);

  final UserRole? role;

  bool get isAuthenticated => role != null;

  bool get canManageTeam => role == UserRole.owner || role == UserRole.admin;

  bool get canDeleteInventory => canManageTeam;

  bool get canDeleteProject => canManageTeam;

  bool get canEditCompanySettings => canManageTeam;

  /// Only an owner may mint another owner (enforced by `update_member_role`).
  bool get canPromoteToOwner => role == UserRole.owner;

  /// Members may create and edit components and projects (spec §2).
  bool get canEditComponents => isAuthenticated;

  bool get canEditProjects => isAuthenticated;

  static const Permissions anonymous = Permissions(null);
}
