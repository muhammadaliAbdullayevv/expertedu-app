import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/core/widgets/status_chip.dart';
import 'package:expert_edu_center/features/branches/application/branch_view.dart';
import 'package:expert_edu_center/features/branches/data/branches_repository.dart';
import 'package:expert_edu_center/features/dashboard/data/dashboard_repository.dart';
import 'package:expert_edu_center/features/dashboard/presentation/desktop_dashboard.dart';
import 'package:expert_edu_center/features/students/presentation/open_student.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

String plain(String v) => v.replaceAll(RegExp(r'[\u00A0\u202F]'), ' ');

class _NoTokens extends TokenStorage {
  @override
  Future<String?> readToken() async => 'token';
}

TimetableLesson lesson(
  int groupId,
  String name, {
  required DateTime at,
  int minutes = 60,
  int marked = 0,
  int late = 0,
  int absent = 0,
  int excused = 0,
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
  presentCount: marked - absent - excused,
  lateCount: late,
  absentCount: absent,
  excusedCount: excused,
);

AbsentToday absentee(int id, String name, {String group = 'IELTS 6.5'}) =>
    AbsentToday(
      studentId: id,
      fullName: name,
      phone: '998901234567',
      groupId: 1,
      groupName: group,
      startsAt: DateTime.now().subtract(const Duration(hours: 2)),
    );

TodayStats stats({
  int planned = 6,
  int held = 4,
  int unmarked = 1,
  int came = 40,
  int absent = 8,
  int expected = 48,
  double? rate = 0.83,
  int leads = 3,
  int trials = 2,
  int risk = 5,
}) => TodayStats(
  activeStudents: 138,
  lessonsPlanned: planned,
  lessonsHeld: held,
  lessonsUnmarked: unmarked,
  came: came,
  absent: absent,
  expected: expected,
  attendanceRate: rate,
  newLeadsToday: leads,
  trialsToday: trials,
  atRiskStudents: risk,
);

TodayView today({
  bool owner = true,
  List<TimetableLesson> lessons = const [],
  List<AbsentToday> absentees = const [],
  List<TodayCall> calls = const [],
  int? callsTotal,
  List<TodayLead> unanswered = const [],
  List<TrialToday> trials = const [],
  List<PayToday> pay = const [],
  int? payTotal,
  int tomorrowLessons = 5,
  int tomorrowTrials = 1,
  TodayStats? s,
}) => TodayView(
  today: DateTime.now(),
  isOwner: owner,
  lessons: lessons,
  absentees: absentees,
  calls: calls,
  callsTotal: callsTotal ?? calls.length,
  unanswered: unanswered,
  unansweredTotal: unanswered.length,
  trialsToday: trials,
  payToday: pay,
  payTodayTotal: payTotal ?? pay.length,
  payTodayAmount: pay.fold(0, (a, p) => a + p.amount),
  tomorrowLessons: tomorrowLessons,
  tomorrowTrials: tomorrowTrials,
  stats: s ?? stats(),
);

class FakeDashboard implements DashboardRepository {
  FakeDashboard(this.data, {this.branchRows = const []});

  TodayView data;
  final List<BranchStats> branchRows;
  int fetches = 0;
  int branchFetches = 0;
  bool failing = false;

  @override
  Future<TodayView> today() async {
    fetches++;
    if (failing) throw Exception('offline');
    return data;
  }

  @override
  Future<List<BranchStats>> branches() async {
    branchFetches++;
    return branchRows;
  }

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
    lessonsPlanned: 6,
    lessonsHeld: 4,
    lessonsUnmarked: 1,
    attendanceRate: 0.84,
    newLeadsToday: 2,
    trialsToday: 1,
    atRiskStudents: 5,
  ),
  BranchStats(
    branchId: 2,
    name: 'Chilonzor',
    activeStudents: 13,
    lessonsPlanned: 0,
    lessonsHeld: 0,
    lessonsUnmarked: 0,
    newLeadsToday: 0,
    trialsToday: 0,
    atRiskStudents: 0,
  ),
];

late ProviderContainer container;

