import '../../students/data/student_models.dart';
import '../../timetable/data/timetable_models.dart';
import 'groups_repository.dart';

DateTime _dt(Object? v) => DateTime.parse(v as String).toLocal();

class GroupTeacher {
  const GroupTeacher({required this.id, required this.fullName, this.phone});

  final int id;
  final String fullName;
  final String? phone;

  factory GroupTeacher.fromJson(Map<String, dynamic> json) => GroupTeacher(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String?,
  );
}

/// Someone who asked for the group in Qabul but is not a student yet: no
/// seat, no charge, and not counted in the group's students.
class GroupWaiting {
  const GroupWaiting({
    required this.leadId,
    required this.fullName,
    required this.phone,
    required this.createdAt,
    this.trialAt,
  });

  final int leadId;
  final String fullName;
  final String phone;
  final DateTime createdAt;
  final DateTime? trialAt;

  factory GroupWaiting.fromJson(Map<String, dynamic> json) => GroupWaiting(
    leadId: json['lead_id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    createdAt: _dt(json['created_at']),
    trialAt: json['trial_at'] == null ? null : _dt(json['trial_at']),
  );
}

/// A group's profile page: who teaches it, how full it is, who has paid, how
/// they attend, when it meets, when it bills, and how much of what was
/// expected has come in.
class GroupProfileData {
  const GroupProfileData({
    required this.group,
    this.subjectName,
    this.teacher,
    this.schedule = const [],
    required this.studentCount,
    this.capacity,
    this.freeSeats,
    required this.paidCount,
    required this.unpaidCount,
    required this.attendance,
    required this.expected,
    required this.collected,
    required this.debtTotal,
    this.nextBillingDate,
    this.nextLessons = const [],
    this.waiting = const [],
  });

  final Group group;
  final String? subjectName;
  final GroupTeacher? teacher;
  final List<ScheduleSlot> schedule;

  /// Active students; past the capacity when a full group took one more.
  final int studentCount;
  final int? capacity;
  final int? freeSeats;
  final int paidCount;
  final int unpaidCount;
  final ProfileAttendance attendance;

  /// This billing period: charged, and paid toward it.
  final int expected;
  final int collected;

  /// Everything still unpaid on the group, however old.
  final int debtTotal;
  final DateTime? nextBillingDate;
  final List<DateTime> nextLessons;
  final List<GroupWaiting> waiting;

  bool get isFull => capacity != null && studentCount >= capacity!;

  /// 0..1 of the expected money that has come in (0 when nothing is expected).
  double get collectedShare =>
      expected <= 0 ? 0 : (collected / expected).clamp(0.0, 1.0);

  factory GroupProfileData.fromJson(Map<String, dynamic> json) =>
      GroupProfileData(
        group: Group.fromJson(json['group'] as Map<String, dynamic>),
        subjectName: json['subject_name'] as String?,
        teacher: json['teacher'] == null
            ? null
            : GroupTeacher.fromJson(json['teacher'] as Map<String, dynamic>),
        schedule: [
          for (final s in json['schedule'] as List<dynamic>? ?? const [])
            ScheduleSlot.fromJson(s as Map<String, dynamic>),
        ],
        studentCount: json['student_count'] as int,
        capacity: json['capacity'] as int?,
        freeSeats: json['free_seats'] as int?,
        paidCount: json['paid_count'] as int,
        unpaidCount: json['unpaid_count'] as int,
        attendance: ProfileAttendance.fromJson(
          json['attendance'] as Map<String, dynamic>,
        ),
        expected: json['expected'] as int,
        collected: json['collected'] as int,
        debtTotal: json['debt_total'] as int,
        nextBillingDate: json['next_billing_date'] == null
            ? null
            : DateTime.parse(json['next_billing_date'] as String),
        nextLessons: [
          for (final d in json['next_lessons'] as List<dynamic>? ?? const [])
            _dt(d),
        ],
        waiting: [
          for (final w in json['waiting'] as List<dynamic>? ?? const [])
            GroupWaiting.fromJson(w as Map<String, dynamic>),
        ],
      );
}
