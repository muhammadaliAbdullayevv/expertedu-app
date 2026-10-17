import '../../timetable/data/timetable_models.dart';
import 'students_repository.dart';

DateTime _dt(Object? v) => DateTime.parse(v as String).toLocal();
DateTime? _dtOrNull(Object? v) => v == null ? null : _dt(v);

/// A group a student is in now, as the table shows it.
class StudentGroupRef {
  const StudentGroupRef({
    required this.groupId,
    required this.name,
    this.subjectId,
    this.subjectName,
    this.teacherId,
    this.teacherName,
    this.schedule = const [],
  });

  final int groupId;
  final String name;
  final int? subjectId;
  final String? subjectName;
  final int? teacherId;
  final String? teacherName;
  final List<ScheduleSlot> schedule;

  factory StudentGroupRef.fromJson(Map<String, dynamic> json) =>
      StudentGroupRef(
        groupId: json['group_id'] as int,
        name: json['name'] as String,
        subjectId: json['subject_id'] as int?,
        subjectName: json['subject_name'] as String?,
        teacherId: json['teacher_id'] as int?,
        teacherName: json['teacher_name'] as String?,
        schedule: [
          for (final s in json['schedule'] as List<dynamic>? ?? const [])
            ScheduleSlot.fromJson(s as Map<String, dynamic>),
        ],
      );
}

/// One row of the O'quvchilar table. The tab flags come from the server --
/// one definition, so the tab numbers and the people in them agree.
class StudentRow {
  const StudentRow({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.balance,
    required this.createdAt,
    this.groups = const [],
    this.attendanceRecent = const [],
    this.attendanceRate,
    this.isNew = false,
    this.isDebtor = false,
    this.isAtRisk = false,
    this.isActive = false,
  });

  final int id;
  final String fullName;
  final String phone;

  /// > 0: owes this much; < 0: has paid ahead.
  final int balance;
  final DateTime createdAt;
  final List<StudentGroupRef> groups;

  /// 'present' | 'late' | 'absent' | 'excused', oldest first, at most ten.
  final List<String> attendanceRecent;
  final double? attendanceRate;
  final bool isNew;
  final bool isDebtor;
  final bool isAtRisk;
  final bool isActive;

  factory StudentRow.fromJson(Map<String, dynamic> json) => StudentRow(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    balance: json['balance'] as int,
    createdAt: _dt(json['created_at']),
    groups: [
      for (final g in json['groups'] as List<dynamic>? ?? const [])
        StudentGroupRef.fromJson(g as Map<String, dynamic>),
    ],
    attendanceRecent: (json['attendance_recent'] as List<dynamic>? ?? const [])
        .cast<String>(),
    attendanceRate: (json['attendance_rate'] as num?)?.toDouble(),
    isNew: json['is_new'] as bool? ?? false,
    isDebtor: json['is_debtor'] as bool? ?? false,
    isAtRisk: json['is_at_risk'] as bool? ?? false,
    isActive: json['is_active'] as bool? ?? false,
  );
}

class ProfileAttendance {
  const ProfileAttendance({
    this.present = 0,
    this.late = 0,
    this.absent = 0,
    this.excused = 0,
    this.total = 0,
    this.rate,
    this.recent = const [],
  });

  final int present;
  final int late;
  final int absent;
  final int excused;
  final int total;

  /// Came (present or late) out of the lessons they were expected at.
  final double? rate;
  final List<String> recent;

  factory ProfileAttendance.fromJson(Map<String, dynamic> json) =>
      ProfileAttendance(
        present: json['present'] as int? ?? 0,
        late: json['late'] as int? ?? 0,
        absent: json['absent'] as int? ?? 0,
        excused: json['excused'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        rate: (json['rate'] as num?)?.toDouble(),
        recent: (json['recent'] as List<dynamic>? ?? const []).cast<String>(),
      );
}

class ProfileGroup {
  const ProfileGroup({
    required this.enrollmentId,
    required this.groupId,
    required this.groupName,
    this.subjectName,
    this.teacherName,
    required this.feeAmount,
    required this.joinedAt,
    required this.status,
    required this.balance,
    this.nextDueDate,
    this.debtSince,
    this.schedule = const [],
    required this.attendance,
  });

