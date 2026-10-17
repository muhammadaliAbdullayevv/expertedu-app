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
  });

  final int id;
  final String phone;
  final String fullName;

  /// 'owner' (one) or 'admin'.
  final String role;
  final bool isActive;
  final DateTime? lastLoginAt;

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
  }) async {
    final json = await _api.post(
      '/staff',
      body: <String, dynamic>{
        'phone': phone,
        'full_name': fullName,
        'password': password,
      },
    );
    return StaffMember.fromJson(json as Map<String, dynamic>);
  }

  Future<StaffMember> update(int id, {String? fullName, bool? isActive}) async {
    final json = await _api.patch(
      '/staff/$id',
      body: <String, dynamic>{'full_name': ?fullName, 'is_active': ?isActive},
    );
    return StaffMember.fromJson(json as Map<String, dynamic>);
  }

  Future<void> resetPassword(int id, String password) =>
      _api.post('/staff/$id/password', body: {'password': password});
}
