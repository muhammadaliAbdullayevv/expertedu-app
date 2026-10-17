import '../../timetable/data/timetable_models.dart';

DateTime? _dt(Object? v) =>
    v == null ? null : DateTime.parse(v as String).toLocal();

/// One card on the Qabul board.
class BoardLead {
  const BoardLead({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.stage,
    required this.v2Stage,
    this.source,
    this.lostReason,
    this.subjectName,
    this.assignedToName,
    required this.createdAt,
    this.enrolledAt,
    this.closedAt,
    required this.stageChangedAt,
    this.nextTrialAt,
    this.lastTrialAt,
    this.groupName,
  });

  final int id;
  final String fullName;
  final String phone;

  /// The app's own nine-value stage.
  final String stage;

  /// The column it is in (see server/app/funnel.py -- the one definition).
  final String v2Stage;
  final String? source;
  final String? lostReason;
  final String? subjectName;
  final String? assignedToName;
  final DateTime createdAt;
  final DateTime? enrolledAt;
  final DateTime? closedAt;
  final DateTime stageChangedAt;
  final DateTime? nextTrialAt;
  final DateTime? lastTrialAt;
  final String? groupName;

  factory BoardLead.fromJson(Map<String, dynamic> json) => BoardLead(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    stage: json['stage'] as String,
    v2Stage: json['v2_stage'] as String,
    source: json['source'] as String?,
    lostReason: json['lost_reason'] as String?,
    subjectName: json['subject_name'] as String?,
    assignedToName: json['assigned_to_name'] as String?,
    createdAt: _dt(json['created_at'])!,
    enrolledAt: _dt(json['enrolled_at']),
    closedAt: _dt(json['closed_at']),
    stageChangedAt: _dt(json['stage_changed_at'])!,
    nextTrialAt: _dt(json['next_trial_at']),
    lastTrialAt: _dt(json['last_trial_at']),
    groupName: json['group_name'] as String?,
  );
}

/// The V2 column keys, in board order (the server sends them; these are
/// only for code that needs to name one).
class BoardStage {
  const BoardStage._();

  static const newLead = 'new';
  static const contacted = 'contacted';
  static const trial = 'trial';
  static const awaitingDecision = 'awaiting_decision';
  static const joined = 'joined';
  static const later = 'later';
  static const rejected = 'rejected';
}

class BoardColumn {
  const BoardColumn({
    required this.key,
    required this.label,
    required this.count,
    required this.leads,
  });

  final String key;
  final String label;

  /// The true number in the column -- [leads] may be capped.
  final int count;
  final List<BoardLead> leads;