  final int enrollmentId;
  final int groupId;
  final String groupName;
  final String? subjectName;
  final String? teacherName;
  final int feeAmount;
  final DateTime joinedAt;
  final String status;

  /// > 0: owes this much on this group.
  final int balance;
  final DateTime? nextDueDate;

  /// The oldest charge on this group that is still unpaid.
  final DateTime? debtSince;
  final List<ScheduleSlot> schedule;
  final ProfileAttendance attendance;

  bool get isActive => status == 'active';

  factory ProfileGroup.fromJson(Map<String, dynamic> json) => ProfileGroup(
    enrollmentId: json['enrollment_id'] as int,
    groupId: json['group_id'] as int,
    groupName: json['group_name'] as String,
    subjectName: json['subject_name'] as String?,
    teacherName: json['teacher_name'] as String?,
    feeAmount: json['fee_amount'] as int,
    joinedAt: DateTime.parse(json['joined_at'] as String),
    status: json['status'] as String,
    balance: json['balance'] as int,
    nextDueDate: json['next_due_date'] == null
        ? null
        : DateTime.parse(json['next_due_date'] as String),
    debtSince: json['debt_since'] == null
        ? null
        : DateTime.parse(json['debt_since'] as String),
    schedule: [
      for (final s in json['schedule'] as List<dynamic>? ?? const [])
        ScheduleSlot.fromJson(s as Map<String, dynamic>),
    ],
    attendance: ProfileAttendance.fromJson(
      json['attendance'] as Map<String, dynamic>,
    ),
  );
}

class ProfilePayment {
  const ProfilePayment({
    required this.id,
    this.enrollmentId,
    this.groupId,
    this.groupName,
    required this.amount,
    this.method,
    required this.receivedAt,
    this.receivedByName,
    this.receiptNo,
    this.note,
    required this.status,
    this.cancelReason,
  });

  final int id;
  final int? enrollmentId;
  final int? groupId;
  final String? groupName;
  final int amount;
  final String? method;
  final DateTime receivedAt;
  final String? receivedByName;
  final String? receiptNo;
  final String? note;

  /// 'valid' | 'cancelled' -- a cancelled payment stays on record.
  final String status;
  final String? cancelReason;

  bool get isCancelled => status == 'cancelled';

  factory ProfilePayment.fromJson(Map<String, dynamic> json) => ProfilePayment(
    id: json['id'] as int,
    enrollmentId: json['enrollment_id'] as int?,
    groupId: json['group_id'] as int?,
    groupName: json['group_name'] as String?,
    amount: json['amount'] as int,
    method: json['method'] as String?,
    receivedAt: _dt(json['received_at']),
    receivedByName: json['received_by_name'] as String?,
    receiptNo: json['receipt_no'] as String?,
    note: json['note'] as String?,
    status: json['status'] as String,
    cancelReason: json['cancel_reason'] as String?,
  );
}

class ProfileMark {
  const ProfileMark({
    required this.at,
    this.groupId,
    required this.groupName,
    required this.status,
  });

  final DateTime at;
  final int? groupId;
  final String groupName;
  final String status;

  factory ProfileMark.fromJson(Map<String, dynamic> json) => ProfileMark(
    at: _dt(json['at']),
    groupId: json['group_id'] as int?,
    groupName: json['group_name'] as String,
    status: json['status'] as String,
  );
}

class ActivityItem {
  const ActivityItem({
    required this.at,
    required this.kind,
    required this.title,
    this.detail,
    this.amount,
    this.groupId,
  });

  final DateTime at;

  /// 'joined' | 'charge' | 'payment' | 'payment_cancelled' | 'absent' | 'late'.
  final String kind;
  final String title;
  final String? detail;
  final int? amount;

  /// The group it was about.
  final int? groupId;

  factory ActivityItem.fromJson(Map<String, dynamic> json) => ActivityItem(
    at: _dt(json['at']),
    kind: json['kind'] as String,
    title: json['title'] as String,
    detail: json['detail'] as String?,
    amount: json['amount'] as int?,
    groupId: json['group_id'] as int?,
  );
}

/// Everything the profile panel shows, from one request.
class StudentProfileData {
  const StudentProfileData({
    required this.student,
    required this.isNew,
    required this.balance,
    required this.paidTotal,
    required this.groups,
    required this.attendance,
    required this.payments,
    this.debtSince,
    this.overdueDays = 0,
    this.activity = const [],
    this.marks = const [],
    this.scope,
  });

