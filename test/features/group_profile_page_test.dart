import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/core/formatters/currency_formatter.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_repository.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/billing/data/transactions_repository.dart';
import 'package:expert_edu_center/features/enrollments/data/enrollments_repository.dart';
import 'package:expert_edu_center/features/groups/data/group_profile_models.dart';
import 'package:expert_edu_center/features/groups/data/groups_repository.dart';
import 'package:expert_edu_center/features/groups/presentation/group_detail_screen.dart';
import 'package:expert_edu_center/features/groups/presentation/groups_breadcrumb.dart';
import 'package:expert_edu_center/features/students/data/student_models.dart';
import 'package:expert_edu_center/features/students/data/students_repository.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';
import 'students_page_test.dart' show Rig, profile;

String plain(String v) => v.replaceAll(RegExp(r'[  ]'), ' ');

ScheduleSlot slot(int weekday) => ScheduleSlot(
  weekday: weekday,
  startsAt: const TimeOfDay(hour: 9, minute: 0),
  endsAt: const TimeOfDay(hour: 10, minute: 30),
);

Group group({
  String mode = 'fixed_day',
  int? billingDay = 15,
  int? capacity = 16,
}) => Group(
  id: 1,
  subjectId: 10,
  name: 'Beginner A',
  teacherName: 'Madina Karimova',
  feeAmount: 310000,
  billingMode: mode,
  billingDay: billingDay,
  capacity: capacity,
  isActive: true,
  level: 'Beginner',
  startDate: DateTime(2026, 9, 1),
);

GroupProfileData data({
  Group? g,
  GroupTeacher? teacher = const GroupTeacher(
    id: 7,
    fullName: 'Madina Karimova',
    phone: '998901110001',
  ),
  List<ScheduleSlot>? schedule,
  int students = 14,
  int? capacity = 16,
  int? free = 2,
  int paid = 9,
  int unpaid = 5,
  int expected = 8100000,
  int collected = 5200000,
  int debt = 2900000,
  DateTime? nextBilling,
  bool perStudentBilling = false,
  List<GroupWaiting> waiting = const [],
  ProfileAttendance attendance = const ProfileAttendance(
    present: 70,
    late: 6,
    absent: 14,
    excused: 2,
    total: 92,
    rate: 0.82,
  ),
}) => GroupProfileData(
  group: g ?? group(),
  subjectName: 'Ingliz tili',
  teacher: teacher,
  schedule: schedule ?? [slot(1), slot(3), slot(5)],
  studentCount: students,
  capacity: capacity,
  freeSeats: free,
  paidCount: paid,
  unpaidCount: unpaid,
  attendance: attendance,
  expected: expected,
  collected: collected,
  debtTotal: debt,
  nextBillingDate: perStudentBilling
      ? null
      : (nextBilling ?? DateTime(2026, 11, 15)),
  nextLessons: [DateTime(2026, 10, 19, 9), DateTime(2026, 10, 21, 9)],
  waiting: waiting,
);

class FakeGroups implements GroupsRepository {
  FakeGroups(this.profileData, {List<RosterEntry>? roster})
    : rosterList = roster ?? defaultRoster;

  GroupProfileData profileData;
  final List<RosterEntry> rosterList;
  int profileCalls = 0;

  static final defaultRoster = [
    RosterEntry(
      enrollmentId: 1,
      studentId: 5,
      studentFullName: 'Yangi Odam',
      studentPhone: '998900000005',
      joinedAt: DateTime.now(),
      status: 'active',
      balance: 0,
      isNew: true,
    ),
    RosterEntry(
      enrollmentId: 2,
      studentId: 6,
      studentFullName: 'Eski Odam',
      studentPhone: '998900000006',
      joinedAt: DateTime(2026, 1, 5),
      status: 'active',
      balance: 100000,
    ),
  ];

  @override
  Future<GroupProfileData> profile(int groupId) async {
    profileCalls++;
    return profileData;
  }

