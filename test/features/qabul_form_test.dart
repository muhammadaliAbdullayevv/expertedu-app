import 'dart:async';

import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/core/formatters/currency_formatter.dart';
import 'package:expert_edu_center/core/widgets/status_chip.dart';
import 'package:expert_edu_center/app/shell/shell_counts.dart';
import 'package:expert_edu_center/app/navigation/destinations.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_models.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_repository.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_models.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/admissions/data/quick_save.dart';
import 'package:expert_edu_center/features/admissions/presentation/admissions_screen.dart';
import 'package:expert_edu_center/features/admissions/presentation/qabul_form.dart'
    show GroupRow;
import 'package:expert_edu_center/features/admissions/presentation/qabul_widgets.dart';
import 'package:expert_edu_center/features/subjects/data/subjects_repository.dart';
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
    int? branchId,
  }) async {
    if (fail) throw ApiException(0, 'offline');
    return GroupSearchResult(exact: list, near: const []);
  }

  final duplicateAsks = <({String? phone, String? name})>[];
  DuplicateCheck duplicateResult = DuplicateCheck.none;

  @override
  Future<DuplicateCheck> duplicates({String? phone, String? fullName}) async {
    duplicateAsks.add((phone: phone, name: fullName));
    return duplicateResult;
  }

  @override
  Future<List<TrialDate>> trialDates(int groupId, {int count = 3}) async =>
      dates;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Saved {
  Saved({
    required this.name,
    required this.phone,
    this.groupId,
    this.parentPhone,
    this.address,
    this.subjectId,
    this.level,
    this.note,
  });
  final String name;
  final String phone;
  final int? groupId;
  final String? parentPhone;
  final String? address;
  final int? subjectId;
  final String? level;
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
    String? parentPhone,
    String? address,
    int? subjectId,
    String? subjectName,
    String? level,
    String? note,
  }) async {
    if (failWith != null) throw failWith!;
    await hold?.future;
    saves.add(
      Saved(
        name: fullName,
        phone: phone,
        groupId: groupId,
        parentPhone: parentPhone,
        address: address,
        subjectId: subjectId,
        level: level,
        note: note,
      ),
    );
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
  Future<List<Subject>> subjects() async => const [
    Subject(id: 1, name: 'Ingliz tili', groupCount: 2),
    Subject(id: 2, name: 'Fransuz tili', groupCount: 1),
  ];

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

String money(int amount) => CurrencyFormatter.format(amount);

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
    await typeInto(tester, 'qabul-first', name);
    await typeInto(tester, 'qabul-last', 'Valiyev');
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
      expect(find.byKey(const ValueKey('qabul-first')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('view-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('qabul-search')), findsOneWidget);
      expect(find.byKey(const ValueKey('qabul-first')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('view-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('qabul-first')), findsOneWidget);
    });

    testWidgets('the sidebar shows no Qabul badge', (tester) async {
      final counts = await _countsFor(openLeads: 11);
      expect(counts.containsKey(Destination.admissions), isFalse);
      expect(counts[Destination.students], 17);
    });
  });

  group('finding the course', () {
    testWidgets('with nothing typed only the hint shows, no list', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(
        find.text('Kurs nomini, tilni yoki o\'qituvchini kiriting'),
        findsOneWidget,
      );
      for (final id in [1, 2, 3]) {
        expect(find.byKey(ValueKey('group-$id')), findsNothing);
      }
      expect(find.byKey(const ValueKey('group-more')), findsNothing);
    });

    testWidgets(
      'typing finds a group by its name, its language or its teacher',
      (tester) async {
        await pumpPage(tester);
        await typeInto(tester, 'qabul-group-search', 'fransuz');
        expect(find.byKey(const ValueKey('group-3')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-1')), findsNothing);
        await typeInto(tester, 'qabul-group-search', 'beginner b');
        expect(find.byKey(const ValueKey('group-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-1')), findsNothing);
        // A teacher's name.
        await typeInto(tester, 'qabul-group-search', 'madina');
        expect(find.byKey(const ValueKey('group-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-2')), findsOneWidget);
        await typeInto(tester, 'qabul-group-search', 'zzz');
        expect(find.text('Mos guruh topilmadi.'), findsOneWidget);
      },
    );

    testWidgets(
      'a row shows name, days and time with its end, teacher, price and seats',
      (tester) async {
        await pumpPage(tester);
        await typeInto(tester, 'qabul-group-search', 'beginner a');
        expect(find.text('Ingliz tili, Beginner A'), findsOneWidget);
        expect(find.text('Du, Chor, Ju · 09:00–10:30'), findsOneWidget);
        expect(find.text('Madina Karimova'), findsOneWidget);
        expect(find.text(money(310000)), findsOneWidget);
        expect(find.text('14 o\'quvchi · 2 bo\'sh'), findsOneWidget);
      },
    );

    testWidgets('there are no day or time filters', (tester) async {
      await pumpPage(tester);
      for (final word in ['Du', 'Se', 'Ertalab', 'Kechqurun', 'Kunduzi']) {
        expect(
          find.widgetWithText(OptionPill, word),
          findsNothing,
          reason: word,
        );
      }
    });

    testWidgets(
      'six groups at first, "Ko\'proq" shows six more, with no scroll box',
      (tester) async {
        final many = <GroupMatch>[
          for (var i = 1; i <= 14; i++)
            makeGroup(i, 'Guruh $i', 'Ingliz tili', [1, 3, 5]),
        ];
        await pumpPage(tester, qabul: FakeQabul(list: many));
        await typeInto(tester, 'qabul-group-search', 'guruh');
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
      'a group with no schedule says so, and the banner offers to fill them all',
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
        expect(find.text('1 ta guruhda jadval kiritilmagan.'), findsOneWidget);
        expect(find.byKey(const ValueKey('fill-schedules')), findsOneWidget);
        await typeInto(tester, 'qabul-group-search', 'fizika');
        expect(find.text('Jadval kiritilmagan'), findsOneWidget);
        expect(find.text('14 o\'quvchi'), findsOneWidget);
      },
    );

    testWidgets(
      'a full group is marked, can still be chosen, and the note says what happens',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-group-search', 'fransuz');
        expect(find.text('To\'lgan · 14 o\'quvchi'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('group-3')));
        await tester.pump();
        expect(find.byKey(const ValueKey('full-note')), findsOneWidget);
        await fill(tester);
        await enter(tester);
        await tester.pumpAndSettle();
        expect(saver.saves.single.groupId, 3);
      },
    );
  });

  group('saving', () {
    testWidgets(
      'course, name, surname, phones, address: Enter saves, clears, back to the search',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-group-search', 'ingliz');
        await tester.tap(find.byKey(const ValueKey('group-1')));
        await tester.pump();
        expect(focusedLabel(), 'qabul-first');
        await typeInto(tester, 'qabul-first', 'Nodira');
        await typeInto(tester, 'qabul-last', 'Ismoilova');
        await typeInto(tester, 'qabul-phone', '901234567');
        await typeInto(tester, 'qabul-parent-phone', '935551234');
        await typeInto(tester, 'qabul-address', 'Chilonzor, 7-kvartal');
        await enter(tester);
        await tester.pumpAndSettle();

        final s = saver.saves.single;
        expect(s.name, 'Nodira Ismoilova');
        expect(s.phone, '998901234567');
        expect(s.parentPhone, '998935551234');
        expect(s.address, 'Chilonzor, 7-kvartal');
        expect(s.groupId, 1);
        // No wish fields for someone who has a group.
        expect((s.subjectId, s.level, s.note), (null, null, null));
        for (final key in [
          'qabul-first',
          'qabul-last',
          'qabul-phone',
          'qabul-parent-phone',
          'qabul-address',
        ]) {
          expect(field(tester, key).controller!.text, '', reason: key);
        }
        // The course search stays; the cursor is back in it.
        expect(field(tester, 'qabul-group-search').controller!.text, 'ingliz');
        expect(focusedLabel(), 'qabul-search');
        expect(chosen(tester, 'group-1'), isFalse);
        expect(find.text('Saqlandi'), findsOneWidget);
        expect(find.text('Qaytarish'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets('parent phone and address are optional', (tester) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await typeInto(tester, 'qabul-group-search', 'ingliz');
      await tester.tap(find.byKey(const ValueKey('group-2')));
      await fill(tester);
      await tester.ensureVisible(find.text('Saqlash'));
      await tester.tap(find.text('Saqlash'));
      await tester.pumpAndSettle();
      final s = saver.saves.single;
      expect((s.parentPhone, s.address), (null, null));
    });

    testWidgets(
      'Enter in the course search picks the only match and moves to the name',
      (tester) async {
        await pumpPage(tester);
        await typeInto(tester, 'qabul-group-search', 'fransuz');
        await tester.tap(find.byKey(const ValueKey('qabul-group-search')));
        await tester.pump();
        await enter(tester);
        expect(chosen(tester, 'group-3'), isTrue);
        expect(focusedLabel(), 'qabul-first');
      },
    );

    testWidgets(
      '"Guruhsiz saqlash" keeps the subject, level and a note about time and days',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await tester.ensureVisible(
          find.byKey(const ValueKey('save-groupless')),
        );
        await tester.tap(find.byKey(const ValueKey('save-groupless')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('wish-panel')), findsOneWidget);
        await tester.tap(find.widgetWithText(OptionPill, 'Fransuz tili'));
        await tester.tap(find.widgetWithText(OptionPill, 'IELTS'));
        await tester.pump();
        expect(field(tester, 'wish-level').controller!.text, 'IELTS');
        await typeInto(tester, 'wish-level', 'A1');
        await typeInto(tester, 'wish-note', 'kechqurun, du-chor-ju');
        await fill(tester);
        await enter(tester);
        await tester.pumpAndSettle();
        final s = saver.saves.single;
        expect(s.groupId, isNull);
        expect(
          (s.subjectId, s.level, s.note),
          (2, 'A1', 'kechqurun, du-chor-ju'),
        );
        // Cleared: the next person starts from nothing again.
        expect(find.byKey(const ValueKey('wish-panel')), findsNothing);
      },
    );

    testWidgets(
      'without a group, and without "Guruhsiz saqlash", nothing is saved',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await fill(tester);
        await enter(tester);
        await tester.pump();
        expect(saver.saves, isEmpty);
        expect(find.textContaining('Kursni tanlang'), findsOneWidget);
        expect(focusedLabel(), 'qabul-search');
        expect(field(tester, 'qabul-first').controller!.text, 'Ali');
      },
    );

    testWidgets('"Guruhsiz saqlash" needs a subject', (tester) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await tester.ensureVisible(find.byKey(const ValueKey('save-groupless')));
      await tester.tap(find.byKey(const ValueKey('save-groupless')));
      await tester.pumpAndSettle();
      await fill(tester);
      await enter(tester);
      await tester.pump();
      expect(saver.saves, isEmpty);
      expect(find.text('Fanni tanlang.'), findsOneWidget);
    });

    testWidgets(
      'a missing name, surname or phone saves nothing and puts the cursor there',
      (tester) async {
        final saver = FakeSaver();
        await pumpPage(tester, saver: saver);
        await typeInto(tester, 'qabul-group-search', 'ingliz');
        await tester.tap(find.byKey(const ValueKey('group-1')));
        await tester.pump();
        await enter(tester);
        await tester.pump();
        expect(find.text('Ismni kiriting'), findsOneWidget);
        expect(find.text('Familiyani kiriting'), findsOneWidget);
        expect(focusedLabel(), 'qabul-first');
        await typeInto(tester, 'qabul-first', 'Ali');
        await typeInto(tester, 'qabul-last', 'Valiyev');
        await typeInto(tester, 'qabul-phone', '9012');
        await enter(tester);
        await tester.pump();
        expect(find.text('Telefon to\'liq emas'), findsOneWidget);
        expect(focusedLabel(), 'qabul-phone');
        expect(saver.saves, isEmpty);
        // A half-typed parent phone is refused too.
        await typeInto(tester, 'qabul-phone', '901234567');
        await typeInto(tester, 'qabul-parent-phone', '9355');
        await enter(tester);
        await tester.pump();
        expect(saver.saves, isEmpty);
      },
    );

    testWidgets(
      'the phone starts with +998 and masks what is typed or pasted',
      (tester) async {
        await pumpPage(tester);
        expect(find.text('+998'), findsNWidgets(2));
        await typeInto(tester, 'qabul-phone', '901234567');
        expect(field(tester, 'qabul-phone').controller!.text, '90 123 45 67');
        await typeInto(tester, 'qabul-phone', '+998 90 111 22 33 99');
        expect(field(tester, 'qabul-phone').controller!.text, '90 111 22 33');
      },
    );

    testWidgets('holding Enter saves one person, not many', (tester) async {
      final saver = FakeSaver()..hold = Completer<void>();
      await pumpPage(tester, saver: saver);
      await typeInto(tester, 'qabul-group-search', 'ingliz');
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
      await typeInto(tester, 'qabul-group-search', 'ingliz');
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await fill(tester);
      await enter(tester);
      await tester.pumpAndSettle();
      expect(field(tester, 'qabul-first').controller!.text, 'Ali');
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
      await typeInto(tester, 'qabul-group-search', 'ingliz');
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await typeInto(tester, 'qabul-group-search', 'fransuz');
      await tester.pumpAndSettle();
      await fill(tester);
      await enter(tester);
      await tester.pump();
      // The old choice is gone; nothing is saved against a group nobody can see.
      expect(saver.saves, isEmpty);
    });

    testWidgets('Qaytarish undoes that save', (tester) async {
      final saver = FakeSaver();
      await pumpPage(tester, saver: saver);
      await typeInto(tester, 'qabul-group-search', 'ingliz');
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await fill(tester, name: 'Ali');
      await enter(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Qaytarish'));
      await tester.pumpAndSettle();
      expect(saver.undone, ['client-0']);
      expect(find.text('Ali Valiyev qaytarildi.'), findsOneWidget);
    });

    testWidgets('a refused save says why', (tester) async {
      final saver = FakeSaver()..settle = Completer<QuickSaveResult>();
      await pumpPage(tester, saver: saver);
      await typeInto(tester, 'qabul-group-search', 'ingliz');
      await tester.tap(find.byKey(const ValueKey('group-1')));
      await fill(tester);
      await enter(tester);
      await tester.pump();
      expect(find.text('Saqlandi'), findsOneWidget); // at once, before the send
      saver.settle!.complete(
        const QuickSaveResult(SaveState.refused, 'Telefon noto\'g\'ri'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Ali Valiyev saqlanmadi: Telefon noto\'g\'ri'),
        findsOneWidget,
      );
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
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OptionPill, 'Ingliz tili'));
        await fill(tester);
        await enter(tester);
        await tester.pumpAndSettle();
        expect(saver.saves.single.groupId, isNull);
      },
    );

    testWidgets('the form is centred in the page', (tester) async {
      await pumpPage(tester);
      final card = tester.getRect(find.byKey(const ValueKey('qabul-first')));
      expect(card.left, greaterThan(200));
    });
  });

  group('warnings that never block', () {
    testWidgets(
      'a known student phone and the same name and surname are warned about, and still saved',
      (tester) async {
        final saver = FakeSaver();
        final qabul = FakeQabul()
          ..duplicateResult = DuplicateCheck(
            phoneStudent: const SimilarStudent(
              id: 5,
              fullName: 'Nodira Ismoilova',
              phone: '998901234567',
              groups: ['Ingliz tili, Beginner A'],
            ),
            nameLeads: const [
              SimilarLead(
                id: 8,
                fullName: 'Ali Valiyev',
                phone: '998935550000',
                groupName: 'Matematika',
              ),
            ],
          );
        await pumpPage(tester, saver: saver, qabul: qabul);
        await typeInto(tester, 'qabul-group-search', 'ingliz');
        await tester.tap(find.byKey(const ValueKey('group-1')));
        await fill(tester);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('duplicate-warning')), findsOneWidget);
        expect(
          find.textContaining(
            'Bu raqam o\'quvchiniki: Nodira Ismoilova (Ingliz tili, Beginner A)',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Xuddi shu ism-familiya bilan saqlangan: Ali Valiyev',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('bir nechta guruhda o\'qishi mumkin'),
          findsOneWidget,
        );
        // Saving is not blocked.
        await enter(tester);
        await tester.pumpAndSettle();
        expect(saver.saves, hasLength(1));
        expect(find.byKey(const ValueKey('duplicate-warning')), findsNothing);
      },
    );

    testWidgets(
      'the check waits for a complete phone, and for both name and surname',
      (tester) async {
        final qabul = FakeQabul();
        await pumpPage(tester, qabul: qabul);
        await typeInto(tester, 'qabul-first', 'Ali');
        await typeInto(tester, 'qabul-phone', '9012');
        await tester.pump(const Duration(seconds: 1));
        expect(qabul.duplicateAsks, isEmpty);
        await typeInto(tester, 'qabul-last', 'Valiyev');
        await tester.pump(const Duration(seconds: 1));
        expect(qabul.duplicateAsks.last.name, 'Ali Valiyev');
        expect(qabul.duplicateAsks.last.phone, '');
        await typeInto(tester, 'qabul-phone', '901234567');
        await tester.pump(const Duration(seconds: 1));
        expect(qabul.duplicateAsks.last.phone, '998901234567');
      },
    );

    testWidgets('a long list of matches is cut to four lines and a count', (
      tester,
    ) async {
      final qabul = FakeQabul()
        ..duplicateResult = DuplicateCheck(
          phoneLeads: [
            for (var i = 1; i <= 6; i++)
              SimilarLead(
                id: i,
                fullName: 'Ali Valiyev',
                phone: '99890000000$i',
                groupName: 'Matematika',
              ),
          ],
        );
      await pumpPage(tester, qabul: qabul);
      await fill(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Bu raqam bilan saqlangan'), findsNWidgets(4));
      expect(find.text('...va yana 2 ta'), findsOneWidget);
    });

    testWidgets('nothing found shows no warning', (tester) async {
      await pumpPage(tester);
      await fill(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('duplicate-warning')), findsNothing);
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
        expect(find.text('Kutmoqda'), findsOneWidget);
        expect(find.text('O\'quvchi qilish'), findsNWidgets(2));
        expect(find.text('Arxiv'), findsNWidgets(2));
        // Nothing that is not listed.
        for (final word in ['Sinov', 'Jami', 'Filter', 'Qayta ochish']) {
          expect(find.textContaining(word), findsNothing, reason: word);
        }
        expect(find.byKey(const ValueKey('row-more')), findsNothing);
      },
    );

    testWidgets(
      'people with no group show as "Kutmoqda" and are counted by what they want',
      (tester) async {
        Lead wait(int id, String subject, String level) => Lead(
          id: id,
          clientId: 'c-$id',
          fullName: 'Kutuvchi $id',
          phone: '99890000000$id',
          subjectName: subject,
          level: level,
          note: 'kechqurun',
          stage: 'new',
          version: 1,
          createdAt: DateTime.now(),
        );
        final admissions = FakeAdmissions()
          ..leads = [
            wait(1, 'Fransuz tili', 'A1'),
            wait(2, 'Fransuz tili', 'A1'),
            wait(3, 'Ingliz tili', 'IELTS'),
            lead(
              4,
              'Guruhdagi',
              groupId: 1,
              groupName: 'Ingliz tili, Beginner A',
            ),
          ];
        await pumpPage(tester, admissions: admissions, view: QabulView.list);
        expect(find.text('Kutmoqda'), findsNWidgets(3));
        expect(find.text('Fransuz tili · A1'), findsNWidgets(2));
        expect(find.text('kechqurun'), findsNWidgets(3));
        // The demand summary: who is waiting for what, most wanted first.
        expect(find.byKey(const ValueKey('demand')), findsOneWidget);
        expect(find.text('Fransuz tili · A1: 2 kishi'), findsOneWidget);
        expect(find.text('Ingliz tili · IELTS: 1 kishi'), findsOneWidget);
        // Someone who has a group is not counted as waiting.
        expect(find.text('Ingliz tili: 1 kishi'), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('demand')),
            matching: find.byType(StatusChip),
          ),
          findsNWidgets(2),
        );
      },
    );

    testWidgets('no one waiting, no summary', (tester) async {
      final admissions = FakeAdmissions()
        ..leads = [
          lead(
            4,
            'Guruhdagi',
            groupId: 1,
            groupName: 'Ingliz tili, Beginner A',
          ),
        ];
      await pumpPage(tester, admissions: admissions, view: QabulView.list);
      expect(find.byKey(const ValueKey('demand')), findsNothing);
    });

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
