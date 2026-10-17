import '../../timetable/data/timetable_models.dart';
import '../data/qabul_models.dart';

/// The words on the Qabul board and finder -- all plain functions of the
/// data and "now", so they can be tested without drawing anything.

/// Weekday names as the design shows them, indexed by ISO weekday (1 = Monday).
const List<String> weekdayAbbr = <String>[
  '',
  'Du',
  'Se',
  'Chor',
  'Pay',
  'Ju',
  'Sha',
  'Yak',
];

const List<String> _months = <String>[
  '',
  'yanvar',
  'fevral',
  'mart',
  'aprel',
  'may',
  'iyun',
  'iyul',
  'avgust',
  'sentyabr',
  'oktyabr',
  'noyabr',
  'dekabr',
];

String _two(int n) => n.toString().padLeft(2, '0');

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whole calendar days from [from] to [now].
int daysSince(DateTime from, DateTime now) =>
    _day(now).difference(_day(from)).inDays;

/// "Bugun", "1 kun", "4 kun".
String ageText(DateTime since, DateTime now) {
  final days = daysSince(since, now);
  return days <= 0 ? 'Bugun' : '$days kun';
}

/// "12-oktyabr".
String dayMonth(DateTime d) => '${d.day}-${_months[d.month]}';

/// "Du, 20-okt".
String weekdayDate(DateTime d) =>
    '${weekdayAbbr[d.weekday]}, ${d.day}-${_months[d.month].substring(0, 3)}';

String clock(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// "Bugun 10:30", "Ertaga 10:30", "20-oktyabr 15:00".
String when(DateTime at, DateTime now) {
  final days = _day(at).difference(_day(now)).inDays;
  final label = switch (days) {
    0 => 'Bugun',
    1 => 'Ertaga',
    _ => dayMonth(at),
  };
  return '$label ${clock(at)}';
}

/// "Du, Chor, Ju".
String daysLabel(Iterable<int> weekdays) =>
    (weekdays.toSet().toList()..sort()).map((d) => weekdayAbbr[d]).join(', ');

/// "Du, Chor, Ju · 10:30" -- or each day with its own time when they differ.
String slotsLabel(List<ScheduleSlot> slots) {
  if (slots.isEmpty) return 'Jadval kiritilmagan';
  final ordered = [...slots]..sort((a, b) => a.weekday.compareTo(b.weekday));
  final times = {for (final s in ordered) hhmm(s.startsAt)};
  if (times.length == 1) {
    return '${daysLabel(ordered.map((s) => s.weekday))} · ${times.single}';
  }
  return ordered
      .map((s) => '${weekdayAbbr[s.weekday]} ${hhmm(s.startsAt)}')
      .join(', ');
}

/// "09:00 – 10:30" for the first slot.
String firstTimeRange(List<ScheduleSlot> slots) {
  if (slots.isEmpty) return '';
  final s = ([...slots]..sort((a, b) => a.weekday.compareTo(b.weekday))).first;
  return '${hhmm(s.startsAt)} – ${hhmm(s.endsAt)}';
}

/// The note under a group in the finder: when it started and how the first
/// payment works.
String billingNote(GroupMatch group, DateTime now) {
  final start = group.startDate;
  final started = start == null
      ? null
      : (!_day(start).isAfter(_day(now))
            ? 'Guruh ${dayMonth(start)}da boshlangan.'
            : 'Guruh ${dayMonth(start)}da boshlanadi.');
  final money = group.isAnniversary
      ? 'Har bir o\'quvchi guruhga qo\'shilgan kunida to\'laydi.'
      : group.prorateFirstPeriod
      ? 'Yangi o\'quvchi qo\'shilishi mumkin; to\'lov qolgan kunlarga hisoblanadi.'
      : 'Yangi o\'quvchi qo\'shilishi mumkin; birinchi oy to\'liq narxda.';
  return [?started, money].join(' ');
}

String initials(String? name) {
  final parts = (name ?? '')
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty);
  final letters = parts
      .take(2)
      .map((p) => String.fromCharCode(p.runes.first).toUpperCase())
      .join();
  return letters.isEmpty ? '–' : letters;
}

/// The seats chip: "2 bo'sh o'rin", "To'lgan", "Cheklanmagan".
String seatsLabel(int? free) => switch (free) {
  null => 'Cheklanmagan',
  0 => 'To\'lgan',
  _ => '$free bo\'sh o\'rin',
};

/// "Ingliz tili, Beginner A" -- the group's name, with its subject in front
/// unless the name already says it.
String groupTitle(GroupMatch g) {
  final subject = g.subjectName;
  if (subject == null || g.name.toLowerCase().contains(subject.toLowerCase())) {
    return g.name;
  }
  return '$subject, ${g.name}';
}
