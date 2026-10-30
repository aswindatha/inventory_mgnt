import '../../core/json.dart';
import 'enums.dart';

class Company {
  const Company({
    required this.id,
    required this.name,
    required this.inviteCode,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String inviteCode;
  final DateTime createdAt;

  factory Company.fromMap(Map<String, dynamic> map) => Company(
    id: parseString(map['id']),
    name: parseString(map['name']),
    inviteCode: parseString(map['invite_code']),
    createdAt: parseTimestamp(map['created_at']),
  );

  Company copyWith({String? name, String? inviteCode}) => Company(
    id: id,
    name: name ?? this.name,
    inviteCode: inviteCode ?? this.inviteCode,
    createdAt: createdAt,
  );
}

/// A member of a company. `companyId` is null between sign-up and onboarding
/// (creating a company or joining one by invite code).
class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    this.companyId,
    this.displayName,
    this.role = UserRole.member,
    required this.createdAt,
  });

  final String id;
  final String? companyId;
  final String email;
  final String? displayName;
  final UserRole role;
  final DateTime createdAt;

  bool get hasCompany => companyId != null;

  String get label => displayName?.isNotEmpty == true ? displayName! : email;

  factory AppUser.fromMap(Map<String, dynamic> map) => AppUser(
    id: parseString(map['id']),
    companyId: parseStringOrNull(map['company_id']),
    email: parseString(map['email']),
    displayName: parseStringOrNull(map['display_name']),
    role: UserRole.fromWire(parseStringOrNull(map['role'])),
    createdAt: parseTimestamp(map['created_at']),
  );
}