  final Student student;
  final bool isNew;

  /// Set when this is a view of one group only (see [scopedTo]).
  final ProfileGroup? scope;

  /// > 0: owes this much across every group.
  final int balance;
  final int paidTotal;
  final List<ProfileGroup> groups;
  final ProfileAttendance attendance;
  final List<ProfilePayment> payments;
  final DateTime? debtSince;
  final int overdueDays;
  final List<ActivityItem> activity;
  final List<ProfileMark> marks;

  List<ProfileGroup> get activeGroups =>
      groups.where((g) => g.isActive).toList();

  /// The same student seen from one group's page: only that group, its debt
  /// and how long it has been due, its attendance, its payments, its lessons
  /// and what happened in it -- nothing about their other groups.
  StudentProfileData scopedTo(int groupId) {
    final mine = groups.where((g) => g.groupId == groupId).toList();
    final myPayments = payments.where((p) => p.groupId == groupId).toList();
    final owed = mine.fold<int>(0, (sum, g) => sum + g.balance);
    DateTime? since;
    for (final g in mine) {
      final d = g.debtSince;
      if (d != null && (since == null || d.isBefore(since))) since = d;
    }
    final today = DateTime.now();
    final overdue = since == null
        ? 0
        : DateTime(today.year, today.month, today.day)
              .difference(DateTime(since.year, since.month, since.day))
              .inDays
              .clamp(0, 100000);
    return StudentProfileData(
      student: student,
      isNew: isNew,
      balance: owed,
      paidTotal: myPayments
          .where((p) => !p.isCancelled)
          .fold<int>(0, (sum, p) => sum + p.amount),
      groups: mine,
      attendance: mine.isEmpty
          ? const ProfileAttendance()
          : mine.first.attendance,
      payments: myPayments,
      debtSince: owed > 0 ? since : null,
      overdueDays: owed > 0 ? overdue : 0,
      activity: activity.where((a) => a.groupId == groupId).toList(),
      marks: marks.where((m) => m.groupId == groupId).toList(),
      scope: mine.isEmpty ? null : mine.first,
    );
  }

  factory StudentProfileData.fromJson(Map<String, dynamic> json) =>
      StudentProfileData(
        student: Student.fromJson(json['student'] as Map<String, dynamic>),
        isNew: json['is_new'] as bool? ?? false,
        balance: json['balance'] as int,
        paidTotal: json['paid_total'] as int,
        groups: [
          for (final g in json['groups'] as List<dynamic>)
            ProfileGroup.fromJson(g as Map<String, dynamic>),
        ],
        attendance: ProfileAttendance.fromJson(
          json['attendance'] as Map<String, dynamic>,
        ),
        payments: [
          for (final p in json['payments'] as List<dynamic>)
            ProfilePayment.fromJson(p as Map<String, dynamic>),
        ],
        debtSince: _dtOrNull(json['debt_since']),
        overdueDays: json['overdue_days'] as int? ?? 0,
        activity: [
          for (final a in json['activity'] as List<dynamic>? ?? const [])
            ActivityItem.fromJson(a as Map<String, dynamic>),
        ],
        marks: [
          for (final m in json['marks'] as List<dynamic>? ?? const [])
            ProfileMark.fromJson(m as Map<String, dynamic>),
        ],
      );
}

/// What "Boshqa guruhga qo'shish" made.
class AddedToGroup {
  const AddedToGroup({
    required this.enrollmentId,
    required this.groupName,
    required this.firstCharge,
    required this.firstPayment,
  });

  final int enrollmentId;
  final String groupName;
  final int firstCharge;
  final int firstPayment;

  factory AddedToGroup.fromJson(Map<String, dynamic> json) => AddedToGroup(
    enrollmentId: json['enrollment_id'] as int,
    groupName: json['group_name'] as String,
    firstCharge: json['first_charge'] as int,
    firstPayment: json['first_payment'] as int,
  );
}
