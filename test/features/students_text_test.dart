import 'package:expert_edu_center/core/widgets/status_chip.dart';
import 'package:expert_edu_center/features/students/data/student_models.dart';
import 'package:expert_edu_center/features/students/presentation/student_text.dart';
import 'package:flutter_test/flutter_test.dart';

StudentRow row(
  int id, {
  bool active = true,
  bool archived = false,
  bool debtor = false,
  bool atRisk = false,
  bool isNew = false,
  int balance = 0,
  List<StudentGroupRef> groups = const [],
}) => StudentRow(
  id: id,
  fullName: 'Talaba $id',
  phone: '99890000000$id',
  balance: balance,
  createdAt: DateTime(2026, 10, 1),
  groups: groups,
  isActive: active,
  isArchived: archived,
  isDebtor: debtor,
  isAtRisk: atRisk,
  isNew: isNew,
);

const english = StudentGroupRef(
  groupId: 1,
  name: 'Beginner A',
  subjectId: 10,
  subjectName: 'Ingliz tili',
  teacherId: 100,
  teacherName: 'Madina Karimova',
);
const math = StudentGroupRef(
  groupId: 2,
  name: 'Matematika 9',
  subjectId: 20,
  subjectName: 'Matematika',
  teacherId: 200,
  teacherName: 'Jasur Rahimov',
);

void main() {
  final rows = [
    row(1, debtor: true, balance: 390000, groups: [english], isNew: true),
    row(2, atRisk: true, groups: [english, math]),
    row(3, groups: [math]),
    row(4, active: false, archived: true),
    row(5, debtor: true, balance: 100000, groups: [math]),
    // Between groups, not archived.
    row(6, active: false),
    // Archived, but still owes.
    row(7, active: false, archived: true, debtor: true, balance: 50000),
  ];

  test('"Hammasi" is everyone not archived and "Arxiv" only the archived', () {
    // 6 is between groups: still in "Hammasi", not in the archive.
    expect(filterStudents(rows).map((s) => s.id), [1, 2, 3, 5, 6]);
    expect(filterStudents(rows, tab: StudentTab.archive).map((s) => s.id), [
      4,
      7,
    ]);
  });

  test(
    'each tab holds what its name says, and the counts agree with the people',
    () {
      // An archived student who still owes stays where he can be collected from.
      expect(filterStudents(rows, tab: StudentTab.debtors).map((s) => s.id), [
        1,
        5,
        7,
      ]);
      expect(filterStudents(rows, tab: StudentTab.atRisk).map((s) => s.id), [
        2,
      ]);
      expect(filterStudents(rows, tab: StudentTab.fresh).map((s) => s.id), [1]);
      final counts = tabCounts(rows);
      for (final tab in StudentTab.values) {
        expect(
          counts[tab],
          filterStudents(rows, tab: tab).length,
          reason: '$tab',
        );
      }
    },
  );

  test('Fan, Guruh and O\'qituvchi narrow the table, alone or together', () {
    expect(filterStudents(rows, subjectId: 10).map((s) => s.id), [1, 2]);
    expect(filterStudents(rows, groupId: 2).map((s) => s.id), [2, 3, 5]);
    expect(filterStudents(rows, teacherId: 200).map((s) => s.id), [2, 3, 5]);
    expect(
      filterStudents(rows, subjectId: 10, teacherId: 200).map((s) => s.id),
      [2],
    );
    expect(
      filterStudents(
        rows,
        tab: StudentTab.debtors,
        groupId: 2,
      ).map((s) => s.id),
      [5],
    );
  });

  test('balance reads −390 000 owed, 0, +120 000 paid ahead', () {
    // The thousands are grouped with the app's own (non-breaking) space.
    String plain(String v) => v.replaceAll(RegExp(r'[\u00A0\u202F]'), ' ');
    expect(plain(signedBalance(390000)), '−390 000');
    expect(signedBalance(0), '0');
    expect(plain(signedBalance(-120000)), '+120 000');
  });

  test('the status chip', () {
    expect(statusOf(row(1, debtor: true)).text, 'Qarzdor');
    expect(statusOf(row(1, debtor: true)).tone, StatusTone.danger);
    expect(statusOf(row(2, atRisk: true)).text, 'Davomat past');
    // It says it is about lessons, and that there is no debt.
    expect(statusOf(row(2, atRisk: true)).hint, contains('Qarzi yo\'q'));
    expect(statusOf(row(3)).text, 'To\'langan');
    expect(statusOf(row(4, active: false, archived: true)).text, 'Arxiv');
    expect(statusOf(row(6, active: false)).text, 'Guruhsiz');
    // Debt is never hidden, even for someone archived or between groups.
    expect(
      statusOf(row(7, active: false, archived: true, debtor: true)).text,
      'Arxiv · qarz',
    );
    expect(
      statusOf(row(8, active: false, debtor: true)).text,
      'Guruhsiz · qarz',
    );
    // A debt outweighs the risk.
    expect(statusOf(row(5, debtor: true, atRisk: true)).text, 'Qarzdor');
  });

  test('small words', () {
    expect(ratePercent(0.923), '92%');
    expect(ratePercent(null), '–');
    expect(shortName('Nilufar Ismoilova'), 'Nilufar I.');
    expect(shortName('Nilufar'), 'Nilufar');
    expect(overdueText(3), '3 kun kechikdi');
    expect(overdueText(0), 'Bugun muddat');
    final now = DateTime(2026, 10, 18, 15);
    expect(dayLabel(DateTime(2026, 10, 18, 1), now), 'Bugun');
    expect(dayLabel(DateTime(2026, 10, 17, 23), now), 'Kecha');
    expect(dayLabel(DateTime(2026, 10, 5), now), '5-oktyabr');
    expect(methodLabel('card'), 'Karta');
    expect(methodLabel(null), 'Naqd');
    expect(attendanceLabel('absent'), 'Kelmadi');
  });

  test('a group under a student shows the teacher and the days', () {
    expect(groupSubtitle(english), 'Madina K.');
  });
}
