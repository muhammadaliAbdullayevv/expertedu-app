import 'dart:async';

import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/app/shell/shell_counts.dart';
import 'package:expert_edu_center/app/navigation/destinations.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_models.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_repository.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_models.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/admissions/data/quick_save.dart';
import 'package:expert_edu_center/features/admissions/presentation/admissions_screen.dart';
import 'package:expert_edu_center/features/admissions/presentation/qabul_form.dart'
    show rankGroups;
import 'package:expert_edu_center/features/admissions/presentation/qabul_widgets.dart';
import 'package:expert_edu_center/features/timetable/data/timetable_models.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/sync/outbox_store.dart';
import 'package:expert_edu_center/services/sync/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

// --- data --------------------------------------------------------------------------------------

ScheduleSlot slot(int weekday, int h) => ScheduleSlot(
  weekday: weekday,
  startsAt: TimeOfDay(hour: h, minute: 0),
  endsAt: TimeOfDay(hour: h + 1, minute: 30),
);

GroupMatch makeGroup(
  int id,
  String name,
  String subject,
  List<int> days, {
  int? free = 2,
  int h = 9,
}) => GroupMatch(
  groupId: id,
  name: name,
  subjectName: subject,
  level: 'Beginner',
  teacherName: 'Madina Karimova',
  feeAmount: 310000,
  billingMode: 'fixed_day',
  billingDay: 1,
  prorateFirstPeriod: true,
  capacity: 16,
  enrolled: 14,
  freeSeats: free,
  slots: [for (final d in days) slot(d, h)],
  matchedDays: days.length,
  totalDays: days.length,
);

final groups = [
  makeGroup(1, 'Beginner A', 'Ingliz tili', [1, 3, 5]),
  makeGroup(2, 'Beginner B', 'Ingliz tili', [2, 4, 6], free: 5, h: 18),
  makeGroup(3, 'A1', 'Fransuz tili', [1, 3, 5], free: 0),
];

final dates = [
  TrialDate(
    startsAt: DateTime(2026, 10, 20, 9),
    endsAt: DateTime(2026, 10, 20, 10, 30),
    guestsBooked: 0,
    sessionFull: false,
    freeSeats: 2,
    suggestedCapacity: 2,
  ),
  TrialDate(
    startsAt: DateTime(2026, 10, 22, 9),
    endsAt: DateTime(2026, 10, 22, 10, 30),
    guestsBooked: 0,
    sessionFull: false,
    freeSeats: 2,
    suggestedCapacity: 2,
  ),
];

// --- fakes -------------------------------------------------------------------------------------

class FakeQabul implements QabulRepository {
  FakeQabul({this.fail = false, List<GroupMatch>? list})
    : list = list ?? groups;

  final bool fail;
  final List<GroupMatch> list;

  @override
  Future<GroupSearchResult> searchGroups({
    int? subjectId,
    String? level,
    Set<int> weekdays = const {},
    String? timeOfDay,
  }) async {
    if (fail) throw ApiException(0, 'offline');
    return GroupSearchResult(exact: list, near: const []);
  }

  @override
  Future<List<TrialDate>> trialDates(int groupId, {int count = 3}) async =>
      dates;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Saved {
  Saved(this.name, this.phone, this.groupId, this.trial, this.note);
  final String name;
  final String phone;
  final int? groupId;
  final DateTime? trial;
  final String? note;
}

class FakeSaver implements QuickSaveRepository {
  final saves = <Saved>[];
  final undone = <String>[];
  Completer<QuickSaveResult>? settle;

  /// Holds the local save open, as a slow disk would.
  Completer<void>? hold;
  Object? failWith;
  UndoOutcome undoOutcome = UndoOutcome.archived;
  int _n = 0;

  @override
  Future<QuickSave> save({
    required String fullName,
    required String phone,
    int? groupId,
    String? groupName,
    DateTime? trialStartsAt,
    String? note,
  }) async {
    if (failWith != null) throw failWith!;
    await hold?.future;
    saves.add(Saved(fullName, phone, groupId, trialStartsAt, note));
    return QuickSave(
      clientId: 'client-${_n++}',
      settled:
          settle?.future ?? Future.value(const QuickSaveResult(SaveState.sent)),
    );
  }

