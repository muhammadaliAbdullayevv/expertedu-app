import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/core/formatters/currency_formatter.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_models.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_repository.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_models.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/admissions/presentation/after_trial_dialog.dart';
import 'package:expert_edu_center/features/admissions/presentation/course_finder_screen.dart';
import 'package:expert_edu_center/features/admissions/presentation/trial_booking_dialog.dart';
import 'package:expert_edu_center/features/enrollments/data/enrollments_repository.dart';
import 'package:expert_edu_center/features/groups/data/groups_repository.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

/// How the app writes money (the grouping spaces are not plain spaces).
String money(int amount) => CurrencyFormatter.format(amount);

// --- data -------------------------------------------------------------------------------------

final now = DateTime(2026, 10, 17, 15, 20);

ScheduleSlot slot(int weekday, int h, [int m = 0]) => ScheduleSlot(
  weekday: weekday,
  startsAt: TimeOfDay(hour: h, minute: m),
  endsAt: TimeOfDay(hour: h + 1, minute: m + 30),
  room: '1-xona',
);

GroupMatch match({
  int? free = 2,
  int matched = 3,
  int total = 3,
  String mode = 'fixed_day',
}) => GroupMatch(
  groupId: 7,
  name: 'Beginner A',
  subjectName: 'Ingliz tili',
  level: 'Beginner',
  teacherName: 'Madina Karimova',
  feeAmount: 310000,
  billingMode: mode,
  billingDay: mode == 'fixed_day' ? 1 : null,
  prorateFirstPeriod: true,
  startDate: DateTime(2026, 9, 1),
  capacity: 16,
  enrolled: 14,
  freeSeats: free,
  slots: [slot(1, 9), slot(3, 9), slot(5, 9)],
  matchedDays: matched,
  totalDays: total,
);

Lead lead({String stage = 'decision_pending', int version = 3}) => Lead(
  id: 4,
  clientId: 'c-4',
  fullName: 'Nodira Ismoilova',
  phone: '998990000026',
  subjectId: 1,
  subjectName: 'Ingliz tili',
  source: 'referral',
  stage: stage,
  version: version,
  createdAt: DateTime(2026, 10, 1),
);

Group makeGroup(int id, String name, {String mode = 'fixed_day'}) => Group(
  id: id,
  subjectId: 1,
  name: name,
  teacherName: 'Madina Karimova',
  feeAmount: 310000,
  billingMode: mode,
  billingDay: mode == 'fixed_day' ? 1 : null,
  isActive: true,
  schedule: [slot(1, 9), slot(3, 9), slot(5, 9)],
);

TrialBooking booking(String status, int groupId) => TrialBooking(
  id: 1,
  leadId: 4,
  sessionId: 1,
  status: status,
  version: 1,
  session: TrialSession(
    id: 1,
    kind: 'group_lesson',
    groupId: groupId,
    startsAt: DateTime(2026, 10, 15, 9),
    endsAt: DateTime(2026, 10, 15, 10, 30),
    capacity: 3,
    status: 'scheduled',
    version: 1,
    booked: 1,
    bookings: const [],
  ),
);

// --- fakes ------------------------------------------------------------------------------------

class FakeQabul implements QabulRepository {
  FakeQabul({required this.groups, this.dates = const []});

  final List<GroupMatch> groups;
  final List<TrialDate> dates;
  final List<Map<String, Object?>> searches = [];

  @override
  Future<GroupSearchResult> searchGroups({
    int? subjectId,
    String? level,
    Set<int> weekdays = const {},
    String? timeOfDay,
    int? branchId,
  }) async {
    searches.add({
      'subject': subjectId,
      'level': level,
      'days': weekdays,
      'time': timeOfDay,
    });
    return GroupSearchResult(exact: groups, near: const []);
  }