Future<FakeDashboard> pump(
  WidgetTester tester, {
  required TodayView data,
  List<BranchStats> branches = const [],
  VoidCallback? onQabul,
  Duration refreshEvery = const Duration(minutes: 3),
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
                refreshEvery: refreshEvery,
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

Finder inside(String key, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

void main() {
  setUpAll(loadAppFonts);

  final now = DateTime.now();
  DateTime at(int hoursFromNow, [int minutes = 0]) =>
      now.add(Duration(hours: hoursFromNow, minutes: minutes));

  group('the owner\'s strip', () {
    testWidgets('lessons held, attendance, unmarked, at risk, requests', (
      tester,
    ) async {
      await pump(tester, data: today());
      for (final k in [
        'kpi-lessons',
        'kpi-attendance',
        'kpi-unmarked',
        'kpi-risk',
        'kpi-requests',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(inside('kpi-lessons', text('4 / 6')), findsOneWidget);
      expect(inside('kpi-attendance', text('83%')), findsOneWidget);
      expect(inside('kpi-attendance', text('40 keldi · 8 kelmadi')), findsOne);
      expect(inside('kpi-unmarked', text('1')), findsOneWidget);
      expect(inside('kpi-risk', text('5')), findsOneWidget);
      expect(inside('kpi-requests', text('3')), findsOneWidget);
      expect(inside('kpi-requests', text('2 ta sinov bugun')), findsOneWidget);
    });

    testWidgets('no money anywhere on the page', (tester) async {
      await pump(tester, data: today());
      expect(find.textContaining('tushum'), findsNothing);
      expect(find.textContaining('Qarz'), findsNothing);
      expect(find.textContaining('so\'m'), findsNothing);
    });

    testWidgets('a quiet day: zeros and dashes, not NaN', (tester) async {
      await pump(
        tester,
        data: today(
          s: stats(
            planned: 0,
            held: 0,
            unmarked: 0,
            came: 0,
            absent: 0,
            expected: 0,
            rate: null,
            leads: 0,
            trials: 0,
            risk: 0,
          ),
        ),
      );
      expect(inside('kpi-lessons', text('0')), findsOneWidget);
      expect(inside('kpi-attendance', text('–')), findsOneWidget);
      expect(
        inside('kpi-attendance', text('Davomat hali olinmagan')),
        findsOne,
      );
    });

    testWidgets('an admin gets no strip at all', (tester) async {
      await pump(tester, data: today(owner: false));
      expect(find.byKey(const ValueKey('kpi-lessons')), findsNothing);
      expect(find.byKey(const ValueKey('kpi-attendance')), findsNothing);
      expect(find.byKey(const ValueKey('kpi-risk')), findsNothing);
    });

    testWidgets('five cards, one baseline: labels, numbers and notes align', (
      tester,
    ) async {
      await pump(tester, data: today());
      final keys = [
        'kpi-lessons',
        'kpi-attendance',
        'kpi-unmarked',
        'kpi-risk',
        'kpi-requests',
      ];
      final tops = {
        for (final k in keys) tester.getTopLeft(find.byKey(ValueKey(k))).dy,
      };
      final heights = {
        for (final k in keys) tester.getSize(find.byKey(ValueKey(k))).height,
      };
      expect(tops.length, 1);
      expect(heights.length, 1);
      final labelTops = {
        for (final t in [
          'Darslar',
          'Bugungi davomat',
          'Davomatsiz darslar',
          'Xavf ostida',
          'Yangi so\'rovlar',
        ])
          tester.getTopLeft(find.text(t)).dy,
      };
      expect(labelTops.length, 1, reason: 'labels $labelTops');
      final noteTops = {
        for (final t in [
          'o\'tdi, davomat olingan',
          '40 keldi · 8 kelmadi',
          'o\'tgan, davomat olinmagan',
          'davomati past o\'quvchi',
          '2 ta sinov bugun',
        ])
          tester.getTopLeft(text(t)).dy,
      };
      expect(noteTops.length, 1, reason: 'notes $noteTops');
    });

    testWidgets('the first card starts where the page title does (32 px in)', (
      tester,
    ) async {
      await pump(tester, data: today());
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('kpi-lessons'))).dx,
        32,
      );
      expect(
        tester.getTopRight(find.byKey(const ValueKey('kpi-requests'))).dx,
        1440 - 32,
      );
    });
  });

  group('today\'s lessons', () {
    testWidgets(
      'each lesson says where it stands; the "now" line sits between past and future',
      (tester) async {
        await pump(
          tester,
          data: today(
            lessons: [
              lesson(1, 'Beginner A', at: at(-5), marked: 11),
              lesson(2, 'Fransuz tili A1', at: at(-3)),
              lesson(3, 'IELTS', at: at(2)),
              lesson(4, 'Rus tili', at: at(4), cancelled: true),
            ],
          ),
        );
        expect(find.text('Davomat olingan'), findsOneWidget);
        expect(find.text('Davomat olinmagan'), findsOneWidget);
        expect(find.text('Kutilmoqda'), findsOneWidget);
        expect(find.text('Bekor qilingan'), findsOneWidget);
        expect(text('3 ta dars'), findsOneWidget);
        final marker = tester.getCenter(
          find.byKey(const ValueKey('now-marker')),
        );
        expect(
          tester.getCenter(find.text('Fransuz tili A1')).dy,
          lessThan(marker.dy),
        );
        expect(tester.getCenter(find.text('IELTS')).dy, greaterThan(marker.dy));
      },
    );

    testWidgets('a lesson in progress is "Davom etmoqda" and can be marked', (
      tester,
    ) async {
      await pump(
        tester,
        data: today(
          lessons: [
            lesson(
              5,
              'IELTS',
              at: now.subtract(const Duration(minutes: 20)),
              minutes: 90,
            ),
          ],
        ),
      );
      expect(find.text('Davom etmoqda'), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-5')), findsOneWidget);
    });

    testWidgets('a marked lesson shows how it went: bar and who came', (
      tester,
    ) async {
      await pump(
        tester,
        data: today(
          lessons: [
            lesson(1, 'Beginner A', at: at(-5), marked: 12, late: 2, absent: 3),
          ],
        ),
      );
      expect(find.byKey(const ValueKey('result-1')), findsOneWidget);
      expect(text('9 keldi · 3 kelmadi'), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-1')), findsNothing);
    });

    testWidgets('chips and results sit in the same columns on every row', (
      tester,
    ) async {
      await pump(
        tester,
        data: today(
          lessons: [
            lesson(1, 'A guruh', at: at(-6), marked: 10, absent: 1),
            lesson(2, 'B guruh', at: at(-4)),
            lesson(3, 'C guruh', at: at(3)),
            lesson(4, 'D guruh', at: at(5), cancelled: true),
          ],
        ),
      );
      final chips = [
        'Davomat olingan',
        'Davomat olinmagan',
        'Kutilmoqda',
        'Bekor qilingan',
      ];
      final lefts = {for (final c in chips) tester.getTopLeft(find.text(c)).dx};
      // Text is centred in a fixed-width chip, so compare the chips' own box.
      final boxes = {
        for (final c in chips)
          tester
              .getTopLeft(
                find
                    .ancestor(
                      of: find.text(c),
                      matching: find.byType(Container),
                    )
                    .first,
              )
              .dx,
      };
      expect(boxes.length, 1, reason: 'chip lefts $boxes ($lefts)');
      final markLeft = tester
          .getTopRight(find.byKey(const ValueKey('mark-2')))
          .dx;
      final resultRight = tester
          .getTopRight(find.byKey(const ValueKey('result-1')))
          .dx;
      expect(markLeft, resultRight, reason: 'button and result end together');
    });

    testWidgets('no lessons: it says so', (tester) async {
      await pump(tester, data: today());
      expect(find.byKey(const ValueKey('timeline-empty')), findsOneWidget);
      expect(find.text('Bugun dars yo\'q.'), findsOneWidget);
    });

    testWidgets('lessons are in time order with the time at the left', (
      tester,
    ) async {
      await pump(
        tester,
        data: today(
          lessons: [
            lesson(1, 'Birinchi', at: at(1)),
            lesson(2, 'Ikkinchi', at: at(3)),
          ],
        ),
      );
      expect(
        tester.getTopLeft(find.text('Birinchi')).dy,
        lessThan(tester.getTopLeft(find.text('Ikkinchi')).dy),
      );
    });
  });

  group('who did not come', () {
    testWidgets('lists them with the group and the phone, Profil opens them', (
      tester,
    ) async {
      await pump(
        tester,
        data: today(
          absentees: [
            absentee(7, 'Sardor Karimov', group: 'Beginner A'),
            absentee(8, 'Dilnoza Ergasheva'),
          ],
        ),
      );
      expect(text('2 ta'), findsOneWidget);
      expect(inside('absentees', text('Sardor Karimov')), findsOneWidget);
      expect(
        inside('absentees', text('Beginner A · +998 90 123 45 67')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('absent-7-1')),
          matching: find.text('Profil'),
        ),
      );
      expect(container.read(openStudentRequestProvider).value, 7);
    });

    testWidgets('nobody missing: a calm line', (tester) async {
      await pump(tester, data: today());
      expect(find.byKey(const ValueKey('absent-empty')), findsOneWidget);
    });

    testWidgets('a long list is cut at eight with the rest counted', (
      tester,
    ) async {
      await pump(
        tester,
        data: today(
          absentees: [for (var i = 1; i <= 11; i++) absentee(i, 'Talaba $i')],
        ),
      );
      expect(find.text('va yana 3 ta'), findsOneWidget);
      expect(find.text('Talaba 9'), findsNothing);
    });
  });

  group('what is waiting for the admin', () {
    TodayView full() => today(
      owner: false,
      calls: [
        TodayCall(
          taskId: 1,
          leadId: 11,
          leadName: 'Aziza Yusupova',
          leadPhone: '998907770001',
          title: 'Qayta qo\'ng\'iroq',
          dueAt: at(-1),
          overdue: true,
        ),
      ],
      callsTotal: 3,
      unanswered: [
        TodayLead(
          leadId: 12,
          fullName: 'Kamola Rahimova',
          phone: '998907770003',
          subjectName: 'Ingliz tili',
          createdAt: now.subtract(const Duration(days: 3)),
        ),
      ],
      trials: [
        TrialToday(
          inquiryId: 13,
          fullName: 'Jahongir Aliyev',
          phone: '998907770004',
          subjectName: 'IELTS',
          startsAt: at(2),
        ),
      ],
      pay: const [
        PayToday(
          studentId: 21,
          fullName: 'Botir Aliyev',
          groupName: 'Beginner A',
          amount: 300000,
        ),
      ],
    );

    testWidgets('the header counts everything waiting', (tester) async {
      await pump(tester, data: full());
      // 3 calls (one listed, two more), 1 request, 1 trial, 1 payment.
      expect(text('6 ta'), findsOneWidget);
    });

    testWidgets('rows show the right people', (tester) async {
      await pump(tester, data: full());
      expect(inside('call-1', text('Aziza Yusupova')), findsOneWidget);
      expect(
        inside('call-1', text('+998 90 777 00 01 · Qayta qo\'ng\'iroq')),
        findsOneWidget,
      );
      expect(find.text('va yana 2 ta qo\'ng\'iroq'), findsOneWidget);
      expect(
        inside('unanswered-12', text('Ingliz tili · javobsiz 3 kun')),
        findsOneWidget,
      );
      expect(inside('trial-13', text('Jahongir Aliyev')), findsOneWidget);
      expect(
        inside('pay-21', text('Beginner A · 300 000 so\'m')),
        findsOneWidget,
      );
    });

    testWidgets('the buttons do what they say', (tester) async {
      var qabul = 0;
      await pump(tester, data: full(), onQabul: () => qabul++);
      Finder button(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(OutlinedButton),
      );
      await tester.tap(button('call-1'));
      await tester.tap(button('unanswered-12'));
      await tester.tap(button('trial-13'));
      expect(qabul, 3);
      // "Profil" opens that student: payments are taken there.
      await tester.tap(button('pay-21'));
      expect(container.read(openStudentRequestProvider).value, 21);
    });

    testWidgets('nothing waiting: a calm line', (tester) async {
      await pump(tester, data: today(owner: false));
      expect(find.byKey(const ValueKey('waiting-empty')), findsOneWidget);
    });

    testWidgets('tags and buttons line up from row to row', (tester) async {
      await pump(tester, data: full());
      final rows = ['call-1', 'unanswered-12', 'trial-13', 'pay-21'];
      final tagLefts = {
        for (final k in rows)
          tester
              .getTopLeft(
                find.descendant(
                  of: find.byKey(ValueKey(k)),
                  matching: find.byType(StatusChip),
                ),
              )
              .dx,
      };
      final buttonRights = {
        for (final k in rows)
          tester
              .getTopRight(
                find.descendant(
                  of: find.byKey(ValueKey(k)),
                  matching: find.byType(OutlinedButton),
                ),
              )
              .dx,
      };
      expect(buttonRights.length, 1, reason: '$buttonRights');
      expect(tagLefts.length, 1, reason: '$tagLefts');
    });
  });

  group('tomorrow', () {
    testWidgets('a line with what is coming', (tester) async {
      await pump(tester, data: today());
      expect(inside('tomorrow', text('5 ta dars · 1 ta sinov')), findsOne);
    });

    testWidgets('nothing coming says so', (tester) async {
      await pump(tester, data: today(tomorrowLessons: 0, tomorrowTrials: 0));
      expect(inside('tomorrow', text('dars ham, sinov ham yo\'q')), findsOne);
    });
  });

  group('every branch side by side (owner, looking at all of them)', () {
    testWidgets('one row per branch with its own day', (tester) async {
      await pump(tester, data: today(), branches: branchRows);
      expect(find.byKey(const ValueKey('branch-stats')), findsOneWidget);
      final hq = find.byKey(const ValueKey('branch-row-1'));
      for (final v in ['Bosh ofis', '114', '4 / 6', '84%', '1', '5', '2']) {
        expect(
          find.descendant(of: hq, matching: find.text(v)),
          findsWidgets,
          reason: v,
        );
      }
      final ch = find.byKey(const ValueKey('branch-row-2'));
      expect(
        find.descendant(of: ch, matching: find.text('13')),
        findsOneWidget,
      );
      // A quiet branch: dashes, and no attendance marked.
      expect(find.descendant(of: ch, matching: find.text('—')), findsWidgets);
      expect(find.descendant(of: ch, matching: find.text('–')), findsOneWidget);
    });

    testWidgets('no money columns', (tester) async {
      await pump(tester, data: today(), branches: branchRows);
      expect(find.text('Bu oy tushum'), findsNothing);
      expect(find.text('Qarz'), findsNothing);
    });

    testWidgets('clicking a branch makes it the branch in view', (
      tester,
    ) async {
      await pump(tester, data: today(), branches: branchRows);
      expect(container.read(branchViewProvider), isNull);
      await tester.tap(find.byKey(const ValueKey('branch-row-2')));
      expect(container.read(branchViewProvider), 2);
    });

    testWidgets('not asked for by an admin', (tester) async {
      final fake = await pump(
        tester,
        data: today(owner: false),
        branches: branchRows,
      );
      expect(find.byKey(const ValueKey('branch-stats')), findsNothing);
      expect(fake.branchFetches, 0);
    });

    testWidgets('not asked for once one branch is chosen', (tester) async {
      final fake = await pump(tester, data: today());
      expect(fake.branchFetches, 1, reason: 'asked while looking at all');
      container.read(branchViewProvider.notifier).select(2);
      tester
          .state<DesktopDashboardState>(find.byType(DesktopDashboard))
          .reload();
      await tester.pumpAndSettle();
      expect(fake.branchFetches, 1, reason: 'not again for one branch');
      expect(find.byKey(const ValueKey('branch-stats')), findsNothing);
    });
  });

  group('refreshing', () {
    testWidgets('reload asks the server again', (tester) async {
      final fake = await pump(tester, data: today());
      expect(fake.fetches, 1);
      tester
          .state<DesktopDashboardState>(find.byType(DesktopDashboard))
          .reload();
      await tester.pumpAndSettle();
      expect(fake.fetches, 2);
    });

    testWidgets('it asks again on its own and shows the new figures', (
      tester,
    ) async {
      final fake = await pump(
        tester,
        data: today(owner: false),
        refreshEvery: const Duration(minutes: 2),
      );
      expect(find.byKey(const ValueKey('absent-empty')), findsOneWidget);
      fake.data = today(
        owner: false,
        absentees: [absentee(7, 'Sardor Karimov')],
      );
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(fake.fetches, 2);
      expect(find.text('Sardor Karimov'), findsOneWidget);
    });

    testWidgets('a failed automatic refresh leaves the page as it was', (
      tester,
    ) async {
      final fake = await pump(
        tester,
        data: today(absentees: [absentee(7, 'Sardor Karimov')]),
        refreshEvery: const Duration(minutes: 2),
      );
      fake.failing = true;
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(fake.fetches, 2);
      expect(find.text('Sardor Karimov'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('narrow window: the halves stack, nothing overflows', (
      tester,
    ) async {
      await pump(
        tester,
        data: today(
          absentees: [absentee(7, 'Sardor Karimov')],
          lessons: [lesson(1, 'Beginner A', at: at(2))],
        ),
        size: const Size(900, 900),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('timeline')), findsOneWidget);
      expect(find.byKey(const ValueKey('absentees')), findsOneWidget);
    });
  });
}
