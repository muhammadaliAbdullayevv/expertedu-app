import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_models.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/billing/data/transactions_repository.dart';
import 'package:expert_edu_center/features/enrollments/data/enrollments_repository.dart';
import 'package:expert_edu_center/features/students/data/student_models.dart';
import 'package:expert_edu_center/features/students/data/students_repository.dart';
import 'package:expert_edu_center/features/students/presentation/open_student.dart';
import 'package:expert_edu_center/features/students/presentation/student_panel.dart';
import 'package:expert_edu_center/features/students/presentation/students_list_screen.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

String plain(String v) => v.replaceAll(RegExp(r'[  ]'), ' ');

// --- data -------------------------------------------------------------------------------------

ScheduleSlot slot(int weekday, int h) => ScheduleSlot(
  weekday: weekday,
  startsAt: TimeOfDay(hour: h, minute: 30),
  endsAt: TimeOfDay(hour: h + 1, minute: 0),
);

final english = StudentGroupRef(
  groupId: 1,
  name: 'Fransuz tili, A1',
  subjectId: 10,
  subjectName: 'Fransuz tili',
  teacherId: 100,
  teacherName: 'Nilufar Ismoilova',
  schedule: [slot(1, 10), slot(3, 10), slot(5, 10)],
);
final math = StudentGroupRef(
  groupId: 2,
  name: 'Matematika 9',
  subjectId: 20,
  subjectName: 'Matematika',
  teacherId: 200,
  teacherName: 'Jasur Rahimov',
  schedule: [slot(2, 15), slot(4, 15)],
);

StudentRow row(
  int id,
  String name, {
  int balance = 0,
  bool debtor = false,
  bool atRisk = false,
  bool isNew = false,
  bool active = true,
  List<StudentGroupRef>? groups,
  List<String> marks = const [],
  double? rate,
}) => StudentRow(
  id: id,
  fullName: name,
  phone: '99890000000$id'.substring(0, 12),
  balance: balance,
  createdAt: DateTime(2026, 10, 1),
  groups: groups ?? (active ? [english] : const []),
  attendanceRecent: marks,
  attendanceRate: rate,
  isNew: isNew,
  isDebtor: debtor,
  isAtRisk: atRisk,
  isActive: active,
);

ProfileGroup pgroup(
  int enrollmentId,
  int groupId,
  String name, {
  int balance = 0,
  String status = 'active',
  List<ScheduleSlot>? schedule,
  String teacher = 'Nilufar Ismoilova',
}) => ProfileGroup(
  enrollmentId: enrollmentId,
  groupId: groupId,
  groupName: name,
  subjectName: 'Fransuz tili',
  teacherName: teacher,
  feeAmount: 390000,
  joinedAt: DateTime(2026, 9, 5),
  status: status,
  balance: balance,
  schedule: schedule ?? [slot(1, 10), slot(3, 10), slot(5, 10)],
  attendance: const ProfileAttendance(
    present: 8,
    late: 1,
    absent: 1,
    total: 10,
    rate: 0.9,
    recent: ['present', 'present', 'late', 'absent', 'present'],
  ),
);

StudentProfileData profile(
  int id,
  String name, {
  int balance = 390000,
  List<ProfileGroup>? groups,
  List<ProfilePayment> payments = const [],
  String? note,
  bool isNew = false,
  int overdueDays = 3,
}) => StudentProfileData(
  student: Student(
    id: id,
    fullName: name,
    phone: '998900000001',
    parentPhone: '998900000011',
    address: 'Chilonzor, 7-kvartal',
    note: note,
  ),
  isNew: isNew,
  balance: balance,
  paidTotal: payments
      .where((p) => !p.isCancelled)
      .fold(0, (a, p) => a + p.amount),
  groups: groups ?? [pgroup(11, 1, 'Fransuz tili, A1', balance: balance)],
  attendance: const ProfileAttendance(
    present: 8,
    late: 1,
    absent: 1,
    total: 10,
    rate: 0.9,
    recent: ['present', 'present', 'late', 'absent', 'present'],
  ),
  payments: payments,
  debtSince: balance > 0
      ? DateTime.now().subtract(Duration(days: overdueDays))
      : null,
  overdueDays: balance > 0 ? overdueDays : 0,
  activity: [
    ActivityItem(
      at: DateTime.now(),
      kind: 'charge',
      title: 'Hisob chiqdi',
      detail: 'Fransuz tili, A1',
      amount: 390000,
    ),
    ActivityItem(
      at: DateTime.now().subtract(const Duration(days: 1)),
      kind: 'absent',
      title: 'Darsga kelmadi',
      detail: 'Fransuz tili, A1',
    ),
  ],
  marks: [
    ProfileMark(
      at: DateTime.now().subtract(const Duration(days: 1)),
      groupName: 'Fransuz tili, A1',
      status: 'absent',
    ),
    ProfileMark(
      at: DateTime.now().subtract(const Duration(days: 3)),
      groupName: 'Fransuz tili, A1',
      status: 'present',
    ),
  ],
);

