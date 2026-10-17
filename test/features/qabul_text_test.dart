import 'package:expert_edu_center/features/admissions/data/qabul_models.dart';
import 'package:expert_edu_center/features/admissions/presentation/qabul_text.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GroupMatch match({required String name, String? subject}) => GroupMatch(
  groupId: 1,
  name: name,
  subjectName: subject,
  feeAmount: 310000,
  billingMode: 'fixed_day',
  billingDay: 1,
  prorateFirstPeriod: true,
  enrolled: 0,
  slots: const [],
  matchedDays: 0,
  totalDays: 0,
);

ScheduleSlot slot(int weekday, int h, [int m = 0]) => ScheduleSlot(
  weekday: weekday,
  startsAt: TimeOfDay(hour: h, minute: m),
  endsAt: TimeOfDay(hour: h + 1, minute: m + 30),
);

void main() {
  final now = DateTime(2026, 10, 17, 15, 20);

  test('how old a card is', () {
    expect(ageText(DateTime(2026, 10, 17, 1), now), 'Bugun');
    expect(ageText(DateTime(2026, 10, 16, 23, 59), now), '1 kun');
    expect(ageText(DateTime(2026, 10, 13), now), '4 kun');
    // The future never shows a negative number.
    expect(ageText(DateTime(2026, 10, 20), now), 'Bugun');
  });

  test('dates read the way the design writes them', () {
    expect(dayMonth(DateTime(2026, 10, 12)), '12-oktyabr');
    // 17 October 2026 is a Saturday.
    expect(weekdayDate(DateTime(2026, 10, 17)), 'Sha, 17-okt');
    expect(weekdayDate(DateTime(2026, 10, 19)), 'Du, 19-okt');
    expect(weekdayDate(DateTime(2026, 10, 22)), 'Pay, 22-okt');
    expect(when(DateTime(2026, 10, 17, 18), now), 'Bugun 18:00');
    expect(when(DateTime(2026, 10, 18, 10, 30), now), 'Ertaga 10:30');
    expect(when(DateTime(2026, 10, 20, 15), now), '20-oktyabr 15:00');
  });

  test('a group\'s days and times', () {
    expect(
      slotsLabel([slot(5, 10, 30), slot(1, 10, 30), slot(3, 10, 30)]),
      'Du, Chor, Ju · 10:30',
    );
    expect(slotsLabel([slot(1, 9), slot(3, 18)]), 'Du 09:00, Chor 18:00');
    expect(slotsLabel(const []), 'Jadval kiritilmagan');
    expect(daysLabel([5, 1, 3, 3]), 'Du, Chor, Ju');
    expect(firstTimeRange([slot(3, 9), slot(1, 9)]), '09:00 – 10:30');
  });

  GroupMatch group({
    String mode = 'fixed_day',
    bool prorate = true,
    DateTime? start,
  }) => GroupMatch(
    groupId: 1,
    name: 'Beginner A',
    feeAmount: 310000,
    billingMode: mode,
    billingDay: mode == 'fixed_day' ? 1 : null,
    prorateFirstPeriod: prorate,
    startDate: start,
    enrolled: 14,
    freeSeats: 2,
    capacity: 16,
    slots: const [],
    matchedDays: 3,
    totalDays: 3,
  );

  test('the billing note under a group in the finder', () {
    expect(
      billingNote(group(start: DateTime(2026, 9, 1)), now),
      'Guruh 1-sentyabrda boshlangan. Yangi o\'quvchi qo\'shilishi mumkin; to\'lov qolgan kunlarga hisoblanadi.',
    );
    expect(
      billingNote(group(prorate: false, start: DateTime(2026, 9, 1)), now),
      contains('birinchi oy to\'liq narxda'),
    );
    expect(
      billingNote(group(mode: 'student_anniversary'), now),
      'Har bir o\'quvchi guruhga qo\'shilgan kunida to\'laydi.',
    );
    expect(
      billingNote(group(start: DateTime(2026, 11, 3)), now),
      startsWith('Guruh 3-noyabrda boshlanadi.'),
    );
  });

  test('small formatters', () {
    expect(initials('Madina Karimova'), 'MK');
    expect(initials('abdd'), 'A');
    expect(initials(null), '–');
    expect(seatsLabel(1), '1 bo\'sh o\'rin');
    expect(seatsLabel(0), 'To\'lgan');
    expect(seatsLabel(null), 'Cheklanmagan');
  });

  test('a group\'s title carries its subject unless the name already does', () {
    expect(
      groupTitle(match(name: 'Beginner A', subject: 'Ingliz tili')),
      'Ingliz tili, Beginner A',
    );
    expect(
      groupTitle(match(name: 'Ingliz tili 1', subject: 'Ingliz tili')),
      'Ingliz tili 1',
    );
    expect(groupTitle(match(name: 'A1', subject: null)), 'A1');
  });
}
