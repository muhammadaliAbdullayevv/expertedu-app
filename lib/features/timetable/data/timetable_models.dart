import 'package:flutter/material.dart';

/// ISO weekdays, 1 = Monday.
const List<String> weekdayNames = <String>[
  '',
  'Dushanba',
  'Seshanba',
  'Chorshanba',
  'Payshanba',
  'Juma',
  'Shanba',
  'Yakshanba',
];
const List<String> weekdayShort = <String>[
  '',
  'Du',
  'Se',
  'Cho',
  'Pa',
  'Ju',
  'Sha',
  'Ya',
];

TimeOfDay _time(String value) {
  final parts = value.split(':');
  return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
}

String hhmm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// One weekly lesson slot of a group, in the center's local time.
class ScheduleSlot {
  const ScheduleSlot({
    required this.weekday,
    required this.startsAt,
    required this.endsAt,
    this.room,
  });

  final int weekday;
  final TimeOfDay startsAt;
  final TimeOfDay endsAt;
  final String? room;

  factory ScheduleSlot.fromJson(Map<String, dynamic> json) => ScheduleSlot(
    weekday: json['weekday'] as int,
    startsAt: _time(json['starts_at'] as String),
    endsAt: _time(json['ends_at'] as String),
    room: json['room'] as String?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'weekday': weekday,
    'starts_at': hhmm(startsAt),
    'ends_at': hhmm(endsAt),
    'room': room,
  };
}

/// "Du, Cho, Ju 14:00" -- a group's week in a few characters; times are
/// listed per day when they differ.
String scheduleSummary(List<ScheduleSlot> slots) {
  if (slots.isEmpty) return 'Jadval yo\'q';
  final times = slots.map((s) => hhmm(s.startsAt)).toSet();
  if (times.length == 1) {
    return '${slots.map((s) => weekdayShort[s.weekday]).join(', ')} ${times.single}';
  }
  return slots
      .map((s) => '${weekdayShort[s.weekday]} ${hhmm(s.startsAt)}')
      .join(', ');
}

class TimetableLesson {
  const TimetableLesson({
    required this.groupId,
    required this.groupName,
    this.subjectName,
    this.teacherId,
    this.teacherName,
    this.room,
    required this.startsAt,
    required this.endsAt,
    this.lessonId,
    required this.status,
    this.cancelReason,
    required this.isExtra,
    required this.studentCount,
    required this.markedCount,
    required this.presentCount,
    this.lateCount = 0,
    this.absentCount = 0,
    this.excusedCount = 0,
  });

  final int groupId;
  final String groupName;
  final String? subjectName;
  final int? teacherId;
  final String? teacherName;
  final String? room;
  final DateTime startsAt;
  final DateTime endsAt;
  final int? lessonId;

  /// 'scheduled' | 'cancelled'.
  final String status;
  final String? cancelReason;
  final bool isExtra;
  final int studentCount;
  final int markedCount;

  /// Came: on time or late (late is also counted in [lateCount]).
  final int presentCount;
  final int lateCount;
  final int absentCount;
  final int excusedCount;

  bool get isCancelled => status == 'cancelled';
  bool get hasStarted => !startsAt.isAfter(DateTime.now());
  bool get isMarked => markedCount > 0;

  factory TimetableLesson.fromJson(Map<String, dynamic> json) =>
      TimetableLesson(
        groupId: json['group_id'] as int,
        groupName: json['group_name'] as String,
        subjectName: json['subject_name'] as String?,
        teacherId: json['teacher_id'] as int?,
        teacherName: json['teacher_name'] as String?,
        room: json['room'] as String?,
        startsAt: DateTime.parse(json['starts_at'] as String),
        endsAt: DateTime.parse(json['ends_at'] as String),
        lessonId: json['lesson_id'] as int?,
        status: json['status'] as String,
        cancelReason: json['cancel_reason'] as String?,
        isExtra: json['is_extra'] as bool,
        studentCount: json['student_count'] as int,
        markedCount: json['marked_count'] as int,
        presentCount: json['present_count'] as int,
        lateCount: json['late_count'] as int? ?? 0,
        absentCount: json['absent_count'] as int? ?? 0,
        excusedCount: json['excused_count'] as int? ?? 0,
      );
}