ProfilePayment payment(
  int id,
  int amount, {
  String status = 'valid',
  String? reason,
}) => ProfilePayment(
  id: id,
  enrollmentId: 11,
  groupName: 'Fransuz tili, A1',
  amount: amount,
  method: 'cash',
  receivedAt: DateTime.now(),
  receivedByName: 'Admin',
  receiptNo: 'R-$id',
  status: status,
  cancelReason: reason,
);

GroupMatch match(
  int id,
  String name, {
  String subject = 'Ingliz tili',
  int enrolled = 5,
  int? capacity,
  int? free,
}) => GroupMatch(
  groupId: id,
  name: name,
  subjectName: subject,
  teacherName: 'Madina Karimova',
  feeAmount: 310000,
  billingMode: 'fixed_day',
  billingDay: 1,
  prorateFirstPeriod: true,
  capacity: capacity,
  enrolled: enrolled,
  freeSeats: free,
  slots: [slot(1, 9)],
  matchedDays: 1,
  totalDays: 1,
);

// --- fakes ------------------------------------------------------------------------------------

class FakeStudents implements StudentsRepository {
  FakeStudents(this.rowList, this.profiles);

  List<StudentRow> rowList;
  final Map<int, StudentProfileData> profiles;
  final profileCalls = <int>[];
  final updates = <({int id, Map<String, dynamic> changes})>[];
  final added = <({int id, int groupId, int? amount, String? method})>[];
  ApiException? updateError;
  int rowCalls = 0;

  @override
  Future<List<StudentRow>> rows({String? query}) async {
    rowCalls++;
    return rowList;
  }

  @override
  Future<StudentProfileData> profile(int id) async {
    profileCalls.add(id);
    return profiles[id]!;
  }

  @override
  Future<Student> update(int id, Map<String, dynamic> changes) async {
    if (updateError != null) throw updateError!;
    updates.add((id: id, changes: changes));
    final old = profiles[id]!;
    final s = old.student;
    profiles[id] = StudentProfileData(
      student: Student(
        id: s.id,
        fullName: (changes['full_name'] as String?) ?? s.fullName,
        phone: (changes['phone'] as String?) ?? s.phone,
        parentPhone: s.parentPhone,
        address: (changes['address'] as String?) ?? s.address,
        note: (changes['note'] as String?) ?? s.note,
      ),
      isNew: old.isNew,
      balance: old.balance,
      paidTotal: old.paidTotal,
      groups: old.groups,
      attendance: old.attendance,
      payments: old.payments,
      debtSince: old.debtSince,
      overdueDays: old.overdueDays,
      activity: old.activity,
      marks: old.marks,
    );
    return profiles[id]!.student;
  }

