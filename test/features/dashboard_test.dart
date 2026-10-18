import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/branches/application/branch_view.dart';
import 'package:expert_edu_center/features/branches/data/branches_repository.dart';
import 'package:expert_edu_center/features/dashboard/data/dashboard_repository.dart';
import 'package:expert_edu_center/features/dashboard/presentation/desktop_dashboard.dart';
import 'package:expert_edu_center/features/debtors/data/debtors_repository.dart';
import 'package:expert_edu_center/features/students/presentation/open_student.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_repository.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

String plain(String v) => v.replaceAll(RegExp(r'[  ]'), ' ');

class _NoTokens extends TokenStorage {
  @override
  Future<String?> readToken() async => 'token';
}

Debtor debtor(int id, String name, int amount, {String group = 'IELTS 6.5'}) =>
    Debtor(
      enrollmentId: id,
      studentId: id * 10,
      studentFullName: name,
      studentPhone: '998900000000',
      groupId: 1,
      groupName: group,
      status: 'active',
      balance: amount,
      oldestUnpaidDue: DateTime.now().subtract(const Duration(days: 12)),
    );

DashboardSummary summary({
  bool money = true,
  List<Debtor>? debtors,
  int dueCount = 0,
  int unanswered = 0,
  int tasks = 0,
  List<TrialToday> trials = const [],
  double? attendance = 0.84,
}) => DashboardSummary(
  today: DateTime.now(),
  activeStudents: 138,
  newStudentsThisMonth: 6,
  activeGroups: 14,
  collectedThisMonth: money ? 80000000 : 0,
  monthlyPlan: money ? 100000000 : 0,
  totalDebt: 2200000,
  debtorCount: 3,
  newLeadsThisWeek: 5,
  openLeads: 9,
  unansweredLeads: unanswered,
  dueTodayCount: dueCount,
  dueTodayAmount: dueCount * 300000,
  trialsToday: trials,
  revenueByMonth: const [],
  recentPayments: const [],
  topDebtors: debtors ?? const [],
  moneyVisible: money,
  attendanceRate7d: attendance,
  tasksDueToday: tasks,
);

TimetableLesson lesson(
  int groupId,
  String name, {
  required DateTime at,
  int minutes = 60,
  int marked = 0,
  bool cancelled = false,
}) => TimetableLesson(
  groupId: groupId,
  groupName: name,
  teacherName: 'Madina Karimova',
  room: '2-xona',
  startsAt: at,
  endsAt: at.add(Duration(minutes: minutes)),
  status: cancelled ? 'cancelled' : 'scheduled',
  isExtra: false,
  studentCount: 12,
  markedCount: marked,
  presentCount: marked,
);

class FakeDashboard implements DashboardRepository {
  FakeDashboard(this.summaryData, {this.branchRows = const []});

  final DashboardSummary summaryData;
  final List<BranchStats> branchRows;
  int fetches = 0;
  int branchFetches = 0;

  @override
  Future<DashboardSummary> fetch() async {
    fetches++;
    return summaryData;
  }

