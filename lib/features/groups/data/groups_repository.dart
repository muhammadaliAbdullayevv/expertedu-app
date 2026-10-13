import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final groupsRepositoryProvider = Provider<GroupsRepository>((ref) {
  return GroupsRepository(ref.watch(apiClientProvider));
});

class Group {
  const Group({
    required this.id,
    required this.name,
    this.teacherName,
    required this.feeAmount,
    required this.dueDay,
    required this.isActive,
    this.note,
  });

  final int id;
  final String name;
  final String? teacherName;
  final int feeAmount;
  final int dueDay;
  final bool isActive;
  final String? note;

  factory Group.fromJson(Map<String, dynamic> json) => Group(
    id: json['id'] as int,
    name: json['name'] as String,
    teacherName: json['teacher_name'] as String?,
    feeAmount: json['fee_amount'] as int,
    dueDay: json['due_day'] as int,
    isActive: json['is_active'] as bool,
    note: json['note'] as String?,
  );
}

class RosterEntry {
  const RosterEntry({
    required this.enrollmentId,
    required this.studentId,
    required this.studentFullName,
    required this.studentPhone,
    required this.joinedAt,
    required this.status,
    required this.balance,
  });

  final int enrollmentId;
  final int studentId;
  final String studentFullName;
  final String studentPhone;
  final DateTime joinedAt;
  final String status;

  /// Total charges minus total payments for this enrollment -- positive
  /// means the student still owes money.
  final int balance;

  factory RosterEntry.fromJson(Map<String, dynamic> json) => RosterEntry(
    enrollmentId: json['enrollment_id'] as int,
    studentId: json['student_id'] as int,
    studentFullName: json['student_full_name'] as String,
    studentPhone: json['student_phone'] as String,
    joinedAt: DateTime.parse(json['joined_at'] as String),
    status: json['status'] as String,
    balance: json['balance'] as int,
  );
}

class GroupsRepository {
  GroupsRepository(this._api);

  final ApiClient _api;

  Future<List<Group>> list({bool includeInactive = false}) async {
    final json =
        await _api.get('/groups', query: {'include_inactive': includeInactive.toString()}) as List<dynamic>;
    return json.map((e) => Group.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Group> create({
    required String name,
    String? teacherName,
    required int feeAmount,
    required int dueDay,
    String? note,
  }) async {
    final json =
        await _api.post(
              '/groups',
              body: <String, dynamic>{
                'name': name,
                'teacher_name': teacherName,
                'fee_amount': feeAmount,
                'due_day': dueDay,
                'note': note,
              },
            )
            as Map<String, dynamic>;
    return Group.fromJson(json);
  }

  Future<List<RosterEntry>> roster(int groupId) async {
    final json = await _api.get('/groups/$groupId/roster') as List<dynamic>;
    return json.map((e) => RosterEntry.fromJson(e as Map<String, dynamic>)).toList();
  }
}