  @override
  Future<AddedToGroup> addToGroup(
    int id, {
    required int groupId,
    required DateTime joinedAt,
    int? firstPaymentAmount,
    String? firstPaymentMethod,
  }) async {
    added.add((
      id: id,
      groupId: groupId,
      amount: firstPaymentAmount,
      method: firstPaymentMethod,
    ));
    return AddedToGroup(
      enrollmentId: 99,
      groupName: 'Ingliz tili, Beginner A',
      firstCharge: 310000,
      firstPayment: firstPaymentAmount ?? 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTransactions implements TransactionsRepository {
  final payments =
      <({int enrollmentId, int amount, String? method, String? note})>[];
  final cancels = <({int id, String reason})>[];
  ApiException? error;

  @override
  Future<void> recordPayment({
    required int enrollmentId,
    required int amount,
    String? method,
    String? note,
  }) async {
    if (error != null) throw error!;
    payments.add((
      enrollmentId: enrollmentId,
      amount: amount,
      method: method,
      note: note,
    ));
  }

  @override
  Future<void> cancelPayment(int paymentId, String reason) async {
    if (error != null) throw error!;
    cancels.add((id: paymentId, reason: reason));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeEnrollments implements EnrollmentsRepository {
  final previews = <int>[];

  @override
  Future<FirstChargePreview> previewFirstCharge({
    required int groupId,
    required DateTime joinedAt,
    String? discountKind,
    int? discountValue,
  }) async {
    previews.add(groupId);
    return FirstChargePreview(
      monthlyFee: 310000,
      discountedFee: 310000,
      periodStart: DateTime(2026, 10, 1),
      periodEnd: DateTime(2026, 11, 1),
      daysLeft: 15,
      daysInPeriod: 31,
      proratedAmount: 150000,
      fullAmount: 310000,
      isMidCycle: true,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeQabul implements QabulRepository {
  FakeQabul(this.list);
  final List<GroupMatch> list;

  @override
  Future<GroupSearchResult> searchGroups({
    int? subjectId,
    String? level,
    Set<int> weekdays = const {},
    String? timeOfDay,
  }) async => GroupSearchResult(exact: list, near: const []);

  @override
  Future<List<TrialDate>> trialDates(int groupId, {int count = 3}) async => [
    TrialDate(
      startsAt: DateTime.now().add(const Duration(days: 2)),
      endsAt: DateTime.now().add(const Duration(days: 2, hours: 1)),
      guestsBooked: 0,
      sessionFull: false,
      freeSeats: 2,
      suggestedCapacity: 2,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Rig {
  Rig({
    List<StudentRow>? rows,
    Map<int, StudentProfileData>? profiles,
    List<GroupMatch>? groups,
  }) : students = FakeStudents(
         rows ??
             [
               row(
                 1,
                 'Botir Aliyev',
                 balance: 390000,
                 debtor: true,
                 isNew: true,
                 marks: ['present', 'absent', 'present'],
                 rate: 0.67,
               ),
               row(
                 2,
                 'Dilnoza Ergasheva',
                 atRisk: true,
                 groups: [english, math],
                 rate: 0.7,
               ),
               row(3, 'Madina Qodirova', balance: -120000, rate: 1.0),
               row(4, 'Ketgan Odam', active: false),
             ],
         profiles ??
             {
               1: profile(1, 'Botir Aliyev', payments: [payment(5, 390000)]),
               2: profile(
                 2,
                 'Dilnoza Ergasheva',
                 balance: 0,
                 groups: [
                   pgroup(21, 1, 'Fransuz tili, A1'),
                   pgroup(
                     22,
                     2,
                     'Matematika 9',
                     balance: 200000,
                     teacher: 'Jasur Rahimov',
                     schedule: [slot(2, 15), slot(4, 15)],
                   ),
                 ],
               ),
               3: profile(3, 'Madina Qodirova', balance: -120000),
               4: profile(
                 4,
                 'Ketgan Odam',
                 balance: 0,
                 groups: [
                   pgroup(41, 1, 'Fransuz tili, A1', status: 'withdrawn'),
                 ],
               ),
             },
       ),
       qabul = FakeQabul(
         groups ??
             [
               match(7, 'Beginner A'),
               match(
                 8,
                 'Fizika',
                 subject: 'Fizika',
                 enrolled: 16,
                 capacity: 16,
                 free: 0,
               ),
               match(1, 'Fransuz tili, A1'),
             ],
       );

  final FakeStudents students;
  final transactions = FakeTransactions();
  final enrollments = FakeEnrollments();
  final FakeQabul qabul;
}

Future<void> pump(
  WidgetTester tester,
  Rig rig, {
  Size size = const Size(1500, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studentsRepositoryProvider.overrideWithValue(rig.students),
        transactionsRepositoryProvider.overrideWithValue(rig.transactions),
        enrollmentsRepositoryProvider.overrideWithValue(rig.enrollments),
        qabulRepositoryProvider.overrideWithValue(rig.qabul),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: StudentsListScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String panelName(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('panel-name'))).data!;

Future<void> tab(WidgetTester tester, int i) async {
  await tester.tap(find.byKey(ValueKey('panel-tab-$i')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  group('the table', () {
    testWidgets(
      'shows who, which group and teacher, attendance, balance and status',
      (tester) async {
        await pump(tester, Rig());
        expect(find.text('Botir Aliyev'), findsWidgets);
        expect(find.text('+998 90 000 00 01'), findsWidgets);
        expect(find.text('Fransuz tili, A1'), findsWidgets);
        expect(find.text('Nilufar I. · Du, Chor, Ju · 10:30'), findsWidgets);
        expect(find.text('67%'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is Text && plain(w.data ?? '') == '−390 000',
          ),
          findsOneWidget,
        );
        expect(find.text('Qarzdor'), findsOneWidget);
        expect(find.text('Xavf ostida'), findsWidgets);
        // A second group is hinted, a student with none is "Guruhsiz".
        expect(find.text('Fransuz tili, A1 +1'), findsOneWidget);
        // Newly joined students are marked.
        expect(find.text('Yangi'), findsWidgets);
      },
    );

    testWidgets(
      'the tabs count and filter: Hammasi, Qarzdorlar, Xavf ostida, Yangi, Arxiv',
      (tester) async {
        await pump(tester, Rig());
        String count(String name) =>
            tester.widget<Text>(find.byKey(ValueKey('count-$name'))).data!;
        expect(count('all'), '3');
        expect(count('debtors'), '1');
        expect(count('atRisk'), '1');
        expect(count('fresh'), '1');
        await tester.tap(find.byKey(const ValueKey('tab-debtors')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('student-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('student-3')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('tab-archive')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('student-4')), findsOneWidget);
        expect(find.byKey(const ValueKey('student-1')), findsNothing);
        expect(find.text('Arxiv'), findsWidgets);
      },
    );

    testWidgets(
      'search finds a name, a phone or a group; the filters narrow by subject, group and teacher',
      (tester) async {
        await pump(tester, Rig());
        await tester.enterText(
          find.byKey(const ValueKey('students-search')),
          'madina',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('student-3')), findsOneWidget);
        expect(find.byKey(const ValueKey('student-1')), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('students-search')),
          '0002',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('student-2')), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('students-search')),
          '',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('filter-subject')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Matematika').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('student-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('student-1')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('filters-clear')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('student-1')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('filter-teacher')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Jasur Rahimov').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('student-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('student-3')), findsNothing);
      },
    );

    testWidgets('ten to a page, with Oldingi and Keyingi', (tester) async {
      final many = [for (var i = 1; i <= 12; i++) row(i, 'Talaba $i')];
      final profiles = {
        for (var i = 1; i <= 12; i++) i: profile(i, 'Talaba $i', balance: 0),
      };
      await pump(tester, Rig(rows: many, profiles: profiles));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('paging'))).data,
        '1–10 / 12',
      );
      expect(find.byKey(const ValueKey('student-11')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('page-next')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('paging'))).data,
        '11–12 / 12',
      );
      expect(find.byKey(const ValueKey('student-11')), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('page-next')))
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'the first student is open on the right; clicking another switches the profile',
      (tester) async {
        await pump(tester, Rig());
        expect(panelName(tester), 'Botir Aliyev');
        await tester.tap(find.byKey(const ValueKey('student-3')));
        await tester.pumpAndSettle();
        expect(panelName(tester), 'Madina Qodirova');
      },
    );
  });

  group('the profile panel', () {
    testWidgets(
      'header: name, phones, address, and Tahrirlash at the top right',
      (tester) async {
        await pump(tester, Rig());
        expect(panelName(tester), 'Botir Aliyev');
        expect(
          find.textContaining('Ota-onasi: +998 90 000 00 11'),
          findsOneWidget,
        );
        expect(find.text('Chilonzor, 7-kvartal'), findsOneWidget);
        expect(find.byKey(const ValueKey('panel-edit')), findsOneWidget);
        expect(find.byKey(const ValueKey('panel-menu')), findsOneWidget);
        // Edit sits to the right of the name.
        final edit = tester.getTopLeft(
          find.byKey(const ValueKey('panel-edit')),
        );
        final name = tester.getTopLeft(
          find.byKey(const ValueKey('panel-name')),
        );
        expect(edit.dx, greaterThan(name.dx));
      },
    );

    testWidgets('a debt shows how much, how late, and since when', (
      tester,
    ) async {
      await pump(tester, Rig());
      expect(find.text('Joriy qarz'), findsOneWidget);
      expect(find.text('3 kun kechikdi'), findsOneWidget);
      expect(find.textContaining('Muddat: '), findsOneWidget);
    });

    testWidgets(
      'money paid ahead is shown as such; nothing owed shows no card',
      (tester) async {
        await pump(tester, Rig());
        await tester.tap(find.byKey(const ValueKey('student-3')));
        await tester.pumpAndSettle();
        expect(find.text('Oldindan to\'langan'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('student-2')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('panel-balance')), findsNothing);
      },
    );

    testWidgets(
      'Umumiy: each group with teacher, time, price and attendance, and the latest activity',
      (tester) async {
        await pump(tester, Rig());
        await tester.tap(find.byKey(const ValueKey('student-2')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('group-card-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-card-2')), findsOneWidget);
        expect(find.text('Jasur Rahimov'), findsWidgets);
        expect(find.text('Du, Chor, Ju · 10:30–11:00'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is Text && plain(w.data ?? '') == '390 000 so\'m',
          ),
          findsWidgets,
        );
        expect(find.text('90%'), findsWidgets);
        expect(find.text('So\'nggi faollik'), findsOneWidget);
        expect(find.text('Hisob chiqdi'), findsOneWidget);
        expect(find.text('Darsga kelmadi'), findsOneWidget);
        expect(find.text('Kecha'), findsWidgets);
      },
    );

    testWidgets(
      'To\'lovlar: payments with method and who took them; a cancelled one is marked and cannot be cancelled again',
      (tester) async {
        final rig = Rig(
          profiles: {
            1: profile(
              1,
              'Botir Aliyev',
              payments: [
                payment(5, 390000),
                payment(
                  6,
                  100000,
                  status: 'cancelled',
                  reason: 'Xato kiritilgan',
                ),
              ],
            ),
            2: profile(2, 'Dilnoza Ergasheva', balance: 0),
            3: profile(3, 'Madina Qodirova', balance: -120000),
            4: profile(4, 'Ketgan Odam', balance: 0),
          },
        );
        await pump(tester, rig);
        await tab(tester, 1);
        expect(find.byKey(const ValueKey('payment-5')), findsOneWidget);
        expect(find.byKey(const ValueKey('payment-6')), findsOneWidget);
        expect(find.text('Bekor qilingan'), findsOneWidget);
        expect(find.text('Sabab: Xato kiritilgan'), findsOneWidget);
        expect(find.byKey(const ValueKey('cancel-payment-5')), findsOneWidget);
        expect(find.byKey(const ValueKey('cancel-payment-6')), findsNothing);
        expect(find.textContaining('Jami to\'langan: '), findsOneWidget);
        expect(find.textContaining('Admin'), findsWidgets);
      },
    );

    testWidgets(
      'Davomat: the share, the counts, each group and the latest lessons',
      (tester) async {
        await pump(tester, Rig());
        await tab(tester, 2);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('attendance-rate')))
              .data,
          '90%',
        );
        expect(find.text('Keldi'), findsWidgets);
        expect(find.text('Kelmadi'), findsWidgets);
        expect(find.text('Guruhlar bo\'yicha'), findsOneWidget);
        expect(find.text('So\'nggi darslar'), findsOneWidget);
      },
    );

    testWidgets('Izohlar: the note, or a line saying there is none', (
      tester,
    ) async {
      final rig = Rig(
        profiles: {
          1: profile(1, 'Botir Aliyev', note: 'Kechqurun keladi'),
          2: profile(2, 'Dilnoza Ergasheva', balance: 0),
          3: profile(3, 'Madina Qodirova', balance: -120000),
          4: profile(4, 'Ketgan Odam', balance: 0),
        },
      );
      await pump(tester, rig);
      await tab(tester, 3);
      expect(find.text('Kechqurun keladi'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('student-3')));
      await tester.pumpAndSettle();
      await tab(tester, 3);
      expect(find.text('Izoh yo\'q.'), findsOneWidget);
    });
  });

  group('editing the profile', () {
    testWidgets(
      'Tahrirlash opens the form filled in; only what changed is sent',
      (tester) async {
        final rig = Rig();
        await pump(tester, rig);
        await tester.tap(find.byKey(const ValueKey('panel-edit')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('edit-name')))
              .controller!
              .text,
          'Botir Aliyev',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('edit-phone')))
              .controller!
              .text,
          '90 000 00 01',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('edit-address')))
              .controller!
              .text,
          'Chilonzor, 7-kvartal',
        );
        await tester.enterText(
          find.byKey(const ValueKey('edit-name')),
          'Botir Aliyev Jr',
        );
        await tester.enterText(
          find.byKey(const ValueKey('edit-phone')),
          '901112233',
        );
        await tester.tap(find.byKey(const ValueKey('edit-save')));
        await tester.pumpAndSettle();
        expect(rig.students.updates.single.id, 1);
        expect(rig.students.updates.single.changes, {
          'full_name': 'Botir Aliyev Jr',
          'phone': '998901112233',
        });
        // Saved: the dialog closes and the panel shows the new name.
        expect(find.byKey(const ValueKey('edit-save')), findsNothing);
        expect(panelName(tester), 'Botir Aliyev Jr');
      },
    );

    testWidgets(
      'the menu has Profilni tahrirlash and Boshqa guruhga qo\'shish',
      (tester) async {
        await pump(tester, Rig());
        await tester.tap(find.byKey(const ValueKey('panel-menu')));
        await tester.pumpAndSettle();
        expect(find.text('Profilni tahrirlash'), findsOneWidget);
        expect(find.text('Boshqa guruhga qo\'shish'), findsWidgets);
        await tester.tap(find.text('Profilni tahrirlash'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('edit-name')), findsOneWidget);
      },
    );

    testWidgets(
      'a phone that belongs to someone else is refused and the form stays open',
      (tester) async {
        final rig = Rig()
          ..students.updateError = ApiException(
            409,
            'Bu raqam boshqa o\'quvchiniki.',
          );
        await pump(tester, rig);
        await tester.tap(find.byKey(const ValueKey('panel-edit')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('edit-phone')),
          '901112233',
        );
        await tester.tap(find.byKey(const ValueKey('edit-save')));
        await tester.pumpAndSettle();
        expect(find.text('Bu raqam boshqa o\'quvchiniki.'), findsOneWidget);
        expect(find.byKey(const ValueKey('edit-save')), findsOneWidget);
      },
    );

    testWidgets('an empty name, a half phone and an unchanged form', (
      tester,
    ) async {
      final rig = Rig();
      await pump(tester, rig);
      await tester.tap(find.byKey(const ValueKey('panel-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('edit-name')), '  ');
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pump();
      expect(find.text('Ism va familiyani kiriting.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('edit-name')),
        'Botir Aliyev',
      );
      await tester.enterText(find.byKey(const ValueKey('edit-phone')), '9011');
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pump();
      expect(find.text('Telefon to\'liq emas.'), findsOneWidget);
      expect(rig.students.updates, isEmpty);
      // Nothing changed: saving just closes, and nothing is sent.
      await tester.enterText(
        find.byKey(const ValueKey('edit-phone')),
        '900000001',
      );
      await tester.tap(find.byKey(const ValueKey('edit-save')));
      await tester.pumpAndSettle();
      expect(rig.students.updates, isEmpty);
    });
  });

  group('payments -- only here', () {
    testWidgets(
      'To\'lov qabul qilish: the amount starts at the debt; the group, method and note are sent',
      (tester) async {
        final rig = Rig();
        await pump(tester, rig);
        await tester.tap(find.byKey(const ValueKey('panel-pay')));
        await tester.pumpAndSettle();
        expect(
          plain(
            tester
                .widget<TextField>(find.byKey(const ValueKey('payment-amount')))
                .controller!
                .text,
          ),
          '390 000',
        );
        await tester.tap(find.byKey(const ValueKey('method-card')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('payment-save')));
        await tester.pumpAndSettle();
        final p = rig.transactions.payments.single;
        expect((p.enrollmentId, p.amount, p.method), (11, 390000, 'card'));
        expect(find.text('To\'lov qabul qilindi.'), findsOneWidget);
        // The profile and the table were read again.
        expect(
          rig.students.profileCalls.where((id) => id == 1).length,
          greaterThanOrEqualTo(2),
        );
      },
    );

    testWidgets(
      'with two groups it starts on the one with the larger debt, and switching changes the amount',
      (tester) async {
        final rig = Rig();
        await pump(tester, rig);
        await tester.tap(find.byKey(const ValueKey('student-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('panel-pay')));
        await tester.pumpAndSettle();
        expect(
          plain(
            tester
                .widget<TextField>(find.byKey(const ValueKey('payment-amount')))
                .controller!
                .text,
          ),
          '200 000',
        );
        await tester.tap(find.byKey(const ValueKey('payment-group')));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Fransuz tili, A1  ·').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('payment-amount')))
              .controller!
              .text,
          '',
        );
        await tester.enterText(
          find.byKey(const ValueKey('payment-amount')),
          '50000',
        );
        await tester.tap(find.byKey(const ValueKey('payment-save')));
        await tester.pumpAndSettle();
        expect(rig.transactions.payments.single.enrollmentId, 21);
        expect(rig.transactions.payments.single.amount, 50000);
      },
    );

    testWidgets('no amount, no payment; a server refusal is shown', (
      tester,
    ) async {
      final rig = Rig(
        profiles: {
          1: profile(
            1,
            'Botir Aliyev',
            balance: 0,
            groups: [pgroup(11, 1, 'Fransuz tili, A1')],
          ),
          2: profile(2, 'Dilnoza Ergasheva', balance: 0),
          3: profile(3, 'Madina Qodirova', balance: -120000),
          4: profile(4, 'Ketgan Odam', balance: 0),
        },
      );
      await pump(tester, rig);
      await tester.tap(find.byKey(const ValueKey('panel-pay')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('payment-save')));
      await tester.pump();
      expect(find.text('Summani kiriting.'), findsOneWidget);
      expect(rig.transactions.payments, isEmpty);
      rig.transactions.error = ApiException(400, 'To\'lov usulini tanlang.');
      await tester.enterText(
        find.byKey(const ValueKey('payment-amount')),
        '1000',
      );
      await tester.tap(find.byKey(const ValueKey('payment-save')));
      await tester.pumpAndSettle();
      expect(find.text('To\'lov usulini tanlang.'), findsOneWidget);
    });

    testWidgets('a student with no group cannot be paid for', (tester) async {
      await pump(tester, Rig());
      await tester.tap(find.byKey(const ValueKey('tab-archive')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('student-4')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('panel-pay')))
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'cancelling a payment needs a reason, then it is cancelled with that reason',
      (tester) async {
        final rig = Rig();
        await pump(tester, rig);
        await tab(tester, 1);
        await tester.tap(find.byKey(const ValueKey('cancel-payment-5')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cancel-confirm')));
        await tester.pump();
        expect(find.text('Sababini yozing.'), findsOneWidget);
        expect(rig.transactions.cancels, isEmpty);
        await tester.enterText(
          find.byKey(const ValueKey('cancel-reason')),
          'Xato kiritilgan',
        );
        await tester.tap(find.byKey(const ValueKey('cancel-confirm')));
        await tester.pumpAndSettle();
        expect(rig.transactions.cancels.single, (
          id: 5,
          reason: 'Xato kiritilgan',
        ));
        expect(find.text('To\'lov bekor qilindi.'), findsOneWidget);
      },
    );
  });

  group('Boshqa guruhga qo\'shish', () {
    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('panel-add-group')));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'search the course, the groups the student is already in are left out',
      (tester) async {
        await pump(tester, Rig());
        await openDialog(tester);
        await tester.enterText(
          find.byKey(const ValueKey('add-group-search')),
          'a',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('add-group-7')), findsOneWidget);
        // Group 1 is "Fransuz tili, A1", which Botir already attends.
        expect(find.byKey(const ValueKey('add-group-1')), findsNothing);
      },
    );

    testWidgets(
      'picking a group shows the first bill by its rule; confirming adds once',
      (tester) async {
        final rig = Rig();
        await pump(tester, rig);
        await openDialog(tester);
        await tester.enterText(
          find.byKey(const ValueKey('add-group-search')),
          'beginner',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('add-group-7')));
        await tester.pumpAndSettle();
        expect(
          plain(
            tester.widget<Text>(find.byKey(const ValueKey('add-due'))).data!,
          ),
          '150 000 so\'m',
        );
        expect(find.textContaining('Bugun, '), findsOneWidget);
        expect(find.textContaining('Keyingi dars, '), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('add-confirm')));
        await tester.pumpAndSettle();
        expect(rig.students.added.single, (
          id: 1,
          groupId: 7,
          amount: null,
          method: null,
        ));
        expect(
          find.textContaining('Ingliz tili, Beginner A guruhiga qo\'shildi'),
          findsOneWidget,
        );
      },
    );

    testWidgets('taking the first payment at once sends exactly what is due', (
      tester,
    ) async {
      final rig = Rig();
      await pump(tester, rig);
      await openDialog(tester);
      await tester.enterText(
        find.byKey(const ValueKey('add-group-search')),
        'beginner',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-group-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-pay-now')));
      await tester.pump();
      await tester.tap(find.text('Karta'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('add-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.added.single, (
        id: 1,
        groupId: 7,
        amount: 150000,
        method: 'card',
      ));
    });

    testWidgets('a full group is marked but still takes the student', (
      tester,
    ) async {
      final rig = Rig();
      await pump(tester, rig);
      await openDialog(tester);
      await tester.enterText(
        find.byKey(const ValueKey('add-group-search')),
        'fizika',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-group-8')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-full-note')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.added.single.groupId, 8);
    });

    testWidgets('nothing can be added before a group is chosen', (
      tester,
    ) async {
      await pump(tester, Rig());
      await openDialog(tester);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('add-confirm')))
            .onPressed,
        isNull,
      );
    });
  });

  group('opening a profile from elsewhere', () {
    testWidgets(
      'a request selects that student and clears what would hide them',
      (tester) async {
        final rig = Rig();
        await pump(tester, rig);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(StudentsListScreen)),
        );
        await tester.tap(find.byKey(const ValueKey('tab-debtors')));
        await tester.pumpAndSettle();
        container.read(openStudentRequestProvider).value = 3;
        await tester.pumpAndSettle();
        // Madina is not a debtor, yet she is shown: the tab went back to Hammasi.
        expect(panelName(tester), 'Madina Qodirova');
        expect(container.read(openStudentRequestProvider).value, isNull);
      },
    );

    testWidgets('an archived student is found in Arxiv', (tester) async {
      await pump(tester, Rig());
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StudentsListScreen)),
      );
      container.read(openStudentRequestProvider).value = 4;
      await tester.pumpAndSettle();
      expect(panelName(tester), 'Ketgan Odam');
      expect(find.byKey(const ValueKey('student-4')), findsOneWidget);
    });

    testWidgets(
      'asked for before the page exists, it opens when the page does',
      (tester) async {
        final rig = Rig();
        final notifier = ValueNotifier<int?>(2);
        tester.view.physicalSize = const Size(1500, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              studentsRepositoryProvider.overrideWithValue(rig.students),
              transactionsRepositoryProvider.overrideWithValue(
                rig.transactions,
              ),
              enrollmentsRepositoryProvider.overrideWithValue(rig.enrollments),
              qabulRepositoryProvider.overrideWithValue(rig.qabul),
              openStudentRequestProvider.overrideWithValue(notifier),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const Scaffold(body: StudentsListScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(panelName(tester), 'Dilnoza Ergasheva');
      },
    );
  });

  group('the attendance indicator', () {
    testWidgets(
      'ten slots: full for lessons attended, faint for missed, empty when not yet marked',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(
              body: AttendanceBars(['present', 'absent', 'late']),
            ),
          ),
        );
        final bars = tester
            .widgetList<Container>(find.byType(Container))
            .toList();
        expect(bars, hasLength(10));
        Color? colorOf(int i) => (bars[i].decoration as BoxDecoration).color;
        expect(colorOf(0), AppColors.accent);
        expect(colorOf(1), isNot(AppColors.accent));
        expect(colorOf(3), AppColors.divider);
      },
    );
  });
}
