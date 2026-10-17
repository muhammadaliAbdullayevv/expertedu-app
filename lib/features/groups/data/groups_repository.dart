import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import 'group_profile_models.dart';
import '../../timetable/data/timetable_models.dart';

final groupsRepositoryProvider = Provider<GroupsRepository>((ref) {
  return GroupsRepository(ref.watch(apiClientProvider));
});

/// The two ways a group bills (see server/app/money/rules.py).
class BillingMode {
  const BillingMode._();

  static const fixedDay = 'fixed_day';
  static const studentAnniversary = 'student_anniversary';
}

class Group {
  const Group({
    required this.id,
    this.subjectId,
    required this.name,
    this.teacherId,
    this.teacherName,
    required this.feeAmount,
    required this.billingMode,
    this.billingDay,
    this.prorateFirstPeriod = true,
    this.capacity,
    required this.isActive,
    this.note,
    this.studentCount,
    this.subjectName,
    this.schedule = const <ScheduleSlot>[],
    this.level,
    this.startDate,
  });

  final int id;
  final int? subjectId;
  final String name;
  final int? teacherId;

  /// The linked teacher's name, joined in by the server.
  final String? teacherName;
  final int feeAmount;

  /// How the group bills: [BillingMode.fixedDay] (everyone pays on
  /// [billingDay], 1-28) or [BillingMode.studentAnniversary] (each student
  /// on their own start day -- no billing day).
  final String billingMode;
  final int? billingDay;

  /// Fixed-day groups: a student joining between billing days first pays a
  /// prorated part (the default); off, the first charge is the full price.
  final bool prorateFirstPeriod;

  bool get isAnniversary => billingMode == BillingMode.studentAnniversary;

  /// "Har oyning 14-kuni" / "Har o'quvchining boshlangan kuni".
  String get billingLabel => isAnniversary
      ? 'Har o\'quvchining boshlangan kuni'
      : 'Har oyning $billingDay-kuni';

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

  /// "Beginner", "IELTS"... and the day the group started.
  final String? level;
  final DateTime? startDate;

  factory Group.fromJson(Map<String, dynamic> json) => Group(
    id: json['id'] as int,
    subjectId: json['subject_id'] as int?,
    name: json['name'] as String,
    teacherId: json['teacher_id'] as int?,
    teacherName: json['teacher_name'] as String?,
    feeAmount: json['fee_amount'] as int,
    billingMode: json['billing_mode'] as String? ?? BillingMode.fixedDay,
    billingDay: json['billing_day'] as int?,
    prorateFirstPeriod: json['prorate_first_period'] as bool? ?? true,
    capacity: json['capacity'] as int?,
    isActive: json['is_active'] as bool,
    note: json['note'] as String?,
    studentCount: json['student_count'] as int?,
    subjectName: json['subject_name'] as String?,
    schedule: (json['schedule'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => ScheduleSlot.fromJson(e as Map<String, dynamic>))
        .toList(),
    level: json['level'] as String?,
    startDate: json['start_date'] == null
        ? null
        : DateTime.parse(json['start_date'] as String),
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
    this.isNew = false,
    this.studentPhoto,
  });

  final int enrollmentId;
  final int studentId;
  final String studentFullName;
  final String studentPhone;

  /// Stored name of the student's photo; null = none.
  final String? studentPhoto;
  final DateTime joinedAt;
  final String status;

  /// Total charges minus total payments for this enrollment -- positive
  /// means the student still owes money.
  final int balance;

  /// Joined in the last two weeks: listed first, marked "Yangi".
  final bool isNew;

  factory RosterEntry.fromJson(Map<String, dynamic> json) => RosterEntry(
    enrollmentId: json['enrollment_id'] as int,
    studentId: json['student_id'] as int,
    studentFullName: json['student_full_name'] as String,
    studentPhone: json['student_phone'] as String,
    studentPhoto: json['student_photo'] as String?,
    joinedAt: DateTime.parse(json['joined_at'] as String),
    status: json['status'] as String,
    balance: json['balance'] as int,
    isNew: json['is_new'] as bool? ?? false,
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
    required String billingMode,
    int? billingDay,
    bool prorateFirstPeriod = true,
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
                'billing_mode': billingMode,
                'billing_day': billingDay,
                'prorate_first_period': prorateFirstPeriod,
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
    required String billingMode,
    int? billingDay,
    bool prorateFirstPeriod = true,
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
                'billing_mode': billingMode,
                'billing_day': billingDay,
                'prorate_first_period': prorateFirstPeriod,
                'capacity': capacity,
                'note': note,
              },
            )
            as Map<String, dynamic>;
    return Group.fromJson(json);
  }

  /// The group's profile page in one request.
  Future<GroupProfileData> profile(int groupId) async {
    final json =
        await _api.get('/groups/$groupId/profile') as Map<String, dynamic>;
    return GroupProfileData.fromJson(json);
  }

  Future<List<RosterEntry>> roster(int groupId) async {
    final json = await _api.get('/groups/$groupId/roster') as List<dynamic>;
    return json
        .map((e) => RosterEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