  @override
  Future<List<TrialDate>> trialDates(int groupId, {int count = 3}) async =>
      dates;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAdmissions implements AdmissionsRepository {
  FakeAdmissions({this.detail, this.groupList = const [], this.bookError});

  final LeadDetail? detail;
  final List<Group> groupList;
  final ApiException? bookError;

  final booked = <({int? sessionId, NewTrialSession? session, bool remind})>[];
  final enrolled = <({int leadId, String key, Map<String, dynamic> body})>[];
  final stages = <({String stage, String? reason, DateTime? followUpAt})>[];

  @override
  Future<LeadDetail> getLead(int id) async => detail!;

  @override
  Future<List<Group>> groups() async => groupList;

  @override
  Future<WriteOutcome<TrialBooking>> bookTrial(
    Lead lead, {
    int? sessionId,
    NewTrialSession? session,
    bool remind = false,
  }) async {
    if (bookError != null) throw bookError!;
    booked.add((sessionId: sessionId, session: session, remind: remind));
    return const WriteOutcome.queued();
  }

  @override
  Future<LeadEnrolled> enrollLead(
    int leadId, {
    required String idempotencyKey,
    required Map<String, dynamic> body,
  }) async {
    enrolled.add((leadId: leadId, key: idempotencyKey, body: body));
    return const LeadEnrolled(
      studentId: 9,
      studentName: 'Nodira Ismoilova',
      reusedStudent: false,
      enrollmentId: 5,
      firstCharge: 150000,
      firstPayment: 0,
    );
  }

  @override
  Future<Lead> changeStage(
    Lead lead,
    String stage, {
    String? reason,
    DateTime? followUpAt,
  }) async {
    stages.add((stage: stage, reason: reason, followUpAt: followUpAt));
    return lead;
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

// --- helpers ----------------------------------------------------------------------------------

Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

Widget opener(
  Future<Object?> Function(BuildContext) show, {
  void Function(Object?)? onResult,
}) => Builder(
  builder: (context) => TextButton(
    onPressed: () async {
      // (Not `onResult?.call(await show(...))`: with no handler that never opens the dialog.)
      final result = await show(context);
      onResult?.call(result);
    },
    child: const Text('ochish'),
  ),
);

void main() {
  setUpAll(loadAppFonts);

  group('the finder\'s group card', () {
    Widget cardFor(GroupMatch g, {bool exact = true, VoidCallback? onJoin}) =>
        SingleChildScrollView(
          child: GroupResultCard(
            group: g,
            exact: exact,
            now: now,
            highlight: const {1, 3, 5},
            primaryTrial: true,
            onTrial: () {},
            onJoin: onJoin,
          ),
        );

    testWidgets(
      'an exact match shows its days, seats, price and the first-payment note',
      (tester) async {
        await pumpApp(tester, cardFor(match(), onJoin: () {}));
        expect(find.text('Ingliz tili, Beginner A'), findsOneWidget);
        expect(find.text('Madina Karimova · 1-xona'), findsOneWidget);
        expect(find.text('Aniq mos: 3 / 3 kun'), findsOneWidget);
        expect(find.text('09:00 – 10:30'), findsOneWidget);
        expect(find.text('Bo\'sh o\'rin: 2'), findsOneWidget);
        expect(find.text('14 / 16'), findsOneWidget);
        expect(find.text('${money(310000)} / oy'), findsOneWidget);
        expect(
          find.textContaining('Guruh 1-sentyabrda boshlangan.'),
          findsOneWidget,
        );
        expect(find.text('Guruhga qo\'shish'), findsOneWidget);
      },
    );

    testWidgets(
      'a near miss says how many days differ; a full group cannot be joined',
      (tester) async {
        await pumpApp(
          tester,
          cardFor(match(free: 0, matched: 0), exact: false),
        );
        expect(find.text('Kunlari farq qiladi: 0 / 3 kun'), findsOneWidget);
        expect(find.text('Guruh to\'lgan'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Guruh to\'lgan'),
              )
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets(
      'an anniversary group says each student pays on their own day',
      (tester) async {
        await pumpApp(tester, cardFor(match(mode: 'student_anniversary')));
        expect(
          find.textContaining(
            'Har bir o\'quvchi guruhga qo\'shilgan kunida to\'laydi.',
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('Sinov darsiga yozish', () {
    final dates = [
      TrialDate(
        startsAt: DateTime(2026, 10, 19, 10, 30),
        endsAt: DateTime(2026, 10, 19, 12),
        guestsBooked: 1,
        sessionFull: false,
        trialSessionId: 11,
        suggestedCapacity: 1,
        freeSeats: 1,
      ),
      TrialDate(
        startsAt: DateTime(2026, 10, 21, 10, 30),
        endsAt: DateTime(2026, 10, 21, 12),
        guestsBooked: 0,
        sessionFull: false,
        suggestedCapacity: 1,
        freeSeats: 1,
      ),
      TrialDate(
        startsAt: DateTime(2026, 10, 23, 10, 30),
        endsAt: DateTime(2026, 10, 23, 12),
        guestsBooked: 3,
        sessionFull: true,
        suggestedCapacity: 1,
        freeSeats: 1,
      ),
    ];

    List<Override> overrides(FakeQabul q, FakeAdmissions a) => [
      qabulRepositoryProvider.overrideWithValue(q),
      admissionsRepositoryProvider.overrideWithValue(a),
    ];

    testWidgets(
      'lists the subject\'s groups with seats, defaults to the first lesson and books into its session',
      (tester) async {
        final admissions = FakeAdmissions();
        final qabul = FakeQabul(
          groups: [match(), match(free: 0)],
          dates: dates,
        );
        Object? result;
        await pumpApp(
          tester,
          opener(
            (c) => showTrialBookingDialog(c, lead: lead()),
            onResult: (r) => result = r,
          ),
          overrides: overrides(qabul, admissions),
        );
        await tester.tap(find.text('ochish'));
        await tester.pumpAndSettle();

        expect(find.text('Sinov darsiga yozish'), findsWidgets);
        expect(find.text('Nodira Ismoilova'), findsOneWidget);
        expect(find.text('So\'rov: Ingliz tili'), findsOneWidget);
        expect(find.text('2 bo\'sh o\'rin'), findsOneWidget);
        expect(find.text('To\'lgan'), findsWidgets);
        expect(qabul.searches.single['subject'], 1);
        // 19 October 2026 is a Monday, 21st a Wednesday, 23rd a Friday.
        for (final label in ['Du, 19-okt', 'Chor, 21-okt', 'Ju, 23-okt']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        // The first lesson is picked: the text says when the client will appear on the list.
        expect(
          find.textContaining(
            'davomat ro\'yxatida "sinov" belgisi bilan ko\'rinadi',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('19-oktyabr'), findsOneWidget);

        await tester.tap(
          find.widgetWithText(FilledButton, 'Sinov darsiga yozish'),
        );
        await tester.pumpAndSettle();
        // It joins the session already open for that lesson, with a reminder task.
        expect(admissions.booked.single.sessionId, 11);
        expect(admissions.booked.single.session, isNull);
        expect(admissions.booked.single.remind, isTrue);
        expect(result, isTrue);
      },
    );

    testWidgets(
      'a lesson with no session yet opens one for the group, a full one cannot be picked',
      (tester) async {
        final admissions = FakeAdmissions();
        await pumpApp(
          tester,
          opener((c) => showTrialBookingDialog(c, lead: lead())),
          overrides: overrides(
            FakeQabul(groups: [match()], dates: dates),
            admissions,
          ),
        );
        await tester.tap(find.text('ochish'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('21-okt'));
        await tester.pump();
        await tester.tap(find.textContaining('23-okt')); // full: ignored
        await tester.pump();
        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Sinov darsiga yozish'),
        );
        await tester.pumpAndSettle();
        final booked = admissions.booked.single;
        expect(booked.sessionId, isNull);
        expect(booked.session!.kind, 'group_lesson');
        expect(booked.session!.groupId, 7);
        expect(booked.session!.startsAt, DateTime(2026, 10, 21, 10, 30));
        expect(booked.session!.capacity, 1);
        expect(booked.remind, isFalse);
      },
    );

    testWidgets('a refusal from the server is shown and nothing closes', (
      tester,
    ) async {
      final admissions = FakeAdmissions(
        bookError: ApiException(
          403,
          'Yana bir sinovni faqat egasi belgilay oladi.',
        ),
      );
      await pumpApp(
        tester,
        opener((c) => showTrialBookingDialog(c, lead: lead())),
        overrides: overrides(
          FakeQabul(groups: [match()], dates: dates),
          admissions,
        ),
      );
      await tester.tap(find.text('ochish'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Sinov darsiga yozish'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Yana bir sinovni faqat egasi belgilay oladi.'),
        findsOneWidget,
      );
      expect(find.text('Sinov darsiga yozish'), findsWidgets);
    });

    testWidgets('no groups for the subject says so', (tester) async {
      await pumpApp(
        tester,
        opener((c) => showTrialBookingDialog(c, lead: lead())),
        overrides: overrides(FakeQabul(groups: const []), FakeAdmissions()),
      );
      await tester.tap(find.text('ochish'));
      await tester.pumpAndSettle();
      expect(find.textContaining('faol guruh topilmadi'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Sinov darsiga yozish'),
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('Sinovdan keyin', () {
    LeadDetail detail() => LeadDetail(
      lead: lead(),
      interactions: const [],
      bookings: [booking('attended', 8)],
      tasks: const [],
    );

    ({
      FakeAdmissions admissions,
      FakeEnrollments enrollments,
      List<Override> overrides,
    })
    setup() {
      final admissions = FakeAdmissions(
        detail: detail(),
        groupList: [makeGroup(7, 'Beginner A'), makeGroup(8, 'Beginner B')],
      );
      final enrollments = FakeEnrollments();
      return (
        admissions: admissions,
        enrollments: enrollments,
        overrides: [
          admissionsRepositoryProvider.overrideWithValue(admissions),
          enrollmentsRepositoryProvider.overrideWithValue(enrollments),
        ],
      );
    }

    testWidgets(
      'the group they tried is chosen, and both ways to charge the first month are shown',
      (tester) async {
        final s = setup();
        await pumpApp(
          tester,
          opener((c) => showAfterTrialDialog(c, lead: lead())),
          overrides: s.overrides,
        );
        await tester.tap(find.text('ochish'));
        await tester.pumpAndSettle();

        expect(find.text('Sinov darsidan keyin'), findsOneWidget);
        expect(find.text('Sinov darsiga keldi'), findsOneWidget);
        expect(find.text('Qaror: kutilmoqda'), findsOneWidget);
        expect(find.text('Guruhga qo\'shish'), findsOneWidget);
        expect(find.text('Keyinroq bog\'lanish'), findsOneWidget);
        expect(find.text('Rad etildi'), findsOneWidget);
        // They attended group 8, so that one is preselected.
        expect(s.enrollments.previews, [8]);
        expect(find.text('Qolgan kunlar bo\'yicha'), findsOneWidget);
        expect(find.text(money(150000)), findsWidgets);
        expect(find.text('To\'liq oy'), findsOneWidget);
        expect(find.text(money(310000)), findsWidgets);
        expect(find.textContaining('(15/31 kun)'), findsOneWidget);
        expect(
          find.textContaining('hisob ${money(150000)} bo\'ladi'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'confirming enrolls once, with the chosen first month and the dialog\'s own key',
      (tester) async {
        final s = setup();
        String? message;
        await pumpApp(
          tester,
          opener(
            (c) => showAfterTrialDialog(c, lead: lead()),
            onResult: (r) => message = r as String?,
          ),
          overrides: s.overrides,
        );
        await tester.tap(find.text('ochish'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('To\'liq oy'));
        await tester.pump();
        expect(
          find.textContaining('hisob ${money(310000)} bo\'ladi'),
          findsOneWidget,
        );
        await tester.tap(find.text('Tasdiqlash'));
        await tester.pumpAndSettle();

        final call = s.admissions.enrolled.single;
        expect(call.leadId, 4);
        expect(call.key, matches(RegExp(r'^[0-9a-f-]{36}$')));
        expect(call.body['group_id'], 8);
        expect(call.body['first_month'], 'full');
        expect(call.body['full_name'], 'Nodira Ismoilova');
        expect(call.body['phone'], '998990000026');
        expect(call.body['joined_at'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
        expect(message, contains('Nodira Ismoilova guruhga yozildi'));
      },
    );

    testWidgets(
      '"Keyinroq" calls back on the chosen day; nothing is enrolled',
      (tester) async {
        final s = setup();
        await pumpApp(
          tester,
          opener((c) => showAfterTrialDialog(c, lead: lead())),
          overrides: s.overrides,
        );
        await tester.tap(find.text('ochish'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keyinroq bog\'lanish'));
        await tester.pump();
        expect(find.textContaining('Qachon eslatamiz:'), findsOneWidget);
        await tester.tap(find.text('Tasdiqlash'));
        await tester.pumpAndSettle();
        expect(s.admissions.enrolled, isEmpty);
        final call = s.admissions.stages.single;
        expect(call.stage, 'follow_up_later');
        expect(call.followUpAt!.hour, 10);
        expect(call.followUpAt!.isAfter(DateTime.now()), isTrue);
      },
    );

    testWidgets('"Rad etildi" needs a reason first', (tester) async {
      final s = setup();
      await pumpApp(
        tester,
        opener((c) => showAfterTrialDialog(c, lead: lead())),
        overrides: s.overrides,
      );
      await tester.tap(find.text('ochish'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rad etildi'));
      await tester.pump();
      await tester.tap(find.text('Tasdiqlash'));
      await tester.pumpAndSettle();
      expect(find.text('Sababini yozing.'), findsOneWidget);
      expect(s.admissions.stages, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextField, 'Rad etish sababi'),
        'Narx qimmat',
      );
      await tester.tap(find.text('Tasdiqlash'));
      await tester.pumpAndSettle();
      final call = s.admissions.stages.single;
      expect((call.stage, call.reason), ('not_interested', 'Narx qimmat'));
      expect(s.admissions.enrolled, isEmpty);
    });

    testWidgets(
      'without a trial it is just "Guruhga qo\'shish" -- no outcome list',
      (tester) async {
        final s = setup();
        await pumpApp(
          tester,
          opener(
            (c) => showAfterTrialDialog(
              c,
              lead: lead(),
              afterTrial: false,
              groupId: 7,
            ),
          ),
          overrides: s.overrides,
        );
        await tester.tap(find.text('ochish'));
        await tester.pumpAndSettle();
        expect(find.text('Keyinroq bog\'lanish'), findsNothing);
        expect(find.text('Rad etildi'), findsNothing);
        expect(find.text('Sinov darsiga keldi'), findsNothing);
        expect(s.enrollments.previews, [7]);
        expect(find.text('Tasdiqlash'), findsOneWidget);
      },
    );
  });
}
