import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../../debtors/data/debtors_repository.dart';

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  return DashboardRepository(ref.watch(apiClientProvider));
});

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
    startsAt: json['starts_at'] == null
        ? null
        : DateTime.parse(json['starts_at'] as String),
  );
}

class MonthlyRevenue {
  const MonthlyRevenue({required this.month, required this.amount});

  /// First day of the month.
  final DateTime month;
  final int amount;

  factory MonthlyRevenue.fromJson(Map<String, dynamic> json) => MonthlyRevenue(
    month: DateTime.parse(json['month'] as String),
    amount: json['amount'] as int,
  );
}

class RecentPayment {
  const RecentPayment({
    required this.id,
    required this.enrollmentId,
    required this.studentFullName,
    required this.groupName,
    required this.amount,
    required this.occurredAt,
  });

  final int id;
  final int enrollmentId;
  final String studentFullName;
  final String groupName;
  final int amount;
  final DateTime occurredAt;

  factory RecentPayment.fromJson(Map<String, dynamic> json) => RecentPayment(
    id: json['id'] as int,
    enrollmentId: json['enrollment_id'] as int,
    studentFullName: json['student_full_name'] as String,
    groupName: json['group_name'] as String,
    amount: json['amount'] as int,
    occurredAt: DateTime.parse(json['occurred_at'] as String),
  );
}

/// Everything the desktop home screen shows, fetched in one request. "Today"
/// and "this month" are the center's own (Tashkent), decided server-side.
class DashboardSummary {
  const DashboardSummary({
    required this.today,
    required this.activeStudents,
    required this.newStudentsThisMonth,
    required this.activeGroups,
    required this.collectedThisMonth,
    required this.monthlyPlan,
    required this.totalDebt,
    required this.debtorCount,
    required this.newLeadsThisWeek,
    required this.openLeads,
    required this.unansweredLeads,
    required this.dueTodayCount,
    required this.dueTodayAmount,
    required this.trialsToday,
    required this.revenueByMonth,
    required this.recentPayments,
    required this.topDebtors,
    this.moneyVisible = true,
    this.attendanceRate7d,
    this.tasksDueToday = 0,
  });

  final DateTime today;
  final int activeStudents;
  final int newStudentsThisMonth;
  final int activeGroups;
  final int collectedThisMonth;

  /// What a full month brings in at current fees -- every active
  /// enrollment's group fee, summed.
  final int monthlyPlan;
  final int totalDebt;
  final int debtorCount;
  final int newLeadsThisWeek;
  final int openLeads;

  /// Still 'new' more than 24 hours after the call came in.
  final int unansweredLeads;
  final int dueTodayCount;
  final int dueTodayAmount;
  final List<TrialToday> trialsToday;

  /// Oldest month first, always six entries (quiet months are 0).
  final List<MonthlyRevenue> revenueByMonth;
  final List<RecentPayment> recentPayments;
  final List<Debtor> topDebtors;

  /// False for an admin: what the center collects is the owner's to see (the
  /// server sends zero / nothing for it); admins only collect from students.
  final bool moneyVisible;

  /// The last 7 days of marked lessons: share that came; null = none marked.
  final double? attendanceRate7d;

  /// Calls to make today (follow-up tasks due).
  final int tasksDueToday;

  factory DashboardSummary.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) parse) =>
        (json[key] as List<dynamic>)
            .map((e) => parse(e as Map<String, dynamic>))
            .toList();

    return DashboardSummary(
      today: DateTime.parse(json['today'] as String),
      activeStudents: json['active_students'] as int,
      newStudentsThisMonth: json['new_students_this_month'] as int,
      activeGroups: json['active_groups'] as int,
      collectedThisMonth: json['collected_this_month'] as int,
      monthlyPlan: json['monthly_plan'] as int,
      totalDebt: json['total_debt'] as int,
      debtorCount: json['debtor_count'] as int,
      newLeadsThisWeek: json['new_leads_this_week'] as int,
      openLeads: json['open_leads'] as int,
      unansweredLeads: json['unanswered_leads'] as int,
      dueTodayCount: json['due_today_count'] as int,
      dueTodayAmount: json['due_today_amount'] as int,
      trialsToday: list('trials_today', TrialToday.fromJson),
      revenueByMonth: list('revenue_by_month', MonthlyRevenue.fromJson),
      recentPayments: list('recent_payments', RecentPayment.fromJson),
      topDebtors: list('top_debtors', Debtor.fromJson),
      moneyVisible: json['money_visible'] as bool? ?? true,
      attendanceRate7d: (json['attendance_rate_7d'] as num?)?.toDouble(),
      tasksDueToday: json['tasks_due_today'] as int? ?? 0,
    );
  }
}

/// One branch's line on the owner's home page.
class BranchStats {
  const BranchStats({
    required this.branchId,
    required this.name,
    this.isHeadquarters = false,
    required this.activeStudents,
    required this.activeGroups,
    required this.collectedThisMonth,
    required this.totalDebt,
    required this.debtorCount,
    this.attendanceRate7d,
    required this.lessonsToday,
    required this.openLeads,
  });

  final int branchId;
  final String name;
  final bool isHeadquarters;
  final int activeStudents;
  final int activeGroups;
  final int collectedThisMonth;
  final int totalDebt;
  final int debtorCount;
  final double? attendanceRate7d;
  final int lessonsToday;
  final int openLeads;

  factory BranchStats.fromJson(Map<String, dynamic> json) => BranchStats(
    branchId: json['branch_id'] as int,
    name: json['name'] as String,
    isHeadquarters: json['is_headquarters'] as bool? ?? false,
    activeStudents: json['active_students'] as int,
    activeGroups: json['active_groups'] as int,
    collectedThisMonth: json['collected_this_month'] as int,
    totalDebt: json['total_debt'] as int,
    debtorCount: json['debtor_count'] as int,
    attendanceRate7d: (json['attendance_rate_7d'] as num?)?.toDouble(),
    lessonsToday: json['lessons_today'] as int,
    openLeads: json['open_leads'] as int,
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

  Future<DashboardSummary> fetch() async {
    final json = await _api.get('/dashboard') as Map<String, dynamic>;
    return DashboardSummary.fromJson(json);
  }
}