  factory BoardColumn.fromJson(Map<String, dynamic> json) => BoardColumn(
    key: json['key'] as String,
    label: json['label'] as String,
    count: json['count'] as int,
    leads: (json['leads'] as List<dynamic>)
        .map((e) => BoardLead.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

class FunnelKpi {
  const FunnelKpi({
    required this.leads,
    required this.trialPeople,
    required this.joined,
    required this.rejected,
    required this.cohortSize,
    required this.cohortJoined,
    this.conversionRate,
  });

  final int leads;
  final int trialPeople;
  final int joined;
  final int rejected;
  final int cohortSize;
  final int cohortJoined;
  final double? conversionRate;

  factory FunnelKpi.fromJson(Map<String, dynamic> json) => FunnelKpi(
    leads: json['leads'] as int,
    trialPeople: json['trial_people'] as int,
    joined: json['joined'] as int,
    rejected: json['rejected'] as int,
    cohortSize: json['cohort_size'] as int,
    cohortJoined: json['cohort_joined'] as int,
    conversionRate: (json['conversion_rate'] as num?)?.toDouble(),
  );
}

class AdmissionsBoard {
  const AdmissionsBoard({required this.kpi, required this.columns});

  final FunnelKpi kpi;
  final List<BoardColumn> columns;

  BoardColumn column(String key) => columns.firstWhere((c) => c.key == key);

  /// Everyone not yet joined or rejected -- the same number as the sidebar
  /// badge and Bugun's open leads.
  int get openLeads => columns
      .where((c) => c.key != BoardStage.joined && c.key != BoardStage.rejected)
      .fold(0, (sum, c) => sum + c.count);

  factory AdmissionsBoard.fromJson(Map<String, dynamic> json) =>
      AdmissionsBoard(
        kpi: FunnelKpi.fromJson(json['kpi'] as Map<String, dynamic>),
        columns: (json['columns'] as List<dynamic>)
            .map((e) => BoardColumn.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A group the course finder offers.
class GroupMatch {
  const GroupMatch({
    required this.groupId,
    required this.name,
    this.subjectName,
    this.level,
    this.teacherName,
    required this.feeAmount,
    required this.billingMode,
    this.billingDay,
    required this.prorateFirstPeriod,
    this.startDate,
    this.capacity,
    required this.enrolled,
    this.freeSeats,
    required this.slots,
    required this.matchedDays,
    required this.totalDays,
  });

  final int groupId;
  final String name;
  final String? subjectName;
  final String? level;
  final String? teacherName;
  final int feeAmount;
  final String billingMode;
  final int? billingDay;
  final bool prorateFirstPeriod;
  final DateTime? startDate;
  final int? capacity;
  final int enrolled;

  /// Null = no seat limit.
  final int? freeSeats;
  final List<ScheduleSlot> slots;
  final int matchedDays;
  final int totalDays;

  bool get isFull => freeSeats == 0;
  bool get isAnniversary => billingMode == 'student_anniversary';
  List<int> get weekdays =>
      ({for (final s in slots) s.weekday}.toList()..sort());

  factory GroupMatch.fromJson(Map<String, dynamic> json) => GroupMatch(
    groupId: json['group_id'] as int,
    name: json['name'] as String,
    subjectName: json['subject_name'] as String?,
    level: json['level'] as String?,
    teacherName: json['teacher_name'] as String?,
    feeAmount: json['fee_amount'] as int,
    billingMode: json['billing_mode'] as String,
    billingDay: json['billing_day'] as int?,
    prorateFirstPeriod: json['prorate_first_period'] as bool,
    startDate: json['start_date'] == null
        ? null
        : DateTime.parse(json['start_date'] as String),
    capacity: json['capacity'] as int?,
    enrolled: json['enrolled'] as int,
    freeSeats: json['free_seats'] as int?,
    slots: (json['slots'] as List<dynamic>)
        .map((e) => ScheduleSlot.fromJson(e as Map<String, dynamic>))
        .toList(),
    matchedDays: json['matched_days'] as int,
    totalDays: json['total_days'] as int,
  );
}

class GroupSearchResult {
  const GroupSearchResult({required this.exact, required this.near});

  final List<GroupMatch> exact;
  final List<GroupMatch> near;

  factory GroupSearchResult.fromJson(Map<String, dynamic> json) =>
      GroupSearchResult(
        exact: (json['exact'] as List<dynamic>)
            .map((e) => GroupMatch.fromJson(e as Map<String, dynamic>))
            .toList(),
        near: (json['near'] as List<dynamic>)
            .map((e) => GroupMatch.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One upcoming lesson of a group a guest could try.
class TrialDate {
  const TrialDate({
    required this.startsAt,
    required this.endsAt,
    this.room,
    this.trialSessionId,
    required this.guestsBooked,
    required this.sessionFull,
    this.freeSeats,
    required this.suggestedCapacity,
  });

  final DateTime startsAt;
  final DateTime endsAt;
  final String? room;

  /// A guest session already open for this lesson (book into it).
  final int? trialSessionId;
  final int guestsBooked;
  final bool sessionFull;
  final int? freeSeats;
  final int suggestedCapacity;

  factory TrialDate.fromJson(Map<String, dynamic> json) => TrialDate(
    startsAt: _dt(json['starts_at'])!,
    endsAt: _dt(json['ends_at'])!,
    room: json['room'] as String?,
    trialSessionId: json['trial_session_id'] as int?,
    guestsBooked: json['guests_booked'] as int,
    sessionFull: json['session_full'] as bool? ?? false,
    freeSeats: json['free_seats'] as int?,
    suggestedCapacity: json['suggested_capacity'] as int,
  );
}

/// The numbers beside the sidebar's labels (server/app/funnel.py).
class ShellCounts {
  const ShellCounts({
    required this.openLeads,
    required this.activeStudents,
    required this.activeGroups,
    required this.activeTeachers,
  });

  final int openLeads;
  final int activeStudents;
  final int activeGroups;
  final int activeTeachers;

  factory ShellCounts.fromJson(Map<String, dynamic> json) => ShellCounts(
    openLeads: json['open_leads'] as int,
    activeStudents: json['active_students'] as int,
    activeGroups: json['active_groups'] as int,
    activeTeachers: json['active_teachers'] as int,
  );
}

class StudentSummary {
  const StudentSummary({
    required this.activeStudents,
    required this.totalStudents,
    required this.newStudentsThisMonth,
    required this.studentsWithDebt,
  });

  final int activeStudents;
  final int totalStudents;
  final int newStudentsThisMonth;
  final int studentsWithDebt;

  factory StudentSummary.fromJson(Map<String, dynamic> json) => StudentSummary(
    activeStudents: json['active_students'] as int,
    totalStudents: json['total_students'] as int,
    newStudentsThisMonth: json['new_students_this_month'] as int,
    studentsWithDebt: json['students_with_debt'] as int,
  );
}
