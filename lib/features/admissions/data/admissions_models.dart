import '../../students/data/students_repository.dart';

DateTime? _dateTime(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

/// A lead's stage, as the server stores it (see server/app/admissions.py).
/// A lead becomes 'enrolled' only through the enrollment wizard, and
/// 'trial_scheduled' / 'trial_completed' only from its trial bookings.
class LeadStage {
  LeadStage._();

  static const String newLead = 'new';
  static const String contacted = 'contacted';
  static const String trialScheduled = 'trial_scheduled';
  static const String trialCompleted = 'trial_completed';
  static const String decisionPending = 'decision_pending';
  static const String followUpLater = 'follow_up_later';
  static const String enrolled = 'enrolled';
  static const String notInterested = 'not_interested';
  static const String unreachable = 'unreachable';

  /// Pipeline order -- the board's columns.
  static const List<String> open = <String>[
    newLead,
    contacted,
    trialScheduled,
    trialCompleted,
    decisionPending,
    followUpLater,
  ];
  static const List<String> closed = <String>[notInterested, unreachable];

  /// What an operator may pick by hand.
  static const List<String> manual = <String>[
    contacted,
    decisionPending,
    followUpLater,
    notInterested,
    unreachable,
  ];

  static const Map<String, String> labels = <String, String>{
    newLead: 'Yangi',
    contacted: 'Bog\'lanildi',
    trialScheduled: 'Sinov rejalashtirildi',
    trialCompleted: 'Sinov o\'tdi',
    decisionPending: 'Qaror kutilmoqda',
    followUpLater: 'Keyinroq bog\'lanish',
    enrolled: 'O\'quvchi bo\'ldi',
    notInterested: 'Qiziqmadi',
    unreachable: 'Bog\'lanib bo\'lmadi',
  };

  static String label(String stage) => labels[stage] ?? stage;
  static bool isOpen(String stage) => open.contains(stage);
}

class Lead {
  const Lead({
    required this.id,
    required this.clientId,
    required this.fullName,
    required this.phone,
    this.parentPhone,
    this.note,
    this.subjectId,
    this.subjectName,
    this.source,
    required this.stage,
    this.lostReason,
    this.assignedTo,
    this.assignedToName,
    this.studentId,
    this.enrollmentId,
    this.enrolledAt,
    this.closedAt,
    this.preferredTrialDate,
    this.nextTrialAt,
    this.nextTrialBookingId,
    this.nextTaskDueAt,
    this.lastContactAt,
    required this.version,
    required this.createdAt,
    this.merged = false,
    this.pendingLocalId,
  });

  /// 0 for a lead made offline that hasn't reached the server yet -- see
  /// [pendingLocalId].
  final int id;
  final String clientId;
  final String fullName;
  final String phone;
  final String? parentPhone;
  final String? note;
  final int? subjectId;
  final String? subjectName;
  final String? source;
  final String stage;
  final String? lostReason;
  final int? assignedTo;
  final String? assignedToName;

  /// The student with this phone -- set from the start when the caller
  /// already is one, and by enrollment otherwise.
  final int? studentId;
  final int? enrollmentId;
  final DateTime? enrolledAt;
  final DateTime? closedAt;
  final DateTime? preferredTrialDate;
  final DateTime? nextTrialAt;
  final int? nextTrialBookingId;
  final DateTime? nextTaskDueAt;
  final DateTime? lastContactAt;

  /// Sent back with every edit; the server refuses an edit made from an
  /// out-of-date copy.
  final int version;
  final DateTime createdAt;

  /// True when the server folded this into a lead the phone already had.
  final bool merged;

  /// Set only on a lead still waiting in the offline outbox.
  final String? pendingLocalId;

  bool get isPending => pendingLocalId != null;
  bool get isOpen => LeadStage.isOpen(stage);

  factory Lead.fromJson(Map<String, dynamic> json) => Lead(
    id: json['id'] as int,
    clientId: json['client_id'] as String,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    parentPhone: json['parent_phone'] as String?,
    note: json['note'] as String?,
    subjectId: json['subject_id'] as int?,
    subjectName: json['subject_name'] as String?,
    source: json['source'] as String?,
    stage: json['stage'] as String,
    lostReason: json['lost_reason'] as String?,
    assignedTo: json['assigned_to'] as int?,
    assignedToName: json['assigned_to_name'] as String?,
    studentId: json['student_id'] as int?,
    enrollmentId: json['enrollment_id'] as int?,
    enrolledAt: _dateTime(json['enrolled_at']),
    closedAt: _dateTime(json['closed_at']),
    preferredTrialDate: _dateTime(json['preferred_trial_date']),
    nextTrialAt: _dateTime(json['next_trial_at']),
    nextTrialBookingId: json['next_trial_booking_id'] as int?,
    nextTaskDueAt: _dateTime(json['next_task_due_at']),
    lastContactAt: _dateTime(json['last_contact_at']),
    version: json['version'] as int,
    createdAt: DateTime.parse(json['created_at'] as String),
    merged: json['merged'] as bool? ?? false,
  );
}

class LeadPage {
  const LeadPage({required this.items, required this.total});

  final List<Lead> items;
  final int total;

  factory LeadPage.fromJson(Map<String, dynamic> json) => LeadPage(
    items: (json['items'] as List<dynamic>)
        .map((e) => Lead.fromJson(e as Map<String, dynamic>))
        .toList(),
    total: json['total'] as int,
  );
}

/// Everything known about a phone: its student (if any) and its leads.
class PhoneLookup {
  const PhoneLookup({required this.phone, this.student, required this.leads});

  final String phone;
  final PhoneOwner? student;
  final List<Lead> leads;

  List<Lead> get openLeads => leads.where((l) => l.isOpen).toList();

  factory PhoneLookup.fromJson(Map<String, dynamic> json) => PhoneLookup(
    phone: json['phone'] as String,
    student: json['student'] == null
        ? null
        : PhoneOwner.fromJson(json['student'] as Map<String, dynamic>),
    leads: (json['leads'] as List<dynamic>)
        .map((e) => Lead.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

class LeadInteraction {
  const LeadInteraction({
    required this.id,
    required this.kind,
    required this.body,
    this.oldStage,
    this.newStage,
    this.bookingId,
    this.taskId,
    this.createdByName,
    required this.createdAt,
  });

  final int id;

  /// 'call_in' | 'call_out' | 'sms' | 'telegram' | 'visit' | 'note', or
  /// 'system' for a change the server logged itself.
  final String kind;
  final String body;
  final String? oldStage;
  final String? newStage;
  final int? bookingId;
  final int? taskId;
  final String? createdByName;
  final DateTime createdAt;

  static const Map<String, String> kindLabels = <String, String>{
    'call_in': 'Kiruvchi qo\'ng\'iroq',
    'call_out': 'Chiquvchi qo\'ng\'iroq',
    'sms': 'SMS',
    'telegram': 'Telegram',
    'visit': 'Tashrif',
    'note': 'Izoh',
  };

  factory LeadInteraction.fromJson(Map<String, dynamic> json) =>
      LeadInteraction(
        id: json['id'] as int,
        kind: json['kind'] as String,
        body: json['body'] as String,
        oldStage: json['old_stage'] as String?,
        newStage: json['new_stage'] as String?,
        bookingId: json['booking_id'] as int?,
        taskId: json['task_id'] as int?,
        createdByName: json['created_by_name'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class FollowUpTask {
  const FollowUpTask({
    required this.id,
    required this.leadId,
    this.leadFullName,
    this.leadPhone,
    this.leadStage,
    required this.title,
    required this.dueAt,
    this.assignedTo,
    this.assignedToName,
    required this.status,
    this.completedAt,
    required this.version,
  });

  final int id;
  final int leadId;
  final String? leadFullName;
  final String? leadPhone;
  final String? leadStage;
  final String title;
  final DateTime dueAt;
  final int? assignedTo;
  final String? assignedToName;

  /// 'open' | 'done' | 'cancelled'.
  final String status;
  final DateTime? completedAt;
  final int version;

  bool get isOpen => status == 'open';
  bool get isOverdue => isOpen && dueAt.isBefore(DateTime.now());

  factory FollowUpTask.fromJson(Map<String, dynamic> json) => FollowUpTask(
    id: json['id'] as int,
    leadId: json['lead_id'] as int,
    leadFullName: json['lead_full_name'] as String?,
    leadPhone: json['lead_phone'] as String?,
    leadStage: json['lead_stage'] as String?,
    title: json['title'] as String,
    dueAt: DateTime.parse(json['due_at'] as String),
    assignedTo: json['assigned_to'] as int?,
    assignedToName: json['assigned_to_name'] as String?,
    status: json['status'] as String,
    completedAt: _dateTime(json['completed_at']),
    version: json['version'] as int,
  );
}

/// Trial booking statuses.
class TrialStatus {
  TrialStatus._();

  static const String scheduled = 'scheduled';
  static const String attended = 'attended';
  static const String absent = 'absent';
  static const String cancelled = 'cancelled';
  static const String rescheduled = 'rescheduled';

  static const Map<String, String> labels = <String, String>{
    scheduled: 'Rejalashtirilgan',
    attended: 'Keldi',
    absent: 'Kelmadi',
    cancelled: 'Bekor qilindi',
    rescheduled: 'Ko\'chirildi',
  };

  static String label(String status) => labels[status] ?? status;
}

class TrialSessionBooking {
  const TrialSessionBooking({
    required this.id,
    required this.leadId,
    required this.leadFullName,
    required this.leadPhone,
    required this.status,
    this.feedback,
  });

  final int id;
  final int leadId;
  final String leadFullName;
  final String leadPhone;
  final String status;
  final String? feedback;

  factory TrialSessionBooking.fromJson(Map<String, dynamic> json) =>
      TrialSessionBooking(
        id: json['id'] as int,
        leadId: json['lead_id'] as int,
        leadFullName: json['lead_full_name'] as String,
        leadPhone: json['lead_phone'] as String,
        status: json['status'] as String,
        feedback: json['feedback'] as String?,
      );
}

class TrialSession {
  const TrialSession({
    required this.id,
    required this.kind,
    this.subjectId,
    this.subjectName,
    this.groupId,
    this.groupName,
    this.teacherId,
    this.teacherName,
    this.room,
    required this.startsAt,
    required this.endsAt,
    required this.capacity,
    required this.status,
    this.note,
    required this.version,
    required this.booked,
    required this.bookings,
  });

  final int id;

  /// 'dedicated', or 'group_lesson' -- guest seats at a regular group's
  /// lesson (still no enrollment).
  final String kind;
  final int? subjectId;
  final String? subjectName;
  final int? groupId;
  final String? groupName;
  final int? teacherId;
  final String? teacherName;
  final String? room;
  final DateTime startsAt;
  final DateTime endsAt;
  final int capacity;

  /// 'scheduled' | 'cancelled'.
  final String status;
  final String? note;
  final int version;

  /// Seats taken (scheduled, attended and absent bookings).
  final int booked;
  final List<TrialSessionBooking> bookings;

  bool get isFull => booked >= capacity;
  bool get hasStarted => !startsAt.isAfter(DateTime.now());
  bool get hasEnded => !endsAt.isAfter(DateTime.now());

  /// "Sinov darsi" or the group's name.
  String get title => kind == 'group_lesson'
      ? 'Guruh darsi: ${groupName ?? ''}'
      : 'Sinov darsi${subjectName == null ? '' : ' · $subjectName'}';

  factory TrialSession.fromJson(Map<String, dynamic> json) => TrialSession(
    id: json['id'] as int,
    kind: json['kind'] as String,
    subjectId: json['subject_id'] as int?,
    subjectName: json['subject_name'] as String?,
    groupId: json['group_id'] as int?,
    groupName: json['group_name'] as String?,
    teacherId: json['teacher_id'] as int?,
    teacherName: json['teacher_name'] as String?,
    room: json['room'] as String?,
    startsAt: DateTime.parse(json['starts_at'] as String),
    endsAt: DateTime.parse(json['ends_at'] as String),
    capacity: json['capacity'] as int,
    status: json['status'] as String,
    note: json['note'] as String?,
    version: json['version'] as int,
    booked: json['booked'] as int? ?? 0,
    bookings: (json['bookings'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => TrialSessionBooking.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

class TrialBooking {
  const TrialBooking({
    required this.id,
    required this.leadId,
    required this.sessionId,
    required this.status,
    this.rescheduledFromId,
    this.cancelReason,
    this.attendanceMarkedAt,
    this.feedback,
    this.recommendedLevel,
    required this.version,
    this.session,
  });

  final int id;
  final int leadId;
  final int sessionId;
  final String status;
  final int? rescheduledFromId;
  final String? cancelReason;
  final DateTime? attendanceMarkedAt;
  final String? feedback;
  final String? recommendedLevel;
  final int version;
  final TrialSession? session;

  factory TrialBooking.fromJson(Map<String, dynamic> json) => TrialBooking(
    id: json['id'] as int,
    leadId: json['lead_id'] as int,
    sessionId: json['session_id'] as int,
    status: json['status'] as String,
    rescheduledFromId: json['rescheduled_from_id'] as int?,
    cancelReason: json['cancel_reason'] as String?,
    attendanceMarkedAt: _dateTime(json['attendance_marked_at']),
    feedback: json['feedback'] as String?,
    recommendedLevel: json['recommended_level'] as String?,
    version: json['version'] as int,
    session: json['session'] == null
        ? null
        : TrialSession.fromJson(json['session'] as Map<String, dynamic>),
  );
}

class LeadDetail {
  const LeadDetail({
    required this.lead,
    required this.interactions,
    required this.bookings,
    required this.tasks,
    this.student,
  });

  final Lead lead;

  /// Newest first.
  final List<LeadInteraction> interactions;

  /// Newest first.
  final List<TrialBooking> bookings;
  final List<FollowUpTask> tasks;

  /// The student who has this lead's phone, if any.
  final PhoneOwner? student;

  factory LeadDetail.fromJson(Map<String, dynamic> json) => LeadDetail(
    lead: Lead.fromJson(json['lead'] as Map<String, dynamic>),
    interactions: (json['interactions'] as List<dynamic>)
        .map((e) => LeadInteraction.fromJson(e as Map<String, dynamic>))
        .toList(),
    bookings: (json['bookings'] as List<dynamic>)
        .map((e) => TrialBooking.fromJson(e as Map<String, dynamic>))
        .toList(),
    tasks: (json['tasks'] as List<dynamic>)
        .map((e) => FollowUpTask.fromJson(e as Map<String, dynamic>))
        .toList(),
    student: json['student'] == null
        ? null
        : PhoneOwner.fromJson(json['student'] as Map<String, dynamic>),
  );
}

class StaffUser {
  const StaffUser({required this.id, required this.fullName});

  final int id;
  final String fullName;

  factory StaffUser.fromJson(Map<String, dynamic> json) =>
      StaffUser(id: json['id'] as int, fullName: json['full_name'] as String);
}

class CountByKey {
  const CountByKey({
    required this.key,
    required this.count,
    required this.enrolled,
  });

  final String key;
  final int count;
  final int enrolled;

  factory CountByKey.fromJson(Map<String, dynamic> json) => CountByKey(
    key: json['key'] as String,
    count: json['count'] as int,
    enrolled: json['enrolled'] as int? ?? 0,
  );
}

/// See server/app/schemas.py AdmissionsReport for what each number counts.
class AdmissionsReport {
  const AdmissionsReport({
    required this.dateFrom,
    required this.dateTo,
    required this.newInquiries,
    required this.trialsBooked,
    required this.trialsAttended,
    required this.trialsAbsent,
    required this.trialsCancelled,
    this.showRate,
    required this.enrollments,
    required this.cohortSize,
    required this.cohortEnrolled,
    this.leadConversionRate,
    required this.trialCohortSize,
    required this.trialCohortEnrolled,
    this.trialConversionRate,
    required this.upcomingTrials,
    required this.followUpsOverdue,
    required this.followUpsDueToday,
    required this.openByStage,
    required this.cohortBySource,
  });

  final DateTime dateFrom;
  final DateTime dateTo;
  final int newInquiries;
  final int trialsBooked;
  final int trialsAttended;
  final int trialsAbsent;
  final int trialsCancelled;
  final double? showRate;
  final int enrollments;
  final int cohortSize;
  final int cohortEnrolled;
  final double? leadConversionRate;
  final int trialCohortSize;
  final int trialCohortEnrolled;
  final double? trialConversionRate;
  final int upcomingTrials;
  final int followUpsOverdue;
  final int followUpsDueToday;
  final List<CountByKey> openByStage;
  final List<CountByKey> cohortBySource;

  static List<CountByKey> _counts(Object? value) => (value as List<dynamic>)
      .map((e) => CountByKey.fromJson(e as Map<String, dynamic>))
      .toList();

  factory AdmissionsReport.fromJson(Map<String, dynamic> json) =>
      AdmissionsReport(
        dateFrom: DateTime.parse(json['date_from'] as String),
        dateTo: DateTime.parse(json['date_to'] as String),
        newInquiries: json['new_inquiries'] as int,
        trialsBooked: json['trials_booked'] as int,
        trialsAttended: json['trials_attended'] as int,
        trialsAbsent: json['trials_absent'] as int,
        trialsCancelled: json['trials_cancelled'] as int,
        showRate: (json['show_rate'] as num?)?.toDouble(),
        enrollments: json['enrollments'] as int,
        cohortSize: json['cohort_size'] as int,
        cohortEnrolled: json['cohort_enrolled'] as int,
        leadConversionRate: (json['lead_conversion_rate'] as num?)?.toDouble(),
        trialCohortSize: json['trial_cohort_size'] as int,
        trialCohortEnrolled: json['trial_cohort_enrolled'] as int,
        trialConversionRate: (json['trial_conversion_rate'] as num?)
            ?.toDouble(),
        upcomingTrials: json['upcoming_trials'] as int,
        followUpsOverdue: json['follow_ups_overdue'] as int,
        followUpsDueToday: json['follow_ups_due_today'] as int,
        openByStage: _counts(json['open_by_stage']),
        cohortBySource: _counts(json['cohort_by_source']),
      );
}

/// The wizard's result.
class LeadEnrolled {
  const LeadEnrolled({
    required this.studentId,
    required this.studentName,
    required this.reusedStudent,
    required this.enrollmentId,
    required this.firstCharge,
    required this.firstPayment,
  });

  final int studentId;
  final String studentName;
  final bool reusedStudent;
  final int enrollmentId;
  final int firstCharge;
  final int firstPayment;

  factory LeadEnrolled.fromJson(Map<String, dynamic> json) {
    final student = json['student'] as Map<String, dynamic>;
    return LeadEnrolled(
      studentId: student['id'] as int,
      studentName: student['full_name'] as String,
      reusedStudent: json['reused_student'] as bool,
      enrollmentId: json['enrollment_id'] as int,
      firstCharge: json['first_charge'] as int,
      firstPayment: json['first_payment'] as int,
    );
  }
}
