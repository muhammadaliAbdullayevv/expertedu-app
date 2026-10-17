import 'dart:async';

import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/core/formatters/currency_formatter.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_models.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_repository.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_models.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/admissions/presentation/student_dialog.dart';
import 'package:expert_edu_center/features/enrollments/data/enrollments_repository.dart';
import 'package:expert_edu_center/features/groups/data/groups_repository.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

String money(int amount) => CurrencyFormatter.format(amount);

ScheduleSlot slot(int weekday) => ScheduleSlot(
  weekday: weekday,
  startsAt: const TimeOfDay(hour: 10, minute: 30),
  endsAt: const TimeOfDay(hour: 12, minute: 0),
);

Group makeGroup(
  int id,
  String name, {
  bool prorate = true,
  String mode = 'fixed_day',
}) => Group(
  id: id,
  subjectId: 1,
  name: name,
  teacherName: 'Madina Karimova',
  feeAmount: 390000,
  billingMode: mode,
  billingDay: mode == 'fixed_day' ? 15 : null,
  prorateFirstPeriod: prorate,
  isActive: true,
  schedule: [slot(1), slot(3), slot(5)],
);

Lead lead({int? groupId}) => Lead(
  id: 4,
  clientId: 'c-4',
  fullName: 'Zilola Nurmatova',
  phone: '998900000007',
  source: 'referral',
  stage: 'new',
  groupId: groupId,
  version: 1,
  createdAt: DateTime(2026, 10, 1),
);

class FakeAdmissions implements AdmissionsRepository {
  FakeAdmissions({required this.groupList, this.error, this.hold});

  final List<Group> groupList;
  final ApiException? error;
  final Completer<void>? hold;
  final enrolled = <({int leadId, String key, Map<String, dynamic> body})>[];

  @override
  Future<List<Group>> groups() async => groupList;

