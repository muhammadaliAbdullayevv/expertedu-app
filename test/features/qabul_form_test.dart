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
    show GroupRow, filterGroups;
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
  Saved(this.name, this.phone, this.groupId);
  final String name;
  final String phone;
  final int? groupId;
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
  }) async {
    if (failWith != null) throw failWith!;
    await hold?.future;
    saves.add(Saved(fullName, phone, groupId));
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

/// Whether the group row [key] is the selected one.
bool chosen(WidgetTester tester, String key) =>
    tester.widget<GroupRow>(find.byKey(ValueKey(key))).selected;

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

  Future<void> fill(WidgetTester tester, {String name = 'Ali'}) async {
    await typeInto(tester, 'qabul-name', name);
    await typeInto(tester, 'qabul-phone', '901234567');
  }

  group('Qabul page', () {
    testWidgets(
      'opens on "Yangi qo\'shish" with the cursor in the search box',
      (tester) async {
        await pumpPage(tester);
        expect(find.text('Yangi qo\'shish'), findsOneWidget);
        expect(find.text('Ro\'yxat'), findsOneWidget);
        expect(focusedLabel(), 'qabul-search');
        // Nothing that is not listed: no stats, stages, trial or notes.
        for (final word in [
          'Bog\'lanildi',
          'To\'lov kutilmoqda',
          'Jami',
          'Shu oy',
          'Sinov darsi',
          'Izoh',
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

  group('finding a group', () {
    testWidgets('with nothing typed all groups show, one plain row each', (
      tester,
    ) async {
      await pumpPage(tester);
      for (final id in [1, 2, 3]) {
        expect(find.byKey(ValueKey('group-$id')), findsOneWidget);
      }
      // Name, days and time, teacher, students (and seats when capacity is set).
      expect(find.text('Ingliz tili, Beginner A'), findsOneWidget);
      expect(find.text('Du, Chor, Ju · 09:00'), findsWidgets);
      expect(find.text('Madina Karimova'), findsWidgets);
      expect(find.text('14 o\'quvchi · 2 bo\'sh'), findsOneWidget);
      expect(find.text('0 o\'quvchi · 0 bo\'sh'), findsNothing);
      // Nothing is chosen yet, and there is no inner scroll box.
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('typing filters by subject or group name', (tester) async {
      await pumpPage(tester);
      await typeInto(tester, 'qabul-group-search', 'fransuz');
      expect(find.byKey(const ValueKey('group-1')), findsNothing);
      expect(find.byKey(const ValueKey('group-3')), findsOneWidget);
      await typeInto(tester, 'qabul-group-search', 'beginner b');
      expect(find.byKey(const ValueKey('group-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-1')), findsNothing);
      await typeInto(tester, 'qabul-group-search', 'zzz');
      expect(find.text('Mos guruh topilmadi.'), findsOneWidget);
    });

    testWidgets('the day toggles filter by weekday', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.widgetWithText(OptionPill, 'Se'));
      await tester.tap(find.widgetWithText(OptionPill, 'Pay'));
      await tester.tap(find.widgetWithText(OptionPill, 'Sha'));
      await tester.pumpAndSettle();
      // Group 2 meets Se Pay Sha; the others meet other days.
      expect(find.byKey(const ValueKey('group-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-1')), findsNothing);
      expect(find.byKey(const ValueKey('group-3')), findsNothing);
      await tester.tap(find.widgetWithText(OptionPill, 'Se'));
      await tester.pumpAndSettle();
      // Se is off: group 2 needs a day that is no longer picked.
      expect(find.byKey(const ValueKey('group-2')), findsNothing);
    });

    testWidgets(
      'six groups at first, "Ko\'proq" shows six more, with no scroll box',
      (tester) async {
        final many = <GroupMatch>[
          for (var i = 1; i <= 14; i++)
            makeGroup(i, 'Guruh $i', 'Ingliz tili', [1, 3, 5]),
        ];
        await pumpPage(tester, qabul: FakeQabul(list: many));
        expect(find.byKey(const ValueKey('group-6')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-7')), findsNothing);
        await tester.ensureVisible(find.byKey(const ValueKey('group-more')));
        await tester.tap(find.byKey(const ValueKey('group-more')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('group-12')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-13')), findsNothing);
        await tester.ensureVisible(find.byKey(const ValueKey('group-more')));
        await tester.tap(find.byKey(const ValueKey('group-more')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('group-14')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-more')), findsNothing);
        expect(find.byType(ListView), findsNothing);
      },
    );

    testWidgets(
      'a group with no schedule says "Jadval kiritilmagan"; students show without a capacity',
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
        expect(find.text('Jahongir Rashidov'), findsOneWidget);
        expect(find.text('Cheklanmagan'), findsNothing);
      },
    );

    test(
      'filterGroups: nothing typed keeps all; a group with no schedule needs no day',
      () {
        final bare = makeGroup(9, 'Fizika', 'Fizika', const []);
        final all = [...groups, bare];
        expect(filterGroups(all).map((g) => g.groupId), [1, 2, 3, 9]);
        expect(filterGroups(all, query: 'ingliz').map((g) => g.groupId), [
          1,
          2,
        ]);
        expect(filterGroups(all, days: {1, 3, 5}).map((g) => g.groupId), [
          1,
          3,
        ]);
        expect(filterGroups(all, days: {1, 3}).map((g) => g.groupId), isEmpty);
      },
    );
  });

  group('saving', () {
    testWidgets(
      'pick a group, type name and phone, Enter: saved, cleared, back to the search',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-group-search', 'ingliz');
        await tester.tap(find.byKey(const ValueKey('group-1')));
        await tester.pump();
        expect(focusedLabel(), 'qabul-name');
        await fill(tester, name: 'Nodira Ismoilova');
        await enter(tester);
        await tester.pumpAndSettle();

        final s = saver.saves.single;
        expect(
          (s.name, s.phone, s.groupId),
          ('Nodira Ismoilova', '998901234567', 1),
        );
        expect(field(tester, 'qabul-name').controller!.text, '');
        expect(field(tester, 'qabul-phone').controller!.text, '');
        // The search stays; the cursor is back in it.
        expect(field(tester, 'qabul-group-search').controller!.text, 'ingliz');
        expect(focusedLabel(), 'qabul-search');
        expect(chosen(tester, 'group-1'), isFalse);
        expect(find.text('Saqlandi'), findsOneWidget);
        expect(find.text('Qaytarish'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets('the Saqlash button saves too', (tester) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-2')));
      await fill(tester);
      await tester.ensureVisible(find.text('Saqlash'));
      await tester.tap(find.text('Saqlash'));
      await tester.pumpAndSettle();
      expect(saver.saves.single.groupId, 2);
    });

    testWidgets('"Guruhsiz saqlash" asks only name and phone', (tester) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await tester.ensureVisible(find.byKey(const ValueKey('save-groupless')));
      await tester.tap(find.byKey(const ValueKey('save-groupless')));
      await tester.pump();
      expect(find.text('Guruhsiz saqlanadi'), findsOneWidget);
      expect(focusedLabel(), 'qabul-name');
      await fill(tester);
      await enter(tester);
      await tester.pumpAndSettle();
      expect(saver.saves.single.groupId, isNull);
      // Cleared: the next person starts from nothing again.
      expect(find.text('Guruhsiz saqlanadi'), findsNothing);
    });

    testWidgets(
      'without a group and without "Guruhsiz saqlash" nothing is saved',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await fill(tester);
        await enter(tester);
        await tester.pump();
        expect(saver.saves, isEmpty);
        expect(find.textContaining('Guruhni tanlang'), findsOneWidget);
        expect(focusedLabel(), 'qabul-search');
        expect(field(tester, 'qabul-name').controller!.text, 'Ali');
      },
    );

    testWidgets(
      'Enter in the search box moves on to the name instead of saving',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await tester.tap(find.byKey(const ValueKey('group-1')));
        await tester.tap(find.byKey(const ValueKey('qabul-group-search')));
        await fill(tester);
        await tester.tap(find.byKey(const ValueKey('qabul-group-search')));
        await tester.pump();
        await enter(tester);
        expect(saver.saves, isEmpty);
        expect(focusedLabel(), 'qabul-name');
      },
    );

    testWidgets(
      'a missing name or phone saves nothing and puts the cursor there',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await tester.tap(find.byKey(const ValueKey('group-1')));
        await tester.pump();
        await enter(tester);
        await tester.pump();
        expect(find.text('Ism kiriting'), findsOneWidget);
        expect(focusedLabel(), 'qabul-name');
        await typeInto(tester, 'qabul-name', 'Ali');
        await typeInto(tester, 'qabul-phone', '9012');
        await enter(tester);
        await tester.pump();
        expect(find.text('Telefon to\'liq emas'), findsOneWidget);
        expect(focusedLabel(), 'qabul-phone');
        expect(saver.saves, isEmpty);
        expect(field(tester, 'qabul-name').controller!.text, 'Ali');
      },
    );

    testWidgets(
      'the phone starts with +998 and masks what is typed or pasted',
      (tester) async {
        await pumpPage(tester);
        expect(find.text('+998'), findsOneWidget);
        await typeInto(tester, 'qabul-phone', '901234567');
        expect(field(tester, 'qabul-phone').controller!.text, '90 123 45 67');
        await typeInto(tester, 'qabul-phone', '+998 90 111 22 33 99');
        expect(field(tester, 'qabul-phone').controller!.text, '90 111 22 33');
      },
    );

    testWidgets('holding Enter saves one person, not many', (tester) async {
      final saver = FakeSaver()..hold = Completer<void>();
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await fill(tester);
      await enter(tester);
      await enter(tester);
      await enter(tester);
      saver.hold!.complete();
      await tester.pumpAndSettle();
      expect(saver.saves, hasLength(1));
    });

    testWidgets('if the local save itself fails the typed text stays', (
      tester,
    ) async {
      final saver = FakeSaver()..failWith = StateError('disk full');
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await fill(tester);
      await enter(tester);
      await tester.pumpAndSettle();
      expect(field(tester, 'qabul-name').controller!.text, 'Ali');
      expect(field(tester, 'qabul-phone').controller!.text, '90 123 45 67');
      expect(find.text('Saqlandi'), findsNothing);
      saver.failWith = null;
      await enter(tester);
      await tester.pumpAndSettle();
      expect(saver.saves, hasLength(1));
    });

    testWidgets('a group pushed out of the list by the search is not saved', (
      tester,
    ) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await typeInto(tester, 'qabul-group-search', 'fransuz');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('save-groupless')));
      await tester.tap(find.byKey(const ValueKey('save-groupless')));
      await fill(tester);
      await enter(tester);
      await tester.pumpAndSettle();
      expect(saver.saves.single.groupId, isNull);
    });

    testWidgets('Qaytarish undoes that save', (tester) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await fill(tester, name: 'Ali');
      await enter(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Qaytarish'));
      await tester.pumpAndSettle();
      expect(saver.undone, ['client-0']);
      expect(find.text('Ali qaytarildi.'), findsOneWidget);
    });

    testWidgets('a folded save says it changed nothing', (tester) async {
      final saver = FakeSaver()..undoOutcome = UndoOutcome.unchanged;
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await fill(tester);
      await enter(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Qaytarish'));
      await tester.pumpAndSettle();
      expect(find.textContaining('o\'zgarmadi'), findsOneWidget);
    });

    testWidgets('a refused save says why', (tester) async {
      final saver = FakeSaver()..settle = Completer<QuickSaveResult>();
      await pumpPage(tester, saver: saver);
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await fill(tester);
      await enter(tester);
      await tester.pump();
      expect(find.text('Saqlandi'), findsOneWidget); // at once, before the send
      saver.settle!.complete(
        const QuickSaveResult(SaveState.refused, 'Telefon noto\'g\'ri'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ali saqlanmadi: Telefon noto\'g\'ri'), findsOneWidget);
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
        await tester.ensureVisible(
          find.byKey(const ValueKey('save-groupless')),
        );
        await tester.tap(find.byKey(const ValueKey('save-groupless')));
        await fill(tester);
        await enter(tester);
        await tester.pumpAndSettle();
        expect(saver.saves.single.groupId, isNull);
      },
    );

    testWidgets('the form is centred in the page', (tester) async {
      await pumpPage(tester);
      final card = tester.getRect(find.byKey(const ValueKey('qabul-name')));
      expect(card.left, greaterThan(200));
    });
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
      sync.pendingCount.value = 0;
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

  group('the list', () {
    testWidgets(
      'rows show name, phone, group and date -- and only two buttons',
      (tester) async {
        final admissions = FakeAdmissions()
          ..leads = [
            lead(
              1,
              'Nodira Ismoilova',
              groupId: 1,
              groupName: 'Ingliz tili, Beginner A',
            ),
            lead(2, 'Sevara Tursunova', created: DateTime(2026, 10, 3)),
          ];
        await pumpPage(tester, admissions: admissions, view: QabulView.list);
        expect(find.text('Nodira Ismoilova'), findsOneWidget);
        expect(find.text('+998 90 000 00 01'), findsOneWidget);
        expect(find.text('Ingliz tili, Beginner A'), findsOneWidget);
        expect(find.text('Guruhsiz'), findsOneWidget);
        expect(find.text('O\'quvchi qilish'), findsNWidgets(2));
        expect(find.text('Arxiv'), findsNWidgets(2));
        // Nothing that is not listed.
        for (final word in ['Sinov', 'Jami', 'Filter', 'Qayta ochish']) {
          expect(find.textContaining(word), findsNothing, reason: word);
        }
        expect(find.byKey(const ValueKey('row-more')), findsNothing);
      },
    );

    testWidgets('search waits for a pause, then asks the server', (
      tester,
    ) async {
      final admissions = FakeAdmissions();
      await pumpPage(tester, admissions: admissions, view: QabulView.list);
      expect(admissions.queries.last['q'], '');
      await typeInto(tester, 'qabul-search', 'nod');
      await tester.pump(const Duration(milliseconds: 100));
      expect(admissions.queries.length, 1);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(admissions.queries.last['q'], 'nod');
      // No filters beyond the search.
      expect(admissions.queries.last['group'], isNull);
      expect(admissions.queries.last['groupless'], isFalse);
      expect(admissions.queries.last['trial'], isFalse);
      expect(admissions.queries.last['archive'], isFalse);
    });

    testWidgets(
      'Arxiv takes the person off the list with a reason; nothing is deleted',
      (tester) async {
        final admissions = FakeAdmissions()
          ..leads = [lead(1, 'Nodira Ismoilova')];
        await pumpPage(tester, admissions: admissions, view: QabulView.list);
        await tester.tap(find.byKey(const ValueKey('row-archive')));
        await tester.pumpAndSettle();
        expect(admissions.stages, [
          (stage: 'not_interested', reason: 'Arxivga olindi'),
        ]);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets(
      'a person saved offline is listed first as "Yuborilmagan", without buttons',
      (tester) async {
        final admissions = FakeAdmissions()
          ..pending = [lead(0, 'Ali Valiyev', pendingLocalId: 'local-1')]
          ..leads = [lead(2, 'Sevara Tursunova')];
        await pumpPage(tester, admissions: admissions, view: QabulView.list);
        expect(find.text('Yuborilmagan'), findsOneWidget);
        expect(find.text('O\'quvchi qilish'), findsOneWidget);
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
