import '../../timetable/data/timetable_models.dart';

DateTime? _dt(Object? v) =>
    v == null ? null : DateTime.parse(v as String).toLocal();

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
    this.branchId,
    this.branchName,
  });

  final int groupId;

  /// The branch it is in (shown while looking at every branch).
  final int? branchId;
  final String? branchName;
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
    branchId: json['branch_id'] as int?,
    branchName: json['branch_name'] as String?,
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

/// An open request that looks like the person being saved.
class SimilarLead {
  const SimilarLead({
    required this.id,
    required this.fullName,
    required this.phone,
    this.groupName,
    this.subjectName,
  });

  final int id;
  final String fullName;
  final String phone;
  final String? groupName;
  final String? subjectName;

  factory SimilarLead.fromJson(Map<String, dynamic> json) => SimilarLead(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    groupName: json['group_name'] as String?,
    subjectName: json['subject_name'] as String?,
  );
}

/// A student who has this phone or this name, with the groups they study in.
class SimilarStudent {
  const SimilarStudent({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.groups,
    this.branchNames = const [],
    this.inScope = true,
  });

  final int id;
  final String fullName;
  final String phone;
  final List<String> groups;

  /// The branches they are in; for a student of ANOTHER branch ([inScope]
  /// false) the name and these are all that is shown.
  final List<String> branchNames;
  final bool inScope;

  factory SimilarStudent.fromJson(Map<String, dynamic> json) => SimilarStudent(
    id: json['student_id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    groups: (json['group_names'] as List<dynamic>).cast<String>(),
    branchNames: (json['branch_names'] as List<dynamic>? ?? const [])
        .cast<String>(),
    inScope: json['in_scope'] as bool? ?? true,
  );
}

/// What the front desk should know before saving someone. Only a warning:
/// one person may study in several groups, so nothing here blocks a save.
class DuplicateCheck {
  const DuplicateCheck({
    this.phoneStudent,
    this.phoneLeads = const [],
    this.nameStudents = const [],
    this.nameLeads = const [],
  });

  static const none = DuplicateCheck();

  final SimilarStudent? phoneStudent;
  final List<SimilarLead> phoneLeads;
  final List<SimilarStudent> nameStudents;
  final List<SimilarLead> nameLeads;

  bool get isEmpty =>
      phoneStudent == null &&
      phoneLeads.isEmpty &&
      nameStudents.isEmpty &&
      nameLeads.isEmpty;

  factory DuplicateCheck.fromJson(Map<String, dynamic> json) => DuplicateCheck(
    phoneStudent: json['phone_student'] == null
        ? null
        : SimilarStudent.fromJson(
            json['phone_student'] as Map<String, dynamic>,
          ),
    phoneLeads: [
      for (final e in json['phone_leads'] as List<dynamic>)
        SimilarLead.fromJson(e as Map<String, dynamic>),
    ],
    nameStudents: [
      for (final e in json['name_students'] as List<dynamic>)
        SimilarStudent.fromJson(e as Map<String, dynamic>),
    ],
    nameLeads: [
      for (final e in json['name_leads'] as List<dynamic>)
        SimilarLead.fromJson(e as Map<String, dynamic>),
    ],
  );
}
