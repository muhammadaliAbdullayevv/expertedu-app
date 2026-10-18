import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../../timetable/data/timetable_models.dart';

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  return DashboardRepository(ref.watch(apiClientProvider));
});

DateTime _dt(Object? v) => DateTime.parse(v as String);

List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) parse) =>
    (v as List<dynamic>).map((e) => parse(e as Map<String, dynamic>)).toList();

class TrialToday {
  const TrialToday({
    required this.inquiryId,
    required this.fullName,
    required this.phone,
    this.subjectName,
    this.startsAt,
  });

  final int inquiryId;
  final String fullName;
  final String phone;
  final String? subjectName;
  final DateTime? startsAt;

  factory TrialToday.fromJson(Map<String, dynamic> json) => TrialToday(
    inquiryId: json['inquiry_id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    subjectName: json['subject_name'] as String?,
    startsAt: json['starts_at'] == null ? null : _dt(json['starts_at']),
  );
}

/// A student marked absent at one of today's lessons.
class AbsentToday {
  const AbsentToday({
    required this.studentId,
    required this.fullName,
    required this.phone,
    this.parentPhone,
    required this.groupId,
    required this.groupName,
    required this.startsAt,
  });

  final int studentId;
  final String fullName;
  final String phone;
  final String? parentPhone;
  final int groupId;
  final String groupName;
  final DateTime startsAt;

  factory AbsentToday.fromJson(Map<String, dynamic> json) => AbsentToday(
    studentId: json['student_id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    parentPhone: json['parent_phone'] as String?,
    groupId: json['group_id'] as int,
    groupName: json['group_name'] as String,
    startsAt: _dt(json['starts_at']),
  );
}

/// A call to make (a follow-up task that is due), as the person to call.
class TodayCall {
  const TodayCall({
    required this.taskId,
    required this.leadId,
    required this.leadName,
    required this.leadPhone,
    required this.title,
    required this.dueAt,
    required this.overdue,
  });

  final int taskId;
  final int leadId;
  final String leadName;
  final String leadPhone;
  final String title;
  final DateTime dueAt;
  final bool overdue;

  factory TodayCall.fromJson(Map<String, dynamic> json) => TodayCall(
    taskId: json['task_id'] as int,
    leadId: json['lead_id'] as int,
    leadName: json['lead_name'] as String,
    leadPhone: json['lead_phone'] as String,
    title: json['title'] as String,
    dueAt: _dt(json['due_at']),
    overdue: json['overdue'] as bool,
  );
}

/// A request nobody answered for more than a day.
class TodayLead {
  const TodayLead({
    required this.leadId,
    required this.fullName,
    required this.phone,
    this.subjectName,
    required this.createdAt,
  });

  final int leadId;
  final String fullName;
  final String phone;
  final String? subjectName;
  final DateTime createdAt;

  factory TodayLead.fromJson(Map<String, dynamic> json) => TodayLead(
    leadId: json['lead_id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    subjectName: json['subject_name'] as String?,
    createdAt: _dt(json['created_at']),
  );
}

/// A student whose payment day is today and who still owes.
class PayToday {
  const PayToday({
    required this.studentId,
    required this.fullName,
    required this.groupName,
    required this.amount,
  });

  final int studentId;
  final String fullName;
  final String groupName;
  final int amount;

  factory PayToday.fromJson(Map<String, dynamic> json) => PayToday(
    studentId: json['student_id'] as int,
    fullName: json['full_name'] as String,
    groupName: json['group_name'] as String,
    amount: json['amount'] as int,
  );
}

/// How the day is going (no money): the owner's strip.
class TodayStats {
  const TodayStats({
    required this.activeStudents,
    required this.lessonsPlanned,
    required this.lessonsHeld,
    required this.lessonsUnmarked,
    required this.came,
    required this.absent,
    required this.expected,
    this.attendanceRate,
    required this.newLeadsToday,
    required this.trialsToday,
    required this.atRiskStudents,
  });

  final int activeStudents;
  final int lessonsPlanned;
  final int lessonsHeld;
  final int lessonsUnmarked;
  final int came;
  final int absent;
  final int expected;
  final double? attendanceRate;
  final int newLeadsToday;
  final int trialsToday;
  final int atRiskStudents;