  @override
  Future<List<RosterEntry>> roster(
    int groupId, {
    bool includeWithdrawn = false,
  }) async => rosterList;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAdmissions implements AdmissionsRepository {
  @override
  Future<List<Group>> groups() async => [group()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Rig rig() => Rig(
  profiles: {
    5: profile(5, 'Yangi Odam', balance: 0),
    6: profile(6, 'Eski Odam'),
  },
);

Widget app(FakeGroups groups, Rig rig, {Widget? home}) => ProviderScope(
  overrides: [
    groupsRepositoryProvider.overrideWithValue(groups),
    studentsRepositoryProvider.overrideWithValue(rig.students),
    transactionsRepositoryProvider.overrideWithValue(rig.transactions),
    enrollmentsRepositoryProvider.overrideWithValue(rig.enrollments),
    qabulRepositoryProvider.overrideWithValue(rig.qabul),
    admissionsRepositoryProvider.overrideWithValue(FakeAdmissions()),
  ],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body:
          home ?? GroupDetailScreen(group: group(), courseName: 'Ingliz tili'),
    ),
  ),
);

Future<void> pump(
  WidgetTester tester,
  Widget widget, {
  Size size = const Size(1500, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

Text text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key)));

void main() {
  setUpAll(loadAppFonts);

  testWidgets(
    'the page names the group, its course and level, and how full it is',
    (tester) async {
      await pump(tester, app(FakeGroups(data()), rig()));
      expect(text(tester, 'group-title').data, 'Beginner A');
      expect(find.text('Guruhlar'), findsOneWidget);
      expect(find.text('Ingliz tili'), findsOneWidget); // the course, a button
      expect(find.text('Beginner'), findsOneWidget);
      expect(find.text('2 bo\'sh o\'rin'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-add-student')), findsOneWidget);
    },
  );

  testWidgets(
    'the four numbers: students, who paid, attendance, collected of expected',
    (tester) async {
      await pump(tester, app(FakeGroups(data()), rig()));
      expect(text(tester, 'stat-students-value').data, '14 / 16');
      expect(find.text('2 ta bo\'sh'), findsOneWidget);
      expect(text(tester, 'stat-paid').data, '9');
      expect(text(tester, 'stat-unpaid').data, '5');
      expect(text(tester, 'stat-attendance-value').data, '82%');
      expect(
        find.textContaining('92 ta belgi · 14 ta kelmagan'),
        findsOneWidget,
      );
      expect(
        text(tester, 'stat-collected-value').data,
        '${CurrencyFormatter.compact(5200000)} / ${CurrencyFormatter.compact(8100000)}',
      );
      expect(
        plain(text(tester, 'stat-debt').data!),
        'Jami qarz: 2 900 000 so\'m',
      );
    },
  );

  testWidgets(
    'teacher, days and times, billing day, price, start and the next lessons',
    (tester) async {
      await pump(tester, app(FakeGroups(data()), rig()));
      expect(text(tester, 'group-teacher').data, 'Madina Karimova');
      expect(find.text('+998 90 111 00 01'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-schedule')), findsOneWidget);
      expect(find.text('09:00–10:30'), findsOneWidget);
      expect(find.text('Har oyning 15-kuni'), findsOneWidget);
      expect(find.text('Keyingisi: 15-noyabr'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && plain(w.data ?? '') == '310 000 so\'m',
        ),
        findsOneWidget,
      );
      expect(find.text('1-sentyabr'), findsOneWidget);
      expect(find.textContaining('19-okt 09:00'), findsOneWidget);
    },
  );

  testWidgets(
    'a group with no teacher, no schedule and a per-student billing day says so',
    (tester) async {
      final d = data(
        g: group(mode: 'student_anniversary', billingDay: null, capacity: null),
        teacher: null,
        schedule: const [],
        capacity: null,
        free: null,
        perStudentBilling: true,
      );
      await pump(tester, app(FakeGroups(d), rig()));
      expect(text(tester, 'group-teacher').data, 'Biriktirilmagan');
      expect(find.text('Jadval kiritilmagan'), findsOneWidget);
      expect(find.text('Har o\'quvchi o\'z kunida to\'laydi'), findsOneWidget);
      expect(text(tester, 'stat-students-value').data, '14');
      expect(find.text('O\'rin cheklanmagan'), findsOneWidget);
    },
  );

  testWidgets(
    'a full group that took one more shows more than its capacity and stays full',
    (tester) async {
      final d = data(students: 17, capacity: 16, free: 0);
      await pump(tester, app(FakeGroups(d), rig()));
      expect(text(tester, 'stat-students-value').data, '17 / 16');
      expect(find.text('To\'lgan'), findsWidgets);
      expect(find.textContaining('bo\'sh o\'rin'), findsNothing);
    },
  );

  testWidgets(
    'nothing collected or expected yet shows an empty bar, not an error',
    (tester) async {
      final d = data(
        students: 0,
        paid: 0,
        unpaid: 0,
        expected: 0,
        collected: 0,
        debt: 0,
        attendance: const ProfileAttendance(),
      );
      await pump(tester, app(FakeGroups(d, roster: const []), rig()));
      expect(text(tester, 'stat-attendance-value').data, '–');
      expect(find.text('Dars belgilanmagan'), findsOneWidget);
      expect(text(tester, 'stat-debt').data, 'Qarz yo\'q');
      expect(find.text('Hali o\'quvchilar yo\'q.'), findsOneWidget);
    },
  );

  testWidgets(
    'people waiting for the group are listed on top, marked, and are not students',
    (tester) async {
      final d = data(
        waiting: [
          GroupWaiting(
            leadId: 71,
            fullName: 'Kutuvchi Bir',
            phone: '998901110061',
            createdAt: DateTime.now(),
          ),
          GroupWaiting(
            leadId: 72,
            fullName: 'Kutuvchi Ikki',
            phone: '998901110062',
            createdAt: DateTime.now(),
            trialAt: DateTime(2026, 10, 20, 9),
          ),
        ],
      );
      await pump(tester, app(FakeGroups(d), rig()));
      expect(find.byKey(const ValueKey('group-waiting')), findsOneWidget);
      expect(
        find.textContaining('2 kishi · o\'quvchilar soniga kirmaydi'),
        findsOneWidget,
      );
      expect(find.text('Hali o\'quvchi emas'), findsNWidgets(2));
      expect(find.textContaining('Sinov: '), findsOneWidget);
      // The student count and the roster are untouched by them.
      expect(text(tester, 'stat-students-value').data, '14 / 16');
      expect(find.byKey(const ValueKey('roster-5')), findsOneWidget);
      expect(find.byKey(const ValueKey('roster-71')), findsNothing);
      // They sit above the students.
      final waitingTop = tester
          .getTopLeft(find.byKey(const ValueKey('group-waiting')))
          .dy;
      final rosterTop = tester
          .getTopLeft(find.byKey(const ValueKey('roster-5')))
          .dy;
      expect(waitingTop, lessThan(rosterTop));
      // "O'quvchi qilish" opens the enrollment dialog for that person.
      await tester.tap(find.byKey(const ValueKey('make-student-71')));
      await tester.pumpAndSettle();
      expect(find.text('Kutuvchi Bir · Beginner A'), findsOneWidget);
    },
  );

  testWidgets('no waiting people, no waiting section', (tester) async {
    await pump(tester, app(FakeGroups(data()), rig()));
    expect(find.byKey(const ValueKey('group-waiting')), findsNothing);
  });

  testWidgets(
    'the breadcrumb goes back: the course returns to its groups, Guruhlar to the start',
    (tester) async {
      final groups = FakeGroups(data());
      final navigator = GlobalKey<NavigatorState>();
      await pump(
        tester,
        ProviderScope(
          overrides: [
            groupsRepositoryProvider.overrideWithValue(groups),
            studentsRepositoryProvider.overrideWithValue(rig().students),
            transactionsRepositoryProvider.overrideWithValue(
              rig().transactions,
            ),
            enrollmentsRepositoryProvider.overrideWithValue(rig().enrollments),
            qabulRepositoryProvider.overrideWithValue(rig().qabul),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            theme: AppTheme.light(),
            home: const Scaffold(body: Text('Fanlar ro\'yxati')),
          ),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: GroupsBreadcrumb(course: 'Ingliz tili')),
        ),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: GroupDetailScreen(group: group(), courseName: 'Ingliz tili'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('crumb-course')));
      await tester.pumpAndSettle();
      expect(find.byType(GroupDetailScreen), findsNothing);
      expect(find.byKey(const ValueKey('crumb-root')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('crumb-root')));
      await tester.pumpAndSettle();
      expect(find.text('Fanlar ro\'yxati'), findsOneWidget);
    },
  );

  testWidgets(
    'a student\'s profile opens beside the list, inside the group page',
    (tester) async {
      final r = rig();
      await pump(tester, app(FakeGroups(data()), r));
      expect(find.byKey(const ValueKey('panel-name')), findsOneWidget);
      await tester.tap(find.text('Eski Odam'));
      await tester.pumpAndSettle();
      expect(r.students.profileCalls.last, 6);
      expect(find.byType(GroupDetailScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('panel-pay')), findsOneWidget);
      // A payment taken there refreshes the group's numbers.
      final groups = FakeGroups(data());
      final before = groups.profileCalls;
      expect(before, 0);
    },
  );

  testWidgets('the profile opened from a group is that group\'s part only', (
    tester,
  ) async {
    await pump(tester, app(FakeGroups(data()), rig()));
    // The chip says which group the panel is showing.
    expect(find.byKey(const ValueKey('panel-scope')), findsOneWidget);
    expect(find.textContaining('Guruh: '), findsOneWidget);
  });

  testWidgets('the student list has no "remove" button any more', (
    tester,
  ) async {
    await pump(tester, app(FakeGroups(data()), rig()));
    expect(find.byIcon(Icons.person_remove_outlined), findsNothing);
    expect(find.byTooltip('Chiqarish'), findsNothing);
  });

  testWidgets(
    'removing is in the profile\'s three dots: this group, not archive',
    (tester) async {
      await pump(tester, app(FakeGroups(data()), rig()));
      await tester.tap(find.byKey(const ValueKey('panel-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-remove-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-archive')), findsNothing);
    },
  );

  testWidgets('a payment taken on the profile reloads the group page', (
    tester,
  ) async {
    final groups = FakeGroups(data());
    final r = rig();
    await pump(tester, app(groups, r));
    final before = groups.profileCalls;
    await tester.tap(find.byKey(const ValueKey('panel-pay')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('payment-amount')),
      '1000',
    );
    await tester.tap(find.byKey(const ValueKey('payment-save')));
    await tester.pumpAndSettle();
    expect(r.transactions.payments, hasLength(1));
    expect(groups.profileCalls, greaterThan(before));
  });

  testWidgets('in a narrow window the profile opens over the list instead', (
    tester,
  ) async {
    await pump(
      tester,
      app(FakeGroups(data()), rig()),
      size: const Size(900, 900),
    );
    expect(find.byKey(const ValueKey('panel-name')), findsNothing);
    await tester.tap(find.text('Eski Odam'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel-name')), findsOneWidget);
  });
}
