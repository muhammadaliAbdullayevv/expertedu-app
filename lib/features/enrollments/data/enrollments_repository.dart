import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final enrollmentsRepositoryProvider = Provider<EnrollmentsRepository>((ref) {
  return EnrollmentsRepository(ref.watch(apiClientProvider));
});

class StudentEnrollment {
  const StudentEnrollment({
    required this.enrollmentId,
    required this.groupId,
    required this.groupName,
    required this.joinedAt,
    required this.status,
  });

  final int enrollmentId;
  final int groupId;
  final String groupName;
  final DateTime joinedAt;
  final String status;

  factory StudentEnrollment.fromJson(Map<String, dynamic> json) =>
      StudentEnrollment(
        enrollmentId: json['enrollment_id'] as int,
        groupId: json['group_id'] as int,
        groupName: json['group_name'] as String,
        joinedAt: DateTime.parse(json['joined_at'] as String),
        status: json['status'] as String,
      );
}

class EnrollmentsRepository {
  EnrollmentsRepository(this._api);

  final ApiClient _api;

  Future<void> create({
    required int studentId,
    required int groupId,
    required DateTime joinedAt,
  }) {
    final dateStr =
        '${joinedAt.year.toString().padLeft(4, '0')}-${joinedAt.month.toString().padLeft(2, '0')}-${joinedAt.day.toString().padLeft(2, '0')}';
    return _api.post(
      '/enrollments',
      body: <String, dynamic>{
        'student_id': studentId,
        'group_id': groupId,
        'joined_at': dateStr,
      },
    );
  }

  Future<void> withdraw(int enrollmentId) {
    return _api.post('/enrollments/$enrollmentId/withdraw');
  }

  Future<List<StudentEnrollment>> listForStudent(int studentId) async {
    final json =
        await _api.get('/enrollments/by-student/$studentId') as List<dynamic>;
    return json
        .map((e) => StudentEnrollment.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
