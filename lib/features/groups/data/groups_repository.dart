import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../../timetable/data/timetable_models.dart';

final groupsRepositoryProvider = Provider<GroupsRepository>((ref) {
  return GroupsRepository(ref.watch(apiClientProvider));
});

class Group {
  const Group({
    required this.id,
    this.subjectId,
    required this.name,
    this.teacherId,
    this.teacherName,
    required this.feeAmount,
    required this.dueDay,
    this.capacity,
    required this.isActive,
    this.note,
    this.studentCount,
    this.subjectName,
    this.schedule = const <ScheduleSlot>[],
  });

  final int id;
  final int? subjectId;
  final String name;
  final int? teacherId;

  /// The linked teacher's name, joined in by the server.
  final String? teacherName;
  final int feeAmount;
  final int dueDay;

  /// Seat limit; null = no limit (never shown as full).
  final int? capacity;
  final bool isActive;
  final String? note;

  /// Only populated when fetched via [GroupsRepository.listBySubject] or
  /// [GroupsRepository.list].
  final int? studentCount;

  /// Only populated by [GroupsRepository.list].
  final String? subjectName;

  /// The weekly lesson slots -- only populated by [GroupsRepository.list].
  final List<ScheduleSlot> schedule;

  factory Group.fromJson(Map<String, dynamic> json) => Group(
    id: json['id'] as int,
    subjectId: json['subject_id'] as int?,
    name: json['name'] as String,
    teacherId: json['teacher_id'] as int?,
    teacherName: json['teacher_name'] as String?,
    feeAmount: json['fee_amount'] as int,
    dueDay: json['due_day'] as int,
    capacity: json['capacity'] as int?,
    isActive: json['is_active'] as bool,
    note: json['note'] as String?,
    studentCount: json['student_count'] as int?,
    subjectName: json['subject_name'] as String?,
    schedule: (json['schedule'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => ScheduleSlot.fromJson(e as Map<String, dynamic>))
        .toList(),
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
        await _api.get(
              '/groups',
              query: {'include_inactive': includeInactive.toString()},
            )
            as List<dynamic>;
    return json.map((e) => Group.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Group>> listBySubject(int subjectId) async {
    final json = await _api.get('/subjects/$subjectId/groups') as List<dynamic>;
    return json.map((e) => Group.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Pass [teacherId] to pick an existing teacher; [teacherName] (the phone
  /// app's typed name) is matched to, or creates, a teacher server-side.
  Future<Group> create({
    required int subjectId,
    required String name,
    int? teacherId,
    String? teacherName,
    required int feeAmount,
    required int dueDay,
    int? capacity,
    String? note,
  }) async {
    final json =
        await _api.post(
              '/groups',
              body: <String, dynamic>{
                'subject_id': subjectId,
                'name': name,
                'teacher_id': teacherId,
                'teacher_name': teacherName,
                'fee_amount': feeAmount,
                'due_day': dueDay,
                'capacity': capacity,
                'note': note,
              },
            )
            as Map<String, dynamic>;
    return Group.fromJson(json);
  }

  /// Sends every editable field -- a null [teacherId] unassigns the teacher,
  /// a null [capacity] removes the seat limit.
  Future<Group> update(
    int id, {
    required int subjectId,
    required String name,
    int? teacherId,
    required int feeAmount,
    required int dueDay,
    int? capacity,
    String? note,
  }) async {
    final json =
        await _api.patch(
              '/groups/$id',
              body: <String, dynamic>{
                'subject_id': subjectId,
                'name': name,
                'teacher_id': teacherId,
                'fee_amount': feeAmount,
                'due_day': dueDay,
                'capacity': capacity,
                'note': note,
              },
            )
            as Map<String, dynamic>;
    return Group.fromJson(json);
  }

  Future<List<RosterEntry>> roster(int groupId) async {
    final json = await _api.get('/groups/$groupId/roster') as List<dynamic>;
    return json
        .map((e) => RosterEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
