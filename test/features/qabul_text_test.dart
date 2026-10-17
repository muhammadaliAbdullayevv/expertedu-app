import 'package:expert_edu_center/core/widgets/status_chip.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_models.dart';
import 'package:expert_edu_center/features/admissions/presentation/qabul_text.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BoardLead lead(
  String v2, {
  DateTime? changed,
  DateTime? nextTrial,
  DateTime? lastTrial,
  DateTime? enrolled,
  DateTime? closed,
  String? lost,
}) => BoardLead(
  id: 1,
  fullName: 'Zilola Nurmatova',
  phone: '998900000007',
  stage: 'new',
  v2Stage: v2,
  createdAt: DateTime(2026, 10, 1),
  stageChangedAt: changed ?? DateTime(2026, 10, 17, 9),
  nextTrialAt: nextTrial,
  lastTrialAt: lastTrial,
  enrolledAt: enrolled,
  closedAt: closed,
  lostReason: lost,
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

  test('the Sinov darsi column: badge only for today and tomorrow', () {
    final tomorrow = lead(BoardStage.trial, nextTrial: DateTime(2026, 10, 18, 10, 30));
    expect(stageBadge(tomorrow, now)?.text, 'Ertaga sinov darsi');
    expect(stageBadge(tomorrow, now)?.tone, StatusTone.warning);
    expect(cardFooter(tomorrow, now), 'Ertaga 10:30');
    final later = lead(BoardStage.trial, nextTrial: DateTime(2026, 10, 20, 15));
    expect(stageBadge(later, now), isNull);
    expect(cardFooter(later, now), '20-oktyabr 15:00');
    expect(stageBadge(lead(BoardStage.trial, nextTrial: DateTime(2026, 10, 17, 18)), now)?.text, 'Bugun sinov darsi');
  });

  test('To\'lov kutilmoqda says how long since the trial', () {
    final waiting = lead(BoardStage.awaitingDecision, lastTrial: DateTime(2026, 10, 15, 10));
    expect(stageBadge(waiting, now)?.text, 'Javob kutilmoqda');
    expect(stageBadge(waiting, now)?.tone, StatusTone.danger);
    expect(cardFooter(waiting, now), 'Sinovdan 2 kun keyin');
    expect(cardFooter(lead(BoardStage.awaitingDecision, lastTrial: DateTime(2026, 10, 17, 9)), now), 'Sinovdan keyin bugun');
  });

  test('footers of the other columns', () {
    expect(cardFooter(lead(BoardStage.newLead, changed: DateTime(2026, 10, 17, 8)), now), 'Bugun');
    expect(cardFooter(lead(BoardStage.contacted, changed: DateTime(2026, 10, 15)), now), '2 kun');
    expect(cardFooter(lead(BoardStage.joined, enrolled: DateTime(2026, 10, 12)), now), '12-oktyabr');
    expect(cardFooter(lead(BoardStage.rejected, closed: DateTime(2026, 10, 10), lost: 'Qimmat'), now), '10-oktyabr · Qimmat');
    expect(cardFooter(lead(BoardStage.rejected, closed: DateTime(2026, 10, 10)), now), '10-oktyabr');
    expect(stageBadge(lead(BoardStage.newLead), now), isNull);
  });

  test('a group\'s days and times', () {
    expect(slotsLabel([slot(5, 10, 30), slot(1, 10, 30), slot(3, 10, 30)]), 'Du, Chor, Ju · 10:30');
    expect(slotsLabel([slot(1, 9), slot(3, 18)]), 'Du 09:00, Chor 18:00');
    expect(slotsLabel(const []), 'Jadval kiritilmagan');
    expect(daysLabel([5, 1, 3, 3]), 'Du, Chor, Ju');
    expect(firstTimeRange([slot(3, 9), slot(1, 9)]), '09:00 – 10:30');
  });

  GroupMatch group({String mode = 'fixed_day', bool prorate = true, DateTime? start}) => GroupMatch(
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
    expect(billingNote(group(start: DateTime(2026, 9, 1)), now),
        'Guruh 1-sentyabrda boshlangan. Yangi o\'quvchi qo\'shilishi mumkin; to\'lov qolgan kunlarga hisoblanadi.');
    expect(billingNote(group(prorate: false, start: DateTime(2026, 9, 1)), now), contains('birinchi oy to\'liq narxda'));
    expect(billingNote(group(mode: 'student_anniversary'), now), 'Har bir o\'quvchi guruhga qo\'shilgan kunida to\'laydi.');
    expect(billingNote(group(start: DateTime(2026, 11, 3)), now), startsWith('Guruh 3-noyabrda boshlanadi.'));
  });

  test('small formatters', () {
    expect(initials('Madina Karimova'), 'MK');
    expect(initials('abdd'), 'A');
    expect(initials(null), '–');
    expect(seatsLabel(1), '1 bo\'sh o\'rin');
    expect(seatsLabel(0), 'To\'lgan');
    expect(seatsLabel(null), 'Cheklanmagan');
  });

  test('the board model keeps the server\'s counts, not the cards it was sent', () {
    final board = AdmissionsBoard.fromJson({
      'kpi': {
        'date_from': '2026-10-01', 'date_to': '2026-10-17', 'leads': 12, 'trial_people': 6, 'joined': 4,
        'rejected': 1, 'cohort_size': 12, 'cohort_joined': 4, 'conversion_rate': 0.3333,
      },
      'columns': [
        for (final (k, n) in [('new', 2), ('contacted', 3), ('trial', 2), ('awaiting_decision', 1), ('joined', 4), ('later', 1), ('rejected', 1)])
          {'key': k, 'label': k, 'count': n, 'leads': []},
      ],
    });
    // Open = everything but Guruhga qo'shildi and Rad etildi.
    expect(board.openLeads, 2 + 3 + 2 + 1 + 1);
    expect(board.column('joined').count, 4);
  });
}
