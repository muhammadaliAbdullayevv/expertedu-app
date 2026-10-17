import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final teachersRepositoryProvider = Provider<TeachersRepository>((ref) {
  return TeachersRepository(ref.watch(apiClientProvider));
});

class Teacher {
  const Teacher({
    required this.id,
    required this.fullName,
    this.phone,
    this.note,
    required this.isActive,
    this.groupCount,
  });

  final int id;
  final String fullName;
  final String? phone;
  final String? note;
  final bool isActive;

  /// Active groups taught -- only populated by [TeachersRepository.list].
  final int? groupCount;

  factory Teacher.fromJson(Map<String, dynamic> json) => Teacher(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String?,
    note: json['note'] as String?,
    isActive: json['is_active'] as bool,
    groupCount: json['group_count'] as int?,
  );
}

class TeachersRepository {
  TeachersRepository(this._api);

  final ApiClient _api;

  Future<List<Teacher>> list() async {
    final json = await _api.get('/teachers') as List<dynamic>;
    return json
        .map((e) => Teacher.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Teacher> create({
    required String fullName,
    String? phone,
    String? note,
  }) async {
    final json =
        await _api.post(
              '/teachers',
              body: <String, dynamic>{
                'full_name': fullName,
                'phone': phone,
                'note': note,
              },
            )
            as Map<String, dynamic>;
    return Teacher.fromJson(json);
  }

  /// Sends every field, so an emptied phone or note is cleared rather than
  /// left as it was.
  Future<Teacher> update(
    int id, {
    required String fullName,
    String? phone,
    String? note,
  }) async {
    final json =
        await _api.patch(
              '/teachers/$id',
              body: <String, dynamic>{
                'full_name': fullName,
                'phone': phone,
                'note': note,
              },
            )
            as Map<String, dynamic>;
    return Teacher.fromJson(json);
  }
}