  factory TodayStats.fromJson(Map<String, dynamic> json) => TodayStats(
    activeStudents: json['active_students'] as int,
    lessonsPlanned: json['lessons_planned'] as int,
    lessonsHeld: json['lessons_held'] as int,
    lessonsUnmarked: json['lessons_unmarked'] as int,
    came: json['came'] as int,
    absent: json['absent'] as int,
    expected: json['expected'] as int,
    attendanceRate: (json['attendance_rate'] as num?)?.toDouble(),
    newLeadsToday: json['new_leads_today'] as int,
    trialsToday: json['trials_today'] as int,
    atRiskStudents: json['at_risk_students'] as int,
  );
}

/// Bugun in one answer: what happened today and what is waiting.
class TodayView {
  const TodayView({
    required this.today,
    this.isOwner = false,
    required this.lessons,
    required this.absentees,
    required this.calls,
    required this.callsTotal,
    required this.unanswered,
    required this.unansweredTotal,
    required this.trialsToday,
    required this.payToday,
    required this.payTodayTotal,
    required this.payTodayAmount,
    required this.tomorrowLessons,
    required this.tomorrowTrials,
    required this.stats,
  });

  final DateTime today;

  /// The owner also gets the stats strip and the branch table.
  final bool isOwner;
  final List<TimetableLesson> lessons;
  final List<AbsentToday> absentees;
  final List<TodayCall> calls;
  final int callsTotal;
  final List<TodayLead> unanswered;
  final int unansweredTotal;
  final List<TrialToday> trialsToday;
  final List<PayToday> payToday;
  final int payTodayTotal;
  final int payTodayAmount;
  final int tomorrowLessons;
  final int tomorrowTrials;
  final TodayStats stats;

  /// Nothing is waiting for the admin.
  bool get nothingWaiting =>
      callsTotal == 0 &&
      unansweredTotal == 0 &&
      trialsToday.isEmpty &&
      payTodayTotal == 0;

  factory TodayView.fromJson(Map<String, dynamic> json) => TodayView(
    today: DateTime.parse(json['today'] as String),
    isOwner: json['is_owner'] as bool? ?? false,
    lessons: _list(json['lessons'], TimetableLesson.fromJson),
    absentees: _list(json['absentees'], AbsentToday.fromJson),
    calls: _list(json['calls'], TodayCall.fromJson),
    callsTotal: json['calls_total'] as int,
    unanswered: _list(json['unanswered'], TodayLead.fromJson),
    unansweredTotal: json['unanswered_total'] as int,
    trialsToday: _list(json['trials_today'], TrialToday.fromJson),
    payToday: _list(json['pay_today'], PayToday.fromJson),
    payTodayTotal: json['pay_today_total'] as int,
    payTodayAmount: json['pay_today_amount'] as int,
    tomorrowLessons: json['tomorrow_lessons'] as int,
    tomorrowTrials: json['tomorrow_trials'] as int,
    stats: TodayStats.fromJson(json['stats'] as Map<String, dynamic>),
  );
}

/// One branch's line on the owner's home page: how its day is going.
class BranchStats {
  const BranchStats({
    required this.branchId,
    required this.name,
    this.isHeadquarters = false,
    required this.activeStudents,
    required this.lessonsPlanned,
    required this.lessonsHeld,
    required this.lessonsUnmarked,
    this.attendanceRate,
    required this.newLeadsToday,
    required this.trialsToday,
    required this.atRiskStudents,
  });

  final int branchId;
  final String name;
  final bool isHeadquarters;
  final int activeStudents;
  final int lessonsPlanned;
  final int lessonsHeld;
  final int lessonsUnmarked;
  final double? attendanceRate;
  final int newLeadsToday;
  final int trialsToday;
  final int atRiskStudents;

  factory BranchStats.fromJson(Map<String, dynamic> json) => BranchStats(
    branchId: json['branch_id'] as int,
    name: json['name'] as String,
    isHeadquarters: json['is_headquarters'] as bool? ?? false,
    activeStudents: json['active_students'] as int,
    lessonsPlanned: json['lessons_planned'] as int,
    lessonsHeld: json['lessons_held'] as int,
    lessonsUnmarked: json['lessons_unmarked'] as int,
    attendanceRate: (json['attendance_rate'] as num?)?.toDouble(),
    newLeadsToday: json['new_leads_today'] as int,
    trialsToday: json['trials_today'] as int,
    atRiskStudents: json['at_risk_students'] as int,
  );
}

class DashboardRepository {
  DashboardRepository(this._api);

  final ApiClient _api;

  /// OWNER ONLY: every branch side by side.
  Future<List<BranchStats>> branches() async {
    final json = await _api.get('/dashboard/branches') as List<dynamic>;
    return [
      for (final b in json) BranchStats.fromJson(b as Map<String, dynamic>),
    ];
  }

  Future<TodayView> today() async {
    final json = await _api.get('/dashboard/today') as Map<String, dynamic>;
    return TodayView.fromJson(json);
  }
}