  @override
  Future<LeadEnrolled> enrollLead(
    int leadId, {
    required String idempotencyKey,
    required Map<String, dynamic> body,
  }) async {
    await hold?.future;
    if (error != null) throw error!;
    enrolled.add((leadId: leadId, key: idempotencyKey, body: body));
    return const LeadEnrolled(
      studentId: 9,
      studentName: 'Zilola Nurmatova',
      reusedStudent: false,
      enrollmentId: 5,
      firstCharge: 327097,
      firstPayment: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeEnrollments implements EnrollmentsRepository {
  final previews = <({int group, DateTime at})>[];

  @override
  Future<FirstChargePreview> previewFirstCharge({
    required int groupId,
    required DateTime joinedAt,
    String? discountKind,
    int? discountValue,
  }) async {
    previews.add((group: groupId, at: joinedAt));
    return FirstChargePreview(
      monthlyFee: 390000,
      discountedFee: 390000,
      periodStart: DateTime(2026, 10, 15),
      periodEnd: DateTime(2026, 11, 15),
      daysLeft: 26,
      daysInPeriod: 31,
      proratedAmount: 327097,
      fullAmount: 390000,
      isMidCycle: true,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeQabul implements QabulRepository {
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

Future<
  ({
    FakeAdmissions admissions,
    FakeEnrollments enrollments,
    List<String?> results,
  })
>
open(
  WidgetTester tester, {
  required Lead lead,
  FakeAdmissions? admissions,
}) async {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final adm =
      admissions ??
      FakeAdmissions(
        groupList: [
          makeGroup(7, 'Fransuz tili, A1'),
          makeGroup(8, 'Beginner B', prorate: false),
        ],
      );
  final enrollments = FakeEnrollments();
  final results = <String?>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        admissionsRepositoryProvider.overrideWithValue(adm),
        enrollmentsRepositoryProvider.overrideWithValue(enrollments),
        qabulRepositoryProvider.overrideWithValue(FakeQabul()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  results.add(await showStudentDialog(context, lead: lead)),
              child: const Text('ochish'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ochish'));
  await tester.pumpAndSettle();
  return (admissions: adm, enrollments: enrollments, results: results);
}

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('a full group still takes the student, with a note saying so', (
    tester,
  ) async {
    final full = Group(
      id: 7,
      subjectId: 1,
      name: 'Fransuz tili, A1',
      teacherName: 'Madina Karimova',
      feeAmount: 390000,
      billingMode: 'fixed_day',
      billingDay: 15,
      capacity: 16,
      studentCount: 16,
      isActive: true,
      schedule: [slot(1)],
    );
    final o = await open(
      tester,
      lead: lead(groupId: 7),
      admissions: FakeAdmissions(groupList: [full]),
    );
    expect(find.byKey(const ValueKey('student-full-note')), findsOneWidget);
    expect(find.textContaining('Guruh to\'lgan (16/16)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('student-confirm')));
    await tester.pumpAndSettle();
    expect(o.admissions.enrolled, hasLength(1));
  });

  testWidgets('a group with room shows no full note', (tester) async {
    await open(tester, lead: lead(groupId: 7));
    expect(find.byKey(const ValueKey('student-full-note')), findsNothing);
  });

  testWidgets(
    'shows the design\'s dialog: group, price, start date, first bill by the group\'s rule',
    (tester) async {
      await open(tester, lead: lead(groupId: 7));
      expect(
        find.text('O\'quvchi qilish'),
        findsNWidgets(2),
      ); // title and the button
      expect(find.text('Zilola Nurmatova · Fransuz tili, A1'), findsOneWidget);
      expect(find.text(money(390000)), findsOneWidget);
      expect(find.textContaining('Bugun, '), findsOneWidget);
      expect(find.textContaining('Keyingi dars, '), findsOneWidget);
      expect(find.text('Sanani tanlash'), findsOneWidget);
      expect(find.text('Birinchi hisob'), findsOneWidget);
      expect(find.textContaining('Guruh qoidasi'), findsOneWidget);
      expect(find.textContaining('26 / 31 kun'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('student-due'))).data,
        money(327097),
      );
      expect(
        find.text('Birinchi to\'lovni hozir qabul qilish'),
        findsOneWidget,
      );
      // The group is already known, so no group picker.
      expect(find.byKey(const ValueKey('student-group')), findsNothing);
    },
  );

  testWidgets('a group that charges the full price says so and asks for it', (
    tester,
  ) async {
    await open(tester, lead: lead(groupId: 8));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('student-due'))).data,
      money(390000),
    );
    expect(find.textContaining('26 / 31 kun'), findsNothing);
    expect(find.text('Birinchi oy to\'liq narxda.'), findsOneWidget);
  });

  testWidgets(
    'confirming enrolls once, on the group\'s rule, and returns the message',
    (tester) async {
      final o = await open(tester, lead: lead(groupId: 7));
      await tester.tap(find.byKey(const ValueKey('student-confirm')));
      await tester.pumpAndSettle();
      expect(o.admissions.enrolled, hasLength(1));
      final call = o.admissions.enrolled.single;
      expect(call.leadId, 4);
      expect(call.body['group_id'], 7);
      expect(call.body['joined_at'], ymd(DateTime.now()));
      // The group decides how the first month is charged; no first_month, no payment.
      expect(call.body.containsKey('first_month'), isFalse);
      expect(call.body.containsKey('first_payment_amount'), isFalse);
      expect(call.key, isNotEmpty);
      expect(o.results.single, contains('Zilola Nurmatova guruhga yozildi'));
      expect(find.text('Birinchi hisob'), findsNothing);
    },
  );

  testWidgets(
    '"Keyingi dars" starts then, and the bill is worked out for that day',
    (tester) async {
      final o = await open(tester, lead: lead(groupId: 7));
      await tester.tap(find.textContaining('Keyingi dars, '));
      await tester.pumpAndSettle();
      final next = DateTime.now().add(const Duration(days: 2));
      expect(ymd(o.enrollments.previews.last.at), ymd(next));
      await tester.tap(find.byKey(const ValueKey('student-confirm')));
      await tester.pumpAndSettle();
      expect(o.admissions.enrolled.single.body['joined_at'], ymd(next));
    },
  );

  testWidgets(
    'taking the first payment now sends exactly what is due, by the chosen method',
    (tester) async {
      final o = await open(tester, lead: lead(groupId: 7));
      await tester.tap(find.byKey(const ValueKey('student-pay-now')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Karta'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('student-confirm')));
      await tester.pumpAndSettle();
      final body = o.admissions.enrolled.single.body;
      expect(body['first_payment_amount'], 327097);
      expect(body['first_payment_method'], 'card');
    },
  );

  testWidgets('pressing twice enrolls once', (tester) async {
    final hold = Completer<void>();
    final o = await open(
      tester,
      lead: lead(groupId: 7),
      admissions: FakeAdmissions(
        groupList: [makeGroup(7, 'Fransuz tili, A1')],
        hold: hold,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('student-confirm')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('student-confirm')),
      warnIfMissed: false,
    );
    await tester.pump();
    hold.complete();
    await tester.pumpAndSettle();
    expect(o.admissions.enrolled, hasLength(1));
  });

  testWidgets('a person with no group must pick one first', (tester) async {
    final o = await open(tester, lead: lead());
    expect(find.byKey(const ValueKey('student-group')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('student-confirm')))
          .onPressed,
      isNull,
    );
    expect(find.text('Birinchi hisob'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('student-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Fransuz tili, A1').last);
    await tester.pumpAndSettle();
    expect(find.text('Birinchi hisob'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('student-confirm')));
    await tester.pumpAndSettle();
    expect(o.admissions.enrolled.single.body['group_id'], 7);
  });

  testWidgets('a refusal is shown and the dialog stays', (tester) async {
    final o = await open(
      tester,
      lead: lead(groupId: 7),
      admissions: FakeAdmissions(
        groupList: [makeGroup(7, 'Fransuz tili, A1')],
        error: ApiException(409, 'Guruhda joy yo\'q'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('student-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Guruhda joy yo\'q'), findsOneWidget);
    expect(o.results, isEmpty);
    expect(find.text('Birinchi hisob'), findsOneWidget);
  });

  testWidgets('Bekor qilish closes without enrolling', (tester) async {
    final o = await open(tester, lead: lead(groupId: 7));
    await tester.tap(find.text('Bekor qilish'));
    await tester.pumpAndSettle();
    expect(o.admissions.enrolled, isEmpty);
    expect(o.results, [null]);
  });
}