  @override
  Future<List<BranchStats>> branches() async {
    branchFetches++;
    return branchRows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTimetable implements TimetableRepository {
  FakeTimetable(this.today);

  final List<TimetableLesson> today;

  @override
  Future<List<TimetableLesson>> lessons(
    DateTime from,
    DateTime to, {
    int? groupId,
    int? teacherId,
  }) async => today;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeBranches implements BranchesRepository {
  @override
  Future<List<Branch>> list() async => const [
    Branch(id: 1, name: 'Bosh ofis', isHeadquarters: true),
    Branch(id: 2, name: 'Chilonzor'),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const branchRows = [
  BranchStats(
    branchId: 1,
    name: 'Bosh ofis',
    isHeadquarters: true,
    activeStudents: 114,
    activeGroups: 10,
    collectedThisMonth: 74000000,
    totalDebt: 19600000,
    debtorCount: 30,
    attendanceRate7d: 0.84,
    lessonsToday: 6,
    openLeads: 11,
  ),
  BranchStats(
    branchId: 2,
    name: 'Chilonzor',
    activeStudents: 13,
    activeGroups: 2,
    collectedThisMonth: 2180000,
    totalDebt: 0,
    debtorCount: 0,
    lessonsToday: 2,
    openLeads: 1,
  ),
];

late ProviderContainer container;
int adminCalls = 0;

Future<FakeDashboard> pump(
  WidgetTester tester, {
  required DashboardSummary data,
  List<TimetableLesson> lessons = const [],
  List<BranchStats> branches = const [],
  VoidCallback? onQabul,
  VoidCallback? onDebtors,
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeDashboard(data, branchRows: branches);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardRepositoryProvider.overrideWithValue(fake),
        timetableRepositoryProvider.overrideWithValue(FakeTimetable(lessons)),
        branchesRepositoryProvider.overrideWithValue(FakeBranches()),
        apiClientProvider.overrideWithValue(ApiClient(_NoTokens())),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: DesktopDashboard(
                onOpenAdmissions: onQabul ?? () {},
                onOpenDebtors: onDebtors ?? () {},
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

Finder text(String value) => find.byWidgetPredicate(
  (w) => w is Text && plain(w.data ?? '') == value,
  description: 'text "$value"',
);

void main() {
  setUpAll(loadAppFonts);

  final now = DateTime.now();
  DateTime at(int hoursFromNow, [int minutes = 0]) =>
      now.add(Duration(hours: hoursFromNow, minutes: minutes));

  group('the four figures', () {
    testWidgets(
      'the owner sees students, what was collected against the plan, debt and attendance',
      (tester) async {
        await pump(tester, data: summary());
        expect(find.byKey(const ValueKey('kpi-students')), findsOneWidget);
        expect(find.byKey(const ValueKey('kpi-collected')), findsOneWidget);
        expect(find.byKey(const ValueKey('kpi-debt')), findsOneWidget);
        expect(find.byKey(const ValueKey('kpi-attendance')), findsOneWidget);
        expect(text('138'), findsOneWidget);
        expect(text('80 000 000 so\'m'), findsOneWidget);
        expect(text('Reja 100 000 000 so\'m · 80%'), findsOneWidget);
        expect(text('84%'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('kpi-collected')),
            matching: find.byType(LinearProgressIndicator),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'an admin sees no collected money, plan or chart -- only what students owe and who pays today',
      (tester) async {
        await pump(tester, data: summary(money: false, dueCount: 7));
        expect(find.byKey(const ValueKey('kpi-collected')), findsNothing);
        expect(find.textContaining('tushum'), findsNothing);
        expect(find.textContaining('Reja'), findsNothing);
        expect(find.byKey(const ValueKey('kpi-due-today')), findsOneWidget);
        expect(text('7 ta'), findsOneWidget);
        expect(text('2 100 000 so\'m to\'lashi kerak'), findsOneWidget);
        // Debt is theirs to collect, so it stays.
        expect(find.byKey(const ValueKey('kpi-debt')), findsOneWidget);
        expect(text('2 200 000 so\'m'), findsOneWidget);
      },
    );

    testWidgets('nobody paying today says so', (tester) async {
      await pump(tester, data: summary(money: false));
      expect(text('Yo\'q'), findsOneWidget);
      expect(
        find.textContaining('hech kimning to\'lov kuni emas'),
        findsOneWidget,
      );
    });

    testWidgets('no lesson marked in 7 days: a dash, not 0%', (tester) async {
      await pump(tester, data: summary(attendance: null));
      expect(text('–'), findsOneWidget);
      expect(find.textContaining('davomat olinmagan'), findsOneWidget);
    });

    for (final money in [true, false]) {
      testWidgets(
        'the four cards sit on one line (${money ? 'owner' : 'admin'}): same top, height, label, number and note',
        (tester) async {
          await pump(tester, data: summary(money: money));
          final keys = [
            const ValueKey('kpi-students'),
            ValueKey(money ? 'kpi-collected' : 'kpi-due-today'),
            const ValueKey('kpi-debt'),
            const ValueKey('kpi-attendance'),
          ];
          final tops = <double>{};
          final heights = <double>{};
          final labelTops = <double>{};
          final valueTops = <double>{};
          final noteTops = <double>{};
          for (final key in keys) {
            final card = find.byKey(key);
            tops.add(tester.getTopLeft(card).dy);
            heights.add(tester.getSize(card).height);
            final texts = find.descendant(
              of: card,
              matching: find.byType(Text),
            );
            labelTops.add(tester.getTopLeft(texts.at(0)).dy);
            valueTops.add(tester.getTopLeft(texts.at(1)).dy.roundToDouble());
            noteTops.add(tester.getTopLeft(texts.at(2)).dy);
          }
          expect(tops.length, 1, reason: 'tops $tops');
          expect(heights.length, 1, reason: 'heights $heights');
          expect(labelTops.length, 1, reason: 'labels $labelTops');
          expect(valueTops.length, 1, reason: 'values $valueTops');
          expect(noteTops.length, 1, reason: 'notes $noteTops');
        },
      );
    }

    testWidgets('the first card starts where the page title does (32 px in)', (
      tester,
    ) async {
      await pump(tester, data: summary());
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('kpi-students'))).dx,
        32,
      );
      // ...and the last one ends 32 px from the right edge.
      expect(
        tester.getTopRight(find.byKey(const ValueKey('kpi-attendance'))).dx,
        1440 - 32,
      );
    });

    testWidgets('the debt card opens Qarzdorlar', (tester) async {
      var opened = 0;
      await pump(tester, data: summary(), onDebtors: () => opened++);
      await tester.tap(find.byKey(const ValueKey('kpi-debt')));
      expect(opened, 1);
    });
  });

  group('today\'s lessons', () {
    testWidgets(
      'each lesson says where it stands; the "now" line sits between past and future',
      (tester) async {
        final lessons = [
          lesson(1, 'Beginner A', at: at(-5), marked: 11),
          lesson(2, 'Fransuz tili A1', at: at(-3)),
          lesson(3, 'Algebra', at: at(2)),
          lesson(4, 'Kimyo', at: at(4), cancelled: true),
        ];
        await pump(tester, data: summary(), lessons: lessons);
        expect(find.byKey(const ValueKey('timeline')), findsOneWidget);
        expect(find.text('Davomat olingan'), findsOneWidget);
        expect(find.text('Davomat olinmagan'), findsOneWidget);
        expect(find.text('Kutilmoqda'), findsOneWidget);
        expect(find.text('Bekor qilingan'), findsOneWidget);
        // A cancelled lesson is not counted.
        expect(find.text('3 ta dars'), findsOneWidget);
        // Only the unmarked, finished lesson offers "Davomat olish".
        expect(find.byKey(const ValueKey('mark-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('mark-1')), findsNothing);
        expect(find.byKey(const ValueKey('mark-3')), findsNothing);
        expect(find.byKey(const ValueKey('mark-4')), findsNothing);
        // The marker is after the two past lessons and before the future one.
        final marker = tester
            .getTopLeft(find.byKey(const ValueKey('now-marker')))
            .dy;
        expect(
          marker,
          greaterThan(
            tester
                .getTopLeft(
                  find.descendant(
                    of: find.byKey(const ValueKey('timeline')),
                    matching: find.text('Fransuz tili A1'),
                  ),
                )
                .dy,
          ),
        );
        expect(marker, lessThan(tester.getTopLeft(find.text('Algebra')).dy));
      },
    );

    testWidgets('a lesson in progress is "Davom etmoqda" and can be marked', (
      tester,
    ) async {
      await pump(
        tester,
        data: summary(),
        lessons: [
          lesson(
            5,
            'IELTS',
            at: now.subtract(const Duration(minutes: 20)),
            minutes: 90,
          ),
        ],
      );
      expect(find.text('Davom etmoqda'), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-5')), findsOneWidget);
    });

    testWidgets('no lessons: it says so', (tester) async {
      await pump(tester, data: summary());
      expect(find.byKey(const ValueKey('timeline-empty')), findsOneWidget);
      expect(find.text('Bugun dars yo\'q.'), findsOneWidget);
    });

    testWidgets('lessons are in time order with the time at the left', (
      tester,
    ) async {
      await pump(
        tester,
        data: summary(),
        lessons: [
          lesson(1, 'Birinchi', at: at(1)),
          lesson(2, 'Ikkinchi', at: at(3)),
        ],
      );
      expect(
        tester.getTopLeft(find.text('Birinchi')).dy,
        lessThan(tester.getTopLeft(find.text('Ikkinchi')).dy),
      );
    });
  });

  group('what needs attention', () {
    testWidgets('lists the real things, most urgent first', (tester) async {
      await pump(
        tester,
        data: summary(
          dueCount: 4,
          unanswered: 2,
          tasks: 3,
          trials: [
            TrialToday(
              inquiryId: 9,
              fullName: 'Zilola Nurmatova',
              phone: '998900000001',
              subjectName: 'Fransuz tili',
              startsAt: at(5),
            ),
          ],
          debtors: [
            debtor(1, 'Botir Aliyev', 390000),
            debtor(2, 'Akmal Nazarov', 450000),
          ],
        ),
        lessons: [lesson(2, 'Fransuz tili A1', at: at(-3))],
      );
      final list = find.byKey(const ValueKey('attention'));
      expect(list, findsOneWidget);
      for (final key in [
        'unmarked-2-${at(-3).millisecondsSinceEpoch}',
        'trial-9',
        'due-today',
        'unanswered',
        'tasks',
        'debtor-1',
        'debtor-2',
      ]) {
        expect(
          find.byKey(ValueKey('attention-$key')),
          findsOneWidget,
          reason: key,
        );
      }
      expect(find.text('Zilola Nurmatova'), findsOneWidget);
      expect(
        find.text('4 ta o\'quvchining to\'lov kuni bugun'),
        findsOneWidget,
      );
      expect(find.text('2 ta so\'rovga javob berilmagan'), findsOneWidget);
      expect(find.text('3 ta qo\'ng\'iroq qilish kerak'), findsOneWidget);
      expect(find.text('7 ta'), findsOneWidget);
      // Order: lesson, trial, payments, requests, calls, then debts.
      double y(String key) =>
          tester.getTopLeft(find.byKey(ValueKey('attention-$key'))).dy;
      expect(y('trial-9'), lessThan(y('due-today')));
      expect(y('due-today'), lessThan(y('unanswered')));
      expect(y('tasks'), lessThan(y('debtor-1')));
    });

    testWidgets('only the four biggest debts are listed', (tester) async {
      await pump(
        tester,
        data: summary(
          debtors: [
            for (var i = 1; i <= 6; i++) debtor(i, 'Qarzdor $i', 100000 * i),
          ],
        ),
      );
      expect(find.byKey(const ValueKey('attention-debtor-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-debtor-5')), findsNothing);
    });

    testWidgets('the buttons do what they say', (tester) async {
      var qabul = 0, debtors = 0;
      await pump(
        tester,
        data: summary(
          dueCount: 1,
          unanswered: 1,
          debtors: [debtor(1, 'Botir Aliyev', 390000)],
        ),
        onQabul: () => qabul++,
        onDebtors: () => debtors++,
      );
      await tester.tap(
        find.byKey(const ValueKey('attention-action-unanswered')),
      );
      await tester.tap(
        find.byKey(const ValueKey('attention-action-due-today')),
      );
      expect(qabul, 1);
      expect(debtors, 1);
      // "Profil" asks for that student's profile (payments are taken there).
      await tester.tap(find.byKey(const ValueKey('attention-action-debtor-1')));
      expect(container.read(openStudentRequestProvider).value, 10);
    });

    testWidgets('nothing to do: a calm line', (tester) async {
      await pump(tester, data: summary());
      expect(find.byKey(const ValueKey('attention-empty')), findsOneWidget);
    });
  });

  group('every branch side by side (owner, looking at all of them)', () {
    testWidgets('one row per branch with its own figures', (tester) async {
      await pump(tester, data: summary(), branches: branchRows);
      expect(find.byKey(const ValueKey('branch-stats')), findsOneWidget);
      final hq = find.byKey(const ValueKey('branch-row-1'));
      expect(
        find.descendant(of: hq, matching: find.text('Bosh ofis')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: hq, matching: find.text('114')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: hq, matching: text('74 000 000 so\'m')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: hq, matching: text('19 600 000 so\'m')),
        findsOneWidget,
      );
      final ch = find.byKey(const ValueKey('branch-row-2'));
      // No debt: a dash; no attendance marked: a dash.
      expect(find.descendant(of: ch, matching: find.text('—')), findsOneWidget);
      expect(find.descendant(of: ch, matching: find.text('–')), findsOneWidget);
    });

    testWidgets('clicking a branch makes it the branch in view', (
      tester,
    ) async {
      await pump(tester, data: summary(), branches: branchRows);
      expect(container.read(branchViewProvider), isNull);
      await tester.tap(find.byKey(const ValueKey('branch-row-2')));
      expect(container.read(branchViewProvider), 2);
    });

    testWidgets(
      'not asked for when one branch is already chosen, or for an admin',
      (tester) async {
        final fake = await pump(
          tester,
          data: summary(money: false),
          branches: branchRows,
        );
        expect(find.byKey(const ValueKey('branch-stats')), findsNothing);
        expect(
          fake.branchFetches,
          0,
          reason: 'an admin never asks for other branches',
        );
      },
    );
  });

  group('refreshing', () {
    testWidgets('reload asks the server again', (tester) async {
      final fake = await pump(tester, data: summary());
      expect(fake.fetches, 1);
      final state = tester.state<DesktopDashboardState>(
        find.byType(DesktopDashboard),
      );
      state.reload();
      await tester.pumpAndSettle();
      expect(fake.fetches, 2);
    });

    testWidgets('narrow window: the two halves stack, nothing overflows', (
      tester,
    ) async {
      await pump(
        tester,
        data: summary(debtors: [debtor(1, 'Botir Aliyev', 390000)]),
        lessons: [lesson(1, 'Beginner A', at: at(2))],
        size: const Size(900, 900),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('timeline')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention')), findsOneWidget);
    });
  });
}