  @override
  Future<UndoOutcome> undo(String clientId) async {
    undone.add(clientId);
    return undoOutcome;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAdmissions implements AdmissionsRepository {
  final queries = <Map<String, Object?>>[];
  final stages = <({String stage, String? reason})>[];
  List<Lead> leads = [];
  List<Lead> pending = [];

  @override
  Future<LeadPage> listLeads({
    String scope = 'open',
    String? query,
    int? assignedTo,
    int? groupId,
    bool groupless = false,
    bool withTrial = false,
    bool archive = false,
    int limit = 500,
  }) async {
    queries.add({
      'q': query,
      'group': groupId,
      'groupless': groupless,
      'trial': withTrial,
      'archive': archive,
    });
    return LeadPage(items: leads, total: leads.length);
  }

  @override
  Future<List<Lead>> pendingLeads() async => pending;

  @override
  Future<Lead> changeStage(
    Lead lead,
    String stage, {
    String? reason,
    DateTime? followUpAt,
  }) async {
    stages.add((stage: stage, reason: reason));
    return lead;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Lead lead(
  int id,
  String name, {
  int? groupId,
  String? groupName,
  DateTime? trial,
  DateTime? created,
  String? note,
  String stage = 'new',
  String? pendingLocalId,
}) => Lead(
  id: id,
  clientId: 'c-$id',
  fullName: name,
  phone: '99890000000$id',
  subjectName: 'Ingliz tili',
  note: note,
  stage: stage,
  groupId: groupId,
  groupName: groupName,
  nextTrialAt: trial,
  version: 1,
  createdAt: created ?? DateTime.now(),
  pendingLocalId: pendingLocalId,
);

// --- harness -----------------------------------------------------------------------------------

Future<void> pumpPage(
  WidgetTester tester, {
  FakeSaver? saver,
  FakeAdmissions? admissions,
  FakeQabul? qabul,
  SyncEngine? sync,
  QabulView view = QabulView.add,
}) async {
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final overrides = <Override>[
    quickSaveProvider.overrideWithValue(saver ?? FakeSaver()),
    admissionsRepositoryProvider.overrideWithValue(
      admissions ?? FakeAdmissions(),
    ),
    qabulRepositoryProvider.overrideWithValue(qabul ?? FakeQabul()),
    syncEngineProvider.overrideWithValue(
      sync ?? SyncEngine(outbox: _NoOutbox(), send: (_, _, _) async => null),
    ),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: AdmissionsScreen(initialView: view)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _NoOutbox implements OutboxStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Whether the choice card [key] is the selected one.
bool chosen(WidgetTester tester, String key) =>
    tester.widget<ChoiceCard>(find.byKey(ValueKey(key))).selected;

String? focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> typeInto(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

TextField field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key)));

Future<void> enter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

void main() {
  setUpAll(loadAppFonts);

  group('Qabul page', () {
    testWidgets(
      'opens on "Yangi qo\'shish" with the cursor in the name, and has no numbers',
      (tester) async {
        await pumpPage(tester);
        expect(find.text('Yangi qo\'shish'), findsOneWidget);
        expect(find.text('Ro\'yxat'), findsOneWidget);
        expect(focusedLabel(), 'qabul-name');
        // No stats, counters, stages or kanban columns.
        for (final word in [
          'Yangi\n',
          'Bog\'lanildi',
          'To\'lov kutilmoqda',
          'Jami',
          'Shu oy',
          'Sinovga kelganlar',
        ]) {
          expect(find.textContaining(word), findsNothing, reason: word);
        }
      },
    );

    testWidgets('the button switches between the two views of the one page', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('qabul-name')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('view-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('qabul-search')), findsOneWidget);
      expect(find.byKey(const ValueKey('qabul-name')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('view-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('qabul-name')), findsOneWidget);
    });

    testWidgets('the sidebar shows no Qabul badge', (tester) async {
      final counts = await _countsFor(openLeads: 11);
      expect(counts.containsKey(Destination.admissions), isFalse);
      expect(counts[Destination.students], 17);
    });
  });

  group('the add form', () {
    testWidgets(
      'the phone starts with +998 and masks what is typed or pasted',
      (tester) async {
        await pumpPage(tester);
        expect(find.text('+998'), findsOneWidget);
        await typeInto(tester, 'qabul-phone', '901234567');
        expect(field(tester, 'qabul-phone').controller!.text, '90 123 45 67');
        await typeInto(tester, 'qabul-phone', '+998 90 111 22 33 99');
        expect(field(tester, 'qabul-phone').controller!.text, '90 111 22 33');
        await typeInto(tester, 'qabul-phone', 'ab90x1');
        expect(field(tester, 'qabul-phone').controller!.text, '90 1');
      },
    );

    testWidgets('Tab goes name -> phone -> group -> trial -> note', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await tester.pumpAndSettle();
      expect(focusedLabel(), 'qabul-group');
      // Back to the name to start from the top.
      await tester.tap(find.byKey(const ValueKey('qabul-name')));
      await tester.pump();
      final order = <String?>[focusedLabel()];
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        order.add(focusedLabel());
      }
      expect(order, [
        'qabul-name',
        'qabul-phone',
        'qabul-group',
        'qabul-trial',
        'qabul-note',
      ]);
    });

    testWidgets(
      'Enter saves, the form clears, focus returns to the name, a notice appears and nothing asks anything',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-name', 'Nodira Ismoilova');
        await typeInto(tester, 'qabul-phone', '901234567');
        await typeInto(tester, 'qabul-note', 'kechqurun qulay');
        await enter(tester);
        await tester.pumpAndSettle();

        expect(saver.saves, hasLength(1));
        final s = saver.saves.single;
        expect(
          (s.name, s.phone, s.groupId, s.trial, s.note),
          ('Nodira Ismoilova', '998901234567', null, null, 'kechqurun qulay'),
        );
        expect(field(tester, 'qabul-name').controller!.text, '');
        expect(field(tester, 'qabul-phone').controller!.text, '');
        expect(field(tester, 'qabul-note').controller!.text, '');
        expect(focusedLabel(), 'qabul-name');
        expect(find.text('Nodira Ismoilova saqlandi'), findsOneWidget);
        expect(find.text('Qaytarish'), findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets('Enter works from every field', (tester) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      for (final key in ['qabul-name', 'qabul-phone', 'qabul-note']) {
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pump();
        await enter(tester);
        await tester.pumpAndSettle();
      }
      expect(saver.saves, hasLength(3));
    });

    testWidgets('holding Enter saves one person, not many', (tester) async {
      // Three Enters arrive while the first save is still being written.
      final saver = FakeSaver()..hold = Completer<void>();
      await pumpPage(tester, saver: saver);
      await typeInto(tester, 'qabul-name', 'Ali');
      await typeInto(tester, 'qabul-phone', '901234567');
      await enter(tester);
      await enter(tester);
      await enter(tester);
      saver.hold!.complete();
      await tester.pumpAndSettle();
      expect(saver.saves, hasLength(1));
    });

    testWidgets(
      'a missing name or phone saves nothing and puts the cursor there; typed text stays',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await enter(tester);
        await tester.pump();
        expect(saver.saves, isEmpty);
        expect(find.text('Ism kiriting'), findsOneWidget);
        expect(focusedLabel(), 'qabul-name');

        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '9012');
        await enter(tester);
        await tester.pump();
        expect(saver.saves, isEmpty);
        expect(find.text('Telefon to\'liq emas'), findsOneWidget);
        expect(focusedLabel(), 'qabul-phone');
        expect(field(tester, 'qabul-name').controller!.text, 'Ali');
        expect(field(tester, 'qabul-phone').controller!.text, '90 12');
      },
    );

    testWidgets(
      'a group and a trial date are saved with the person; nothing is chosen at first',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        // The picker shows free seats; "Guruhsiz" is there but not chosen,
        // and there is no trial section until a group is.
        expect(find.text('2 bo\'sh o\'rin'), findsOneWidget);
        expect(find.text('5 bo\'sh o\'rin'), findsOneWidget);
        expect(find.text('To\'lgan'), findsOneWidget);
        expect(chosen(tester, 'group-none'), isFalse);
        expect(chosen(tester, 'group-1'), isFalse);
        expect(find.byKey(const ValueKey('trial-link')), findsNothing);
        expect(find.text('Sinov darsi qo\'shish'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('group-1')));
        await tester.pumpAndSettle();
        // One link, dates only after it is opened.
        expect(find.text('Sinov darsi qo\'shish'), findsOneWidget);
        expect(find.text('Sinovsiz'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('trial-link')));
        await tester.pumpAndSettle();
        expect(find.text('Sinovsiz'), findsOneWidget);
        await tester.tap(find.text('Pay, 22-okt 09:00'));
        await tester.pump();
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await enter(tester);
        await tester.pumpAndSettle();

        final s = saver.saves.single;
        expect(s.groupId, 1);
        expect(s.trial, DateTime(2026, 10, 22, 9));
        // Cleared for the next person: the trial section is gone again.
        expect(find.byKey(const ValueKey('trial-link')), findsNothing);
        expect(chosen(tester, 'group-1'), isFalse);
      },
    );

    testWidgets('"Guruhsiz" is the last row and saves without a group', (
      tester,
    ) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      final last = tester.getTopLeft(find.byKey(const ValueKey('group-3'))).dy;
      final none = tester
          .getTopLeft(find.byKey(const ValueKey('group-none')))
          .dy;
      expect(none, greaterThan(last));
      await tester.tap(find.byKey(const ValueKey('group-none')));
      await tester.pump();
      expect(chosen(tester, 'group-none'), isTrue);
      await typeInto(tester, 'qabul-name', 'Ali');
      await typeInto(tester, 'qabul-phone', '901234567');
      await enter(tester);
      await tester.pumpAndSettle();
      expect(saver.saves.single.groupId, isNull);
    });

    testWidgets(
      'the arrow keys choose a group and a trial date; Enter then saves',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await tester.tap(find.byKey(const ValueKey('qabul-phone')));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focusedLabel(), 'qabul-group');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(chosen(tester, 'group-1'), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focusedLabel(), 'qabul-trial');
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await enter(tester);
        await tester.pumpAndSettle();
        final s = saver.saves.single;
        expect(s.groupId, 1);
        expect(s.trial, DateTime(2026, 10, 20, 9));
      },
    );

    testWidgets('one search field narrows the groups by subject or name', (
      tester,
    ) async {
      await pumpPage(tester);
      await typeInto(tester, 'qabul-group-search', 'fransuz');
      expect(find.byKey(const ValueKey('group-1')), findsNothing);
      expect(find.byKey(const ValueKey('group-3')), findsOneWidget);
      await typeInto(tester, 'qabul-group-search', 'beginner b');
      expect(find.byKey(const ValueKey('group-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-1')), findsNothing);
      await typeInto(tester, 'qabul-group-search', 'zzz');
      expect(find.text('Mos guruh topilmadi.'), findsOneWidget);
      // "Guruhsiz" is always there.
      expect(find.byKey(const ValueKey('group-none')), findsOneWidget);
    });

    testWidgets('day toggles put exact matches first and hide nothing', (
      tester,
    ) async {
      await pumpPage(tester);
      double top(int id) =>
          tester.getTopLeft(find.byKey(ValueKey('group-$id'))).dy;
      // As listed: 1 (Du Chor Ju), 2 (Se Pay Sha), 3 (Du Chor Ju).
      expect(top(1), lessThan(top(2)));
      await tester.tap(find.widgetWithText(OptionPill, 'Se'));
      await tester.tap(find.widgetWithText(OptionPill, 'Pay'));
      await tester.tap(find.widgetWithText(OptionPill, 'Sha'));
      await tester.pumpAndSettle();
      // Se Pay Sha picked: group 2 is the exact match and goes first.
      expect(top(2), lessThan(top(1)));
      expect(top(2), lessThan(top(3)));
      expect(find.byKey(const ValueKey('group-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-3')), findsOneWidget);
    });

    testWidgets('five groups at first, "Yana ko\'rsatish" shows five more', (
      tester,
    ) async {
      final many = <GroupMatch>[
        for (var i = 1; i <= 12; i++)
          makeGroup(i, 'Guruh $i', 'Ingliz tili', [1, 3, 5]),
      ];
      await pumpPage(tester, qabul: FakeQabul(list: many));
      expect(find.byKey(const ValueKey('group-5')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-6')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('group-more')));
      await tester.tap(find.byKey(const ValueKey('group-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-10')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-11')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('group-more')));
      await tester.tap(find.byKey(const ValueKey('group-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-12')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-more')), findsNothing);
      // The inline list has no scroll box of its own.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('group-1')),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
    });

    testWidgets(
      'a group with no schedule says so; no capacity shows the students, not "Cheklanmagan"',
      (tester) async {
        final bare = GroupMatch(
          groupId: 9,
          name: 'Fizika',
          subjectName: 'Fizika',
          teacherName: 'Jahongir Rashidov',
          feeAmount: 300000,
          billingMode: 'fixed_day',
          billingDay: 1,
          prorateFirstPeriod: true,
          enrolled: 14,
          slots: const [],
          matchedDays: 0,
          totalDays: 0,
        );
        await pumpPage(tester, qabul: FakeQabul(list: [bare, groups.first]));
        expect(find.text('Jadval kiritilmagan'), findsOneWidget);
        expect(find.text('14 o\'quvchi'), findsOneWidget);
        expect(find.text('Cheklanmagan'), findsNothing);
        expect(find.text('Jahongir Rashidov'), findsOneWidget);
        // The scheduled group still shows its own days and time.
        expect(find.text('09:00–10:30'), findsOneWidget);
      },
    );

    testWidgets('a group pushed out of the list by the search is not saved', (
      tester,
    ) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await tester.pumpAndSettle();
      await typeInto(tester, 'qabul-group-search', 'fransuz');
      await tester.pumpAndSettle();
      await typeInto(tester, 'qabul-name', 'Ali');
      await typeInto(tester, 'qabul-phone', '901234567');
      await enter(tester);
      await tester.pumpAndSettle();
      expect(saver.saves.single.groupId, isNull);
    });

    testWidgets('the form is centred in the page', (tester) async {
      await pumpPage(tester);
      final card = tester.getRect(find.byKey(const ValueKey('qabul-name')));
      // 1440 wide page: the 780 card sits in the middle of
      // the page, not against the left edge.
      expect(card.left, greaterThan(200));
    });

    testWidgets(
      'on a slow connection the saved state shows at once, then follows the send',
      (tester) async {
        final saver = FakeSaver()..settle = Completer<QuickSaveResult>();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await enter(tester);
        await tester.pump();
        // Not sent yet -- but saved, cleared and ready for the next person.
        expect(find.text('Ali saqlandi'), findsOneWidget);
        expect(field(tester, 'qabul-name').controller!.text, '');
        expect(focusedLabel(), 'qabul-name');
        saver.settle!.complete(const QuickSaveResult(SaveState.queued));
        await tester.pumpAndSettle();
        expect(
          find.text('Ali saqlandi — internet qaytganda yuboriladi'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a refused save says why and points to the waiting list; nothing is lost',
      (tester) async {
        final saver = FakeSaver()..settle = Completer<QuickSaveResult>();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await enter(tester);
        await tester.pump();
        saver.settle!.complete(
          const QuickSaveResult(SaveState.refused, 'Sinovda joy yo\'q'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Ali saqlanmadi: Sinovda joy yo\'q'), findsOneWidget);
        expect(find.text('Ko\'rish'), findsOneWidget);
        expect(find.text('Qaytarish'), findsNothing);
      },
    );

    testWidgets('if the local save itself fails the typed text stays', (
      tester,
    ) async {
      final saver = FakeSaver()..failWith = StateError('disk full');
      await pumpPage(tester, saver: saver);
      await typeInto(tester, 'qabul-name', 'Ali');
      await typeInto(tester, 'qabul-phone', '901234567');
      await enter(tester);
      await tester.pumpAndSettle();
      expect(field(tester, 'qabul-name').controller!.text, 'Ali');
      expect(field(tester, 'qabul-phone').controller!.text, '90 123 45 67');
      expect(find.text('Ali saqlandi'), findsNothing);
      // And it can be tried again.
      saver.failWith = null;
      await enter(tester);
      await tester.pumpAndSettle();
      expect(saver.saves, hasLength(1));
    });

    testWidgets(
      'Qaytarish undoes that save and puts the person back in the form',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await typeInto(tester, 'qabul-note', 'qulay');
        await enter(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Qaytarish'));
        await tester.pumpAndSettle();
        expect(saver.undone, ['client-0']);
        expect(find.text('Ali qaytarildi.'), findsOneWidget);
        expect(field(tester, 'qabul-name').controller!.text, 'Ali');
        expect(field(tester, 'qabul-phone').controller!.text, '90 123 45 67');
        expect(field(tester, 'qabul-note').controller!.text, 'qulay');
      },
    );

    testWidgets(
      'Qaytarish does not overwrite the next person being typed; a folded save says it changed nothing',
      (tester) async {
        final saver = FakeSaver()..undoOutcome = UndoOutcome.unchanged;
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await enter(tester);
        await tester.pumpAndSettle();
        await typeInto(tester, 'qabul-name', 'Vali');
        await tester.tap(find.text('Qaytarish'));
        await tester.pumpAndSettle();
        expect(field(tester, 'qabul-name').controller!.text, 'Vali');
        expect(
          find.textContaining('avvalgi so\'rovga qo\'shilgan, o\'zgarmadi'),
          findsOneWidget,
        );
      },
    );

    testWidgets('the notice goes away by itself', (tester) async {
      await pumpPage(tester);
      await typeInto(tester, 'qabul-name', 'Ali');
      await typeInto(tester, 'qabul-phone', '901234567');
      await enter(tester);
      await tester.pump();
      expect(find.text('Ali saqlandi'), findsOneWidget);
      await tester.pump(const Duration(seconds: 13));
      expect(find.text('Ali saqlandi'), findsNothing);
    });

    testWidgets(
      'groups that cannot load still let the person be saved without one',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver, qabul: FakeQabul(fail: true));
        expect(
          find.text('Guruhlar yuklanmadi. Guruhsiz saqlash mumkin.'),
          findsOneWidget,
        );
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await enter(tester);
        await tester.pumpAndSettle();
        expect(saver.saves.single.groupId, isNull);
      },
    );
  });

  group('the Oflayn chip', () {
    SyncEngine engine() =>
        SyncEngine(outbox: _NoOutbox(), send: (_, _, _) async => null);

    testWidgets('is hidden while online with nothing waiting', (tester) async {
      await pumpPage(tester, sync: engine());
      expect(find.textContaining('Oflayn'), findsNothing);
      expect(find.textContaining('yuborilmagan'), findsNothing);
    });

    testWidgets(
      'shows "Oflayn" the moment the server cannot be reached, and goes when it can',
      (tester) async {
        final sync = engine();
        await pumpPage(tester, sync: sync);
        sync.reportOffline();
        await tester.pump();
        expect(find.text('Oflayn'), findsOneWidget);
        sync.reportOnline();
        await tester.pump();
        expect(find.textContaining('Oflayn'), findsNothing);
      },
    );

    testWidgets('a save that is merely on its way does not flash a count', (
      tester,
    ) async {
      final sync = engine();
      await pumpPage(tester, sync: sync);
      sync.pendingCount.value = 1;
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('yuborilmagan'), findsNothing);
      sync.pendingCount.value = 0; // it arrived
      await tester.pump(const Duration(seconds: 10));
      expect(find.textContaining('yuborilmagan'), findsNothing);
    });

    testWidgets('something waiting for more than a few seconds is shown', (
      tester,
    ) async {
      final sync = engine();
      await pumpPage(tester, sync: sync);
      sync.pendingCount.value = 2;
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('2 ta yuborilmagan'), findsOneWidget);
      sync.pendingCount.value = 0;
      await tester.pump();
      expect(find.textContaining('yuborilmagan'), findsNothing);
    });
  });

  group('ranking the groups', () {
    test('a search keeps what matches the subject or the name', () {
      expect(rankGroups(groups, query: 'fransuz').map((g) => g.groupId), [3]);
      expect(rankGroups(groups, query: 'ingliz').map((g) => g.groupId), [1, 2]);
      expect(rankGroups(groups, query: 'BEGINNER A').map((g) => g.groupId), [
        1,
      ]);
    });

    test(
      'exact day matches come first, then by fit, then groups with no schedule',
      () {
        final noSchedule = makeGroup(9, 'Fizika', 'Fizika', const []);
        final mixed = makeGroup(8, 'Aralash', 'Ingliz tili', [1, 6]);
        final all = [noSchedule, groups[1], mixed, groups[0]];
        // Du Chor Ju: group 1 exact; mixed fits one day; group 2 none; Fizika unknown.
        final ids = rankGroups(all, days: {1, 3, 5}).map((g) => g.groupId);
        expect(ids, [1, 8, 2, 9]);
        // Nothing is ever hidden by the days.
        expect(ids, hasLength(4));
      },
    );
  });

  group('the list', () {
    testWidgets('rows show the person, group, trial and age -- and no totals', (
      tester,
    ) async {
      final admissions = FakeAdmissions()
        ..leads = [
          lead(
            1,
            'Nodira Ismoilova',
            groupId: 1,
            groupName: 'Ingliz tili, Beginner A',
          ),
          lead(
            2,
            'Sevara Tursunova',
            note: 'kechqurun',
            created: DateTime.now().subtract(const Duration(days: 3)),
          ),
          lead(
            3,
            'Rustam Soliyev',
            groupName: 'Matematika',
            trial: DateTime(2026, 10, 21, 15),
          ),
        ];
      await pumpPage(tester, admissions: admissions, view: QabulView.list);
      expect(find.text('Nodira Ismoilova'), findsOneWidget);
      expect(find.text('+998 90 000 00 01'), findsOneWidget);
      expect(find.text('Ingliz tili, Beginner A'), findsOneWidget);
      expect(find.text('Du, Chor, Ju · 09:00'), findsOneWidget);
      expect(find.text('Guruhsiz'), findsWidgets);
      expect(find.text('Ingliz tili, kechqurun'), findsOneWidget);
      expect(find.text('Sinov: 21-okt 15:00'), findsOneWidget);
      expect(find.text('Bugun'), findsWidgets);
      expect(find.text('3 kun oldin'), findsOneWidget);
      expect(find.text('Sinov darsi'), findsNWidgets(3));
      expect(find.text('O\'quvchi qilish'), findsNWidgets(3));
      expect(find.textContaining('Jami'), findsNothing);
    });

    testWidgets('search waits for a pause and the filters go to the server', (
      tester,
    ) async {
      final admissions = FakeAdmissions();
      await pumpPage(tester, admissions: admissions, view: QabulView.list);
      expect(admissions.queries.last, {
        'q': '',
        'group': null,
        'groupless': false,
        'trial': false,
        'archive': false,
      });

      await typeInto(tester, 'qabul-search', 'nod');
      await tester.pump(const Duration(milliseconds: 100));
      expect(admissions.queries.length, 1); // still typing
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(admissions.queries.last['q'], 'nod');

      await tester.tap(find.byKey(const ValueKey('qabul-groupless')));
      await tester.pumpAndSettle();
      expect(admissions.queries.last['groupless'], isTrue);
      await tester.tap(find.byKey(const ValueKey('qabul-with-trial')));
      await tester.pumpAndSettle();
      expect(admissions.queries.last['trial'], isTrue);
      await tester.tap(find.byKey(const ValueKey('qabul-archive')));
      await tester.pumpAndSettle();
      expect(admissions.queries.last['archive'], isTrue);
    });

    testWidgets('the group filter picks one group', (tester) async {
      final admissions = FakeAdmissions();
      await pumpPage(tester, admissions: admissions, view: QabulView.list);
      await tester.tap(find.byKey(const ValueKey('qabul-group-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ingliz tili, Beginner B').last);
      await tester.pumpAndSettle();
      expect(admissions.queries.last['group'], 2);
      expect(find.text('Beginner B'), findsOneWidget);
    });

    testWidgets(
      'Arxiv archives at once with a way back; the archive view offers Qayta ochish only',
      (tester) async {
        final admissions = FakeAdmissions()
          ..leads = [lead(1, 'Nodira Ismoilova')];
        await pumpPage(tester, admissions: admissions, view: QabulView.list);
        await tester.tap(find.byKey(const ValueKey('row-more')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Arxiv').last);
        await tester.pumpAndSettle();
        expect(admissions.stages, [
          (stage: 'not_interested', reason: 'Arxivga olindi'),
        ]);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Nodira Ismoilova arxivga olindi.'), findsOneWidget);
        await tester.tap(find.text('Qaytarish'));
        await tester.pumpAndSettle();
        expect(admissions.stages.last.stage, 'contacted');

        await tester.tap(find.byKey(const ValueKey('qabul-archive')));
        await tester.pumpAndSettle();
        expect(find.text('Qayta ochish'), findsOneWidget);
        expect(find.text('Sinov darsi'), findsNothing);
        expect(find.text('O\'quvchi qilish'), findsNothing);
      },
    );

    testWidgets(
      'a person saved offline is listed first as "Yuborilmagan", without actions',
      (tester) async {
        final admissions = FakeAdmissions()
          ..pending = [lead(0, 'Ali Valiyev', pendingLocalId: 'local-1')]
          ..leads = [lead(2, 'Sevara Tursunova')];
        await pumpPage(tester, admissions: admissions, view: QabulView.list);
        expect(find.text('Yuborilmagan'), findsOneWidget);
        expect(
          find.text('O\'quvchi qilish'),
          findsOneWidget,
        ); // only Sevara's row
        final names = tester
            .widgetList<Text>(
              find.byWidgetPredicate(
                (w) =>
                    w is Text &&
                    (w.data == 'Ali Valiyev' || w.data == 'Sevara Tursunova'),
              ),
            )
            .map((t) => t.data)
            .toList();
        expect(names, ['Ali Valiyev', 'Sevara Tursunova']);
      },
    );

    testWidgets(
      'an empty list says how to start; an empty search says nothing was found',
      (tester) async {
        final admissions = FakeAdmissions();
        await pumpPage(tester, admissions: admissions, view: QabulView.list);
        expect(
          find.textContaining('Hali hech kim saqlanmagan'),
          findsOneWidget,
        );
        await typeInto(tester, 'qabul-search', 'zzz');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.text('Hech narsa topilmadi.'), findsOneWidget);
      },
    );
  });
}

Future<Map<Destination, int>> _countsFor({required int openLeads}) async {
  final container = ProviderContainer(
    overrides: [
      qabulRepositoryProvider.overrideWithValue(_CountsQabul(openLeads)),
    ],
  );
  addTearDown(container.dispose);
  return container.read(shellCountsProvider.future);
}

class _CountsQabul implements QabulRepository {
  _CountsQabul(this.openLeads);
  final int openLeads;

  @override
  Future<ShellCounts> shellCounts() async => ShellCounts(
    openLeads: openLeads,
    activeStudents: 17,
    activeGroups: 8,
    activeTeachers: 4,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
