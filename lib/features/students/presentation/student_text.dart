import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../admissions/presentation/qabul_text.dart';
import '../data/student_models.dart';

/// The words and the filtering of the O'quvchilar page -- plain functions of
/// the data, so they can be tested without drawing anything.

/// The tabs above the table.
enum StudentTab {
  all('Hammasi'),
  debtors('Qarzdorlar'),
  atRisk('Xavf ostida'),
  fresh('Yangi'),
  archive('Arxiv');

  const StudentTab(this.label);

  final String label;
}

/// Who is in a tab. "Hammasi" is the active students (at least one group);
/// "Arxiv" is everyone who has none. The flags come from the server.
bool inTab(StudentRow s, StudentTab tab) => switch (tab) {
  StudentTab.all => s.isActive,
  StudentTab.debtors => s.isDebtor,
  StudentTab.atRisk => s.isAtRisk,
  StudentTab.fresh => s.isNew,
  StudentTab.archive => !s.isActive,
};

Map<StudentTab, int> tabCounts(List<StudentRow> rows) => {
  for (final tab in StudentTab.values)
    tab: rows.where((s) => inTab(s, tab)).length,
};

/// The table after a tab and the Fan / Guruh / O'qituvchi filters.
List<StudentRow> filterStudents(
  List<StudentRow> rows, {
  StudentTab tab = StudentTab.all,
  int? subjectId,
  int? groupId,
  int? teacherId,
}) => [
  for (final s in rows)
    if (inTab(s, tab) &&
        (subjectId == null || s.groups.any((g) => g.subjectId == subjectId)) &&
        (groupId == null || s.groups.any((g) => g.groupId == groupId)) &&
        (teacherId == null || s.groups.any((g) => g.teacherId == teacherId)))
      s,
];

/// "−390 000" owed, "0", "+120 000" paid ahead.
String signedBalance(int owed) {
  if (owed == 0) return '0';
  final digits = CurrencyFormatter.format(owed.abs()).replaceAll(' so\'m', '');
  return owed > 0 ? '−$digits' : '+$digits';
}

/// The status chip of a table row, and what it means (shown on hover).
/// "Davomat past" is about lessons missed, never about money.
({String text, StatusTone tone, String hint}) statusOf(StudentRow s) {
  if (!s.isActive) {
    return (
      text: 'Arxiv',
      tone: StatusTone.neutral,
      hint: 'Hech qaysi guruhda emas',
    );
  }
  if (s.isDebtor) {
    return (
      text: 'Qarzdor',
      tone: StatusTone.danger,
      hint: 'To\'lanmagan hisob bor',
    );
  }
  if (s.isAtRisk) {
    return (
      text: 'Davomat past',
      tone: StatusTone.warning,
      hint:
          'Oxirgi 10 darsda davomat ${ratePercent(s.attendanceRate)} '
          '(75% dan past). Qarzi yo\'q.',
    );
  }
  return (
    text: 'To\'langan',
    tone: StatusTone.ok,
    hint: 'Qarzi yo\'q, davomati yaxshi',
  );
}

/// "92%" or "–" when no lesson was marked yet.
String ratePercent(double? rate) =>
    rate == null ? '–' : '${(rate * 100).round()}%';

/// "Nilufar I. · Du, Chor, Ju · 10:30" under a group in the table.
String groupSubtitle(StudentGroupRef g) {
  final teacher = g.teacherName == null ? null : shortName(g.teacherName!);
  final when = g.schedule.isEmpty ? null : slotsLabel(g.schedule);
  return [?teacher, ?when].join(' · ');
}

/// "Nilufar Ismoilova" -> "Nilufar I.".
String shortName(String full) {
  final parts = full.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) return full.trim();
  return '${parts.first} ${parts[1][0]}.';
}

/// "Bugun", "Kecha" or "5-sentyabr".
String dayLabel(DateTime at, DateTime now) {
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(at.year, at.month, at.day)).inDays;
  return switch (days) {
    0 => 'Bugun',
    1 => 'Kecha',
    _ => dayMonth(at),
  };
}

String methodLabel(String? method) => switch (method) {
  'card' => 'Karta',
  'click_payme' => 'Click / Payme',
  _ => 'Naqd',
};

String attendanceLabel(String status) => switch (status) {
  'present' => 'Keldi',
  'late' => 'Kechikdi',
  'absent' => 'Kelmadi',
  _ => 'Sababli',
};

StatusTone attendanceTone(String status) => switch (status) {
  'present' => StatusTone.ok,
  'late' => StatusTone.warning,
  'absent' => StatusTone.danger,
  _ => StatusTone.neutral,
};

/// "2 kun kechikdi" -- how long the oldest unpaid charge has been due.
String overdueText(int days) =>
    days <= 0 ? 'Bugun muddat' : '$days kun kechikdi';

/// "14-oktyabr".
String dueText(DateTime? since) => since == null ? '' : dayMonth(since);
