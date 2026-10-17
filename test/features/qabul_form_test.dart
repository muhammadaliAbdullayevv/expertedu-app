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
  FakeQabul({this.fail = false});

  final bool fail;

  @override
  Future<GroupSearchResult> searchGroups({
    int? subjectId,
    String? level,
    Set<int> weekdays = const {},
    String? timeOfDay,
  }) async {
    if (fail) throw ApiException(0, 'offline');
    return GroupSearchResult(exact: groups, near: const []);
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
      SyncEngine(outbox: _NoOutbox(), send: (_, _, _) async => null),
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
      'a group and a trial date are saved with the person; "guruhsiz" is the default',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        // The picker shows free seats; the groupless option is there and chosen.
        expect(find.text('2 bo\'sh o\'rin'), findsOneWidget);
        expect(find.text('5 bo\'sh o\'rin'), findsOneWidget);
        expect(find.text('To\'lgan'), findsOneWidget);
        expect(find.byKey(const ValueKey('group-none')), findsOneWidget);
        expect(
          find.text('Guruh tanlansa, sinov darsi sanalari shu yerda chiqadi.'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('group-1')));
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
        // After saving the choice is cleared for the next person.
        expect(
          find.text('Guruh tanlansa, sinov darsi sanalari shu yerda chiqadi.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the arrow keys choose a group and a trial date; Enter then saves',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '901234567');
        await tester.sendKeyEvent(
          LogicalKeyboardKey.tab,
        ); // name -> phone (cursor is in phone after typing? tap-free)
        await tester.tap(find.byKey(const ValueKey('qabul-phone')));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focusedLabel(), 'qabul-group');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focusedLabel(), 'qabul-trial');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await enter(tester);
        await tester.pumpAndSettle();
        final s = saver.saves.single;
        expect(s.groupId, 1);
        expect(s.trial, DateTime(2026, 10, 20, 9));
      },
    );

    testWidgets('the subject and day filters narrow the groups', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('group-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-3')), findsOneWidget);
      await tester.tap(find.widgetWithText(InkWell, 'Fransuz tili'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-1')), findsNothing);
      expect(find.byKey(const ValueKey('group-3')), findsOneWidget);
      await tester.tap(find.widgetWithText(InkWell, 'Fransuz tili'));
      await tester.tap(find.widgetWithText(InkWell, 'Se Pay Sha'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-1')), findsNothing);
      expect(find.byKey(const ValueKey('group-2')), findsOneWidget);
      // "Guruhsiz" is always there.
      expect(find.byKey(const ValueKey('group-none')), findsOneWidget);
    });

    testWidgets('a group hidden by a filter is not saved invisibly', (
      tester,
    ) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(InkWell, 'Se Pay Sha'));
      await tester.pumpAndSettle();
      await typeInto(tester, 'qabul-name', 'Ali');
      await typeInto(tester, 'qabul-phone', '901234567');
      await enter(tester);
      await tester.pumpAndSettle();
      expect(saver.saves.single.groupId, isNull);
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
