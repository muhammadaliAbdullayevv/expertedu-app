import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final staffRepositoryProvider = Provider<StaffRepository>((ref) {
  return StaffRepository(ref.watch(apiClientProvider));
});

class StaffMember {
  const StaffMember({
    required this.id,
    required this.phone,
    required this.fullName,
    required this.role,
    required this.isActive,
    this.lastLoginAt,
    this.branchId,
    this.branchName,
  });

  final int id;
  final String phone;
  final String fullName;

  /// 'owner' (one) or 'admin'.
  final String role;
  final bool isActive;
  final DateTime? lastLoginAt;

  /// The branch an admin works in (the owner has none).
  final int? branchId;
  final String? branchName;

  bool get isOwner => role == 'owner';

  factory StaffMember.fromJson(Map<String, dynamic> json) => StaffMember(
    id: json['id'] as int,
    phone: json['phone'] as String,
    fullName: json['full_name'] as String,
    role: json['role'] as String,
    isActive: json['is_active'] as bool,
    lastLoginAt: json['last_login_at'] == null
        ? null
        : DateTime.parse(json['last_login_at'] as String),
    branchId: json['branch_id'] as int?,
    branchName: json['branch_name'] as String?,
  );
}

/// Staff accounts -- owner only (server/app/routes/staff.py).
class StaffRepository {
  StaffRepository(this._api);

  final ApiClient _api;

  Future<List<StaffMember>> list() async {
    final json = await _api.get('/staff') as List<dynamic>;
    return json
        .map((e) => StaffMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<StaffMember> create({
    required String phone,
    required String fullName,
    required String password,
    int? branchId,
  }) async {
    final json = await _api.post(
      '/staff',
      body: <String, dynamic>{
        'phone': phone,
        'full_name': fullName,
        'password': password,
        'branch_id': branchId,
      },
    );
    return StaffMember.fromJson(json as Map<String, dynamic>);
  }

  Future<StaffMember> update(
    int id, {
    String? fullName,
    String? phone,
    bool? isActive,
    int? branchId,
  }) async {
    final json = await _api.patch(
      '/staff/$id',
      body: <String, dynamic>{
        'full_name': ?fullName,
        'phone': ?phone,
        'is_active': ?isActive,
        'branch_id': ?branchId,
      },
    );
    return StaffMember.fromJson(json as Map<String, dynamic>);
  }

  Future<void> resetPassword(int id, String password) =>
      _api.post('/staff/$id/password', body: {'password': password});

  /// Signs the account out of every device.
  Future<void> signOutEverywhere(int id) => _api.post('/staff/$id/sign-out');
}
