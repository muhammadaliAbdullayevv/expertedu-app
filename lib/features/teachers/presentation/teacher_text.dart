import '../../../core/formatters/currency_formatter.dart';
import '../data/teachers_repository.dart';

/// The tabs of the teachers page.
enum TeacherTab {
  active('Faol'),
  free('Guruhsiz'),
  archive('Arxiv');

  const TeacherTab(this.label);
  final String label;
}

bool _inTab(Teacher t, TeacherTab tab) => switch (tab) {
  TeacherTab.active => t.isActive,
  TeacherTab.free => t.isActive && (t.groupCount ?? 0) == 0,
  TeacherTab.archive => !t.isActive,
};

List<Teacher> filterTeachers(List<Teacher> all, {required TeacherTab tab}) => [
  for (final t in all)
    if (_inTab(t, tab)) t,
];

Map<TeacherTab, int> teacherTabCounts(List<Teacher> all) => {
  for (final tab in TeacherTab.values)
    tab: all.where((t) => _inTab(t, tab)).length,
};

/// "40%" / "37,5%" -- whole percents without the decimals.
String percentText(double percent) {
  final whole = percent == percent.roundToDouble();
  return '${whole ? percent.round() : percent.toStringAsFixed(1).replaceAll('.', ',')}%';
}

/// How someone is paid, in one phrase: "40%", "Qat'iy 3 000 000 so'm / oy",
/// or "Belgilanmagan".
String ruleText(String? method, double? percent, int? fixed) {
  if (method == 'percent' && percent != null) return percentText(percent);
  if (method == 'fixed' && fixed != null) {
    return 'Qat\'iy ${CurrencyFormatter.format(fixed)} / oy';
  }
  return 'Belgilanmagan';
}

/// "12 o'quvchi" / "12 / 15 o'quvchi".
String studentsText(int count, int? capacity) =>
    capacity == null ? '$count o\'quvchi' : '$count / $capacity o\'quvchi';