/// Attendance statuses, in the order the sheet offers them.
class AttendanceStatus {
  AttendanceStatus._();

  static const String present = 'present';
  static const String late = 'late';
  static const String absent = 'absent';
  static const String excused = 'excused';

  static const List<String> all = <String>[present, late, absent, excused];

  static const Map<String, String> labels = <String, String>{
    present: 'Keldi',
    late: 'Kechikdi',
    absent: 'Kelmadi',
    excused: 'Sababli',
  };
}

class SheetStudent {
  const SheetStudent({
    required this.enrollmentId,
    required this.studentId,
    required this.fullName,
    required this.phone,
    this.status,
    this.note,
  });

  final int enrollmentId;
  final int studentId;
  final String fullName;
  final String phone;
  final String? status;
  final String? note;

  factory SheetStudent.fromJson(Map<String, dynamic> json) => SheetStudent(
    enrollmentId: json['enrollment_id'] as int,
    studentId: json['student_id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    status: json['status'] as String?,
    note: json['note'] as String?,
  );
}

class SheetTrialGuest {
  const SheetTrialGuest({
    required this.bookingId,
    required this.leadId,
    required this.fullName,
    required this.status,
  });

  final int bookingId;
  final int leadId;
  final String fullName;
  final String status;

  factory SheetTrialGuest.fromJson(Map<String, dynamic> json) =>
      SheetTrialGuest(
        bookingId: json['booking_id'] as int,
        leadId: json['lead_id'] as int,
        fullName: json['full_name'] as String,
        status: json['status'] as String,
      );
}

class AttendanceSheet {
  const AttendanceSheet({
    required this.lesson,
    required this.students,
    required this.trialGuests,
  });

  final TimetableLesson lesson;
  final List<SheetStudent> students;
  final List<SheetTrialGuest> trialGuests;

  factory AttendanceSheet.fromJson(Map<String, dynamic> json) =>
      AttendanceSheet(
        lesson: TimetableLesson.fromJson(
          json['lesson'] as Map<String, dynamic>,
        ),
        students: (json['students'] as List<dynamic>)
            .map((e) => SheetStudent.fromJson(e as Map<String, dynamic>))
            .toList(),
        trialGuests: (json['trial_guests'] as List<dynamic>)
            .map((e) => SheetTrialGuest.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class AttendanceReportRow {
  const AttendanceReportRow({
    required this.enrollmentId,
    required this.studentId,
    required this.fullName,
    required this.phone,
    required this.groupId,
    required this.groupName,
    required this.lessons,
    required this.present,
    required this.late,
    required this.absent,
    required this.excused,
    this.rate,
  });

  final int enrollmentId;
  final int studentId;
  final String fullName;
  final String phone;
  final int groupId;
  final String groupName;
  final int lessons;
  final int present;
  final int late;
  final int absent;
  final int excused;

  /// (present + late) / lessons.
  final double? rate;

  factory AttendanceReportRow.fromJson(Map<String, dynamic> json) =>
      AttendanceReportRow(
        enrollmentId: json['enrollment_id'] as int,
        studentId: json['student_id'] as int,
        fullName: json['full_name'] as String,
        phone: json['phone'] as String,
        groupId: json['group_id'] as int,
        groupName: json['group_name'] as String,
        lessons: json['lessons'] as int,
        present: json['present'] as int,
        late: json['late'] as int,
        absent: json['absent'] as int,
        excused: json['excused'] as int,
        rate: (json['rate'] as num?)?.toDouble(),
      );
}
