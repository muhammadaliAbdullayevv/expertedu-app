import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/billing/data/transactions_repository.dart';
import 'package:expert_edu_center/features/enrollments/data/enrollments_repository.dart';
import 'package:expert_edu_center/features/photos/photos_repository.dart';
import 'package:expert_edu_center/features/students/data/student_models.dart';
import 'package:expert_edu_center/features/students/data/students_repository.dart';
import 'package:expert_edu_center/features/students/presentation/student_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';
import 'students_page_test.dart' hide main;

/// Archiving, removing from a group, moving to another group, putting a group
/// back, and the Amallar tab -- on the student's profile.

Future<void> pumpPanel(
  WidgetTester tester,
  Rig rig, {
  required int studentId,
  int? groupId,
}) async {
  tester.view.physicalSize = const Size(900, 1300);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studentsRepositoryProvider.overrideWithValue(rig.students),
        transactionsRepositoryProvider.overrideWithValue(rig.transactions),
        enrollmentsRepositoryProvider.overrideWithValue(rig.enrollments),
        qabulRepositoryProvider.overrideWithValue(rig.qabul),
        photosRepositoryProvider.overrideWithValue(rig.photos),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 440,
              height: 1200,
              child: StudentPanel(
                studentId: studentId,
                groupId: groupId,
                onChanged: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('panel-menu')));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String key) async {
  await openMenu(tester);
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Dilnoza: Fransuz tili (owes 100 000) and Matematika 9 (paid up).
Rig twoGroupRig({int debt = 0}) {
  final rig = Rig(
    rows: [
      row(2, 'Dilnoza Ergasheva', groups: [english, math]),
    ],
    profiles: {
      2: profile(
        2,
        'Dilnoza Ergasheva',
        balance: 100000,
        groups: [
          pgroup(21, 1, 'Fransuz tili, A1', balance: 100000),
          pgroup(22, 2, 'Matematika 9', teacher: 'Jasur Rahimov'),
        ],
      ),
    },
  );
  rig.students.debtToReport = debt;
  return rig;
}

void main() {
  setUpAll(loadAppFonts);

  group('the three dots depend on where the profile was opened', () {
    testWidgets('from O\'quvchilar: archive, never "remove from this group"', (
      tester,
    ) async {
      await pumpPanel(tester, twoGroupRig(), studentId: 2);
      await openMenu(tester);
      expect(find.byKey(const ValueKey('menu-archive')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-transfer')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-add-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-remove-group')), findsNothing);
      expect(find.byKey(const ValueKey('menu-unarchive')), findsNothing);
    });

    testWidgets('from a group\'s page: remove from THIS group, never archive', (
      tester,
    ) async {
      await pumpPanel(tester, twoGroupRig(), studentId: 2, groupId: 1);
      await openMenu(tester);
      expect(find.byKey(const ValueKey('menu-remove-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-transfer')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-archive')), findsNothing);
      expect(find.byKey(const ValueKey('menu-unarchive')), findsNothing);
    });

    testWidgets('an archived student: "Arxivdan chiqarish" instead', (
      tester,
    ) async {
      final rig = twoGroupRig();
      rig.students.profiles[2] = profile(
        2,
        'Dilnoza Ergasheva',
        balance: 0,
        archivedAt: DateTime.now(),
        groups: [
          pgroup(21, 1, 'Fransuz tili, A1', status: 'withdrawn'),
          pgroup(22, 2, 'Matematika 9', status: 'withdrawn'),
        ],
      );
      await pumpPanel(tester, rig, studentId: 2);
      expect(find.byKey(const ValueKey('panel-archived')), findsOneWidget);
      await openMenu(tester);
      expect(find.byKey(const ValueKey('menu-unarchive')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-archive')), findsNothing);
      // He is in no group, so there is nothing to move.
      expect(find.byKey(const ValueKey('menu-transfer')), findsNothing);
    });
  });

  group('archiving', () {
    testWidgets('asks why and refuses to go on without a reason', (
      tester,
    ) async {
      final rig = twoGroupRig(debt: 100000);
      await pumpPanel(tester, rig, studentId: 2);
      await choose(tester, 'menu-archive');
      await tester.tap(find.byKey(const ValueKey('reason-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reason-error')), findsOneWidget);
      expect(rig.students.archives, isEmpty);
    });

    testWidgets('says what he owes, then archives with the reason', (
      tester,
    ) async {
      final rig = twoGroupRig(debt: 100000);
      await pumpPanel(tester, rig, studentId: 2);
      await choose(tester, 'menu-archive');
      expect(
        plain(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byKey(const ValueKey('reason-debt')),
                  matching: find.byType(Text),
                ),
              )
              .data!,
        ),
        'Barcha guruhlar bo\'yicha qarz: 100 000 so\'m',
      );
      // The groups he will leave are named.
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('reason-explain'))).data,
        contains('Fransuz tili, A1'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('reason-note')),
        '  Ko\'chib ketdi ',
      );
      await tester.tap(find.byKey(const ValueKey('reason-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.archives, [(id: 2, note: 'Ko\'chib ketdi')]);
      expect(find.byKey(const ValueKey('reason-note')), findsNothing);
    });
  });

  group('removing from one group', () {
    testWidgets('names the group, says if he paid everything, needs a reason', (
      tester,
    ) async {
      final rig = twoGroupRig(debt: 100000);
      await pumpPanel(tester, rig, studentId: 2, groupId: 1);
      await choose(tester, 'menu-remove-group');
      expect(find.text('Dilnoza Ergasheva · Fransuz tili, A1'), findsOneWidget);
      // The debt shown is THIS group's (100 000), read from the profile.
      expect(
        plain(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byKey(const ValueKey('reason-debt')),
                  matching: find.byType(Text),
                ),
              )
              .data!,
        ),
        'Bu guruh bo\'yicha qarz: 100 000 so\'m',
      );
      await tester.tap(find.byKey(const ValueKey('reason-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.removals, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('reason-note')),
        'Vaqti to\'g\'ri kelmadi',
      );
      await tester.tap(find.byKey(const ValueKey('reason-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.removals, [
        (id: 2, groupId: 1, note: 'Vaqti to\'g\'ri kelmadi'),
      ]);
    });

    testWidgets('a group paid in full says there is no debt', (tester) async {
      final rig = twoGroupRig();
      await pumpPanel(tester, rig, studentId: 2, groupId: 2);
      await choose(tester, 'menu-remove-group');
      expect(
        plain(
          tester
              .widget<Text>(
                find.descendant(
                  of: find.byKey(const ValueKey('reason-debt')),
                  matching: find.byType(Text),
                ),
              )
              .data!,
        ),
        'Bu guruh bo\'yicha qarz yo\'q — barcha to\'lovlar to\'langan',
      );
      await tester.enterText(
        find.byKey(const ValueKey('reason-note')),
        'Kursni tugatdi',
      );
      await tester.tap(find.byKey(const ValueKey('reason-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.removals.single.groupId, 2);
    });
  });

  group('unarchiving', () {
    testWidgets('needs no reason and puts no group back by itself', (
      tester,
    ) async {
      final rig = twoGroupRig();
      rig.students.profiles[2] = profile(
        2,
        'Dilnoza Ergasheva',
        balance: 0,
        archivedAt: DateTime.now(),
        groups: [pgroup(21, 1, 'Fransuz tili, A1', status: 'withdrawn')],
      );
      await pumpPanel(tester, rig, studentId: 2);
      await choose(tester, 'menu-unarchive');
      await tester.tap(find.byKey(const ValueKey('reason-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.unarchives, [(id: 2, note: null)]);
      expect(rig.students.added, isEmpty);
    });
  });

  group('changing groups', () {
    Future<void> openTransfer(
      WidgetTester tester,
      Rig rig, {
      int? groupId,
    }) async {
      await pumpPanel(tester, rig, studentId: 2, groupId: groupId);
      await choose(tester, 'menu-transfer');
    }

    testWidgets('two current groups: pick one, then the new one', (
      tester,
    ) async {
      final rig = twoGroupRig(debt: 100000);
      await openTransfer(tester, rig);
      // Both current groups are offered; nothing is chosen yet.
      expect(find.byKey(const ValueKey('transfer-from-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('transfer-from-2')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('transfer-search')),
        'beginner',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transfer-to-7')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('transfer-confirm')),
            )
            .onPressed,
        isNull,
        reason: 'which group does he leave?',
      );
      await tester.tap(find.byKey(const ValueKey('transfer-from-1')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('transfer-confirm')),
            )
            .onPressed,
        isNotNull,
      );
      // The first bill is the NEW group's, and the old debt is called out.
      expect(
        plain(
          tester.widget<Text>(find.byKey(const ValueKey('transfer-due'))).data!,
        ),
        '150 000 so\'m',
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('transfer-old-debt')),
                matching: find.byType(Text),
              ),
            )
            .data!
            .replaceAll(RegExp(r'[\u00a0\u202f]'), ' '),
        contains('Eski guruhdan qarz: 100 000'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('transfer-note')),
        'Daraja oshdi',
      );
      await tester.tap(find.byKey(const ValueKey('transfer-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.transfers, [
        (id: 2, from: 1, to: 7, note: 'Daraja oshdi'),
      ]);
    });

    testWidgets('opened from a group\'s page it starts on that group', (
      tester,
    ) async {
      final rig = twoGroupRig();
      await openTransfer(tester, rig, groupId: 2);
      await tester.enterText(
        find.byKey(const ValueKey('transfer-search')),
        'beginner',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transfer-to-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transfer-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.transfers.single.from, 2);
      // A group with nothing owed shows no old-debt note.
    });

    testWidgets(
      'a single current group is already chosen; no old-debt note when paid up',
      (tester) async {
        final rig = Rig(
          rows: [row(3, 'Madina Qodirova')],
          profiles: {
            2: profile(
              2,
              'Madina Qodirova',
              balance: 0,
              groups: [pgroup(21, 1, 'Fransuz tili, A1')],
            ),
          },
        );
        await openTransfer(tester, rig);
        await tester.enterText(
          find.byKey(const ValueKey('transfer-search')),
          'beginner',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('transfer-to-7')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('transfer-old-debt')), findsNothing);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('transfer-confirm')),
              )
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('the groups he is already in are not offered as the new one', (
      tester,
    ) async {
      await openTransfer(tester, twoGroupRig());
      await tester.enterText(
        find.byKey(const ValueKey('transfer-search')),
        'a',
      );
      await tester.pumpAndSettle();
      // Fransuz tili, A1 is group 1 -- he is in it.
      expect(find.byKey(const ValueKey('transfer-to-1')), findsNothing);
      expect(find.byKey(const ValueKey('transfer-to-7')), findsOneWidget);
    });
  });

  group('groups he left', () {
    Rig leftRig({DateTime? archivedAt}) {
      final rig = twoGroupRig();
      rig.students.profiles[2] = profile(
        2,
        'Dilnoza Ergasheva',
        balance: 0,
        archivedAt: archivedAt,
        groups: [
          pgroup(31, 7, 'Beginner A', status: 'withdrawn'),
          pgroup(22, 2, 'Matematika 9', teacher: 'Jasur Rahimov'),
        ],
      );
      return rig;
    }

    testWidgets('are shown faded, frozen, with an activate button', (
      tester,
    ) async {
      await pumpPanel(tester, leftRig(), studentId: 2);
      expect(find.byKey(const ValueKey('group-card-7')), findsOneWidget);
      expect(find.byKey(const ValueKey('frozen-7')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('frozen-7'))).data,
        startsWith('Muzlatilgan'),
      );
      expect(find.byKey(const ValueKey('activate-7')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('group-card-7')),
          matching: find.byType(Opacity),
        ),
        findsWidgets,
      );
      // The group he is in is not frozen and has no such button.
      expect(find.byKey(const ValueKey('frozen-2')), findsNothing);
      expect(find.byKey(const ValueKey('activate-2')), findsNothing);
    });

    testWidgets(
      'the button sits on the group\'s top row, beside the paid / unpaid chip',
      (tester) async {
        await pumpPanel(tester, leftRig(), studentId: 2);
        final card = find.byKey(const ValueKey('group-card-7'));
        final chip = find.descendant(
          of: card,
          matching: find.text('To\'langan'),
        );
        final button = find.byKey(const ValueKey('activate-7'));
        final name = find.descendant(
          of: card,
          matching: find.text('Beginner A'),
        );
        expect(
          (tester.getCenter(chip).dy - tester.getCenter(button).dy).abs(),
          lessThan(6),
        );
        expect(
          (tester.getCenter(name).dy - tester.getCenter(button).dy).abs(),
          lessThan(6),
        );
        expect(
          tester.getCenter(chip).dx,
          lessThan(tester.getCenter(button).dx),
        );
      },
    );

    testWidgets('activating opens the group already chosen and adds him back', (
      tester,
    ) async {
      final rig = leftRig();
      await pumpPanel(tester, rig, studentId: 2);
      await tester.tap(find.byKey(const ValueKey('activate-7')));
      await tester.pumpAndSettle();
      expect(find.text('Guruhni faollashtirish'), findsWidgets);
      expect(find.byKey(const ValueKey('add-due')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-confirm')));
      await tester.pumpAndSettle();
      expect(rig.students.added.map((a) => (a.id, a.groupId)), [(2, 7)]);
    });

    testWidgets('an archived student with a debt can still pay it', (
      tester,
    ) async {
      final rig = twoGroupRig();
      rig.students.profiles[2] = profile(
        2,
        'Dilnoza Ergasheva',
        balance: 100000,
        archivedAt: DateTime.now(),
        groups: [
          pgroup(
            21,
            1,
            'Fransuz tili, A1',
            status: 'withdrawn',
            balance: 100000,
          ),
        ],
      );
      await pumpPanel(tester, rig, studentId: 2);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('panel-pay')))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('the old debt reminder', () {
    testWidgets('shows until the first payment on the new group', (
      tester,
    ) async {
      final rig = twoGroupRig();
      rig.students.profiles[2] = profile(
        2,
        'Dilnoza Ergasheva',
        balance: 100000,
        groups: [
          pgroup(31, 7, 'Beginner A'),
          pgroup(
            21,
            1,
            'Fransuz tili, A1',
            status: 'withdrawn',
            balance: 100000,
          ),
        ],
        notices: [
          TransferNotice(
            fromGroupId: 1,
            fromGroupName: 'Fransuz tili, A1',
            toGroupId: 7,
            toGroupName: 'Beginner A',
            debt: 100000,
            at: DateTime.now(),
          ),
        ],
      );
      await pumpPanel(tester, rig, studentId: 2);
      final notice = find.byKey(const ValueKey('transfer-notice-1'));
      expect(notice, findsOneWidget);
      final text = plain(
        tester
            .widget<Text>(
              find.descendant(of: notice, matching: find.byType(Text)),
            )
            .data!,
      );
      expect(
        text,
        contains('Eski guruhdan qarz: Fransuz tili, A1 — 100 000 so\'m'),
      );
      expect(text, contains('birinchi to\'lov qilinguncha'));
    });

    testWidgets('is absent when there is nothing to remind', (tester) async {
      await pumpPanel(tester, twoGroupRig(), studentId: 2);
      expect(find.byKey(const ValueKey('transfer-notice-1')), findsNothing);
    });
  });

  group('Amallar', () {
    Future<void> openActions(WidgetTester tester, Rig rig) async {
      await pumpPanel(tester, rig, studentId: 2);
      await tester.tap(find.byKey(const ValueKey('panel-tab-4')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists each action with its reason, debt and who did it', (
      tester,
    ) async {
      final rig = twoGroupRig();
      final now = DateTime.now();
      rig.students.profiles[2] = profile(
        2,
        'Dilnoza Ergasheva',
        balance: 0,
        events: [
          StudentEvent(
            id: 4,
            kind: 'archived',
            note: 'Ko\'chib ketdi',
            debt: 100000,
            byName: 'Admin',
            at: now,
          ),
          StudentEvent(
            id: 3,
            kind: 'removed',
            groupId: 1,
            groupName: 'Fransuz tili, A1',
            note: 'Ko\'chib ketdi',
            debt: 0,
            at: now,
          ),
          StudentEvent(
            id: 2,
            kind: 'transferred',
            groupId: 2,
            groupName: 'Matematika 9',
            toGroupId: 1,
            toGroupName: 'Fransuz tili, A1',
            debt: 50000,
            at: now,
          ),
          StudentEvent(
            id: 1,
            kind: 'added',
            groupId: 2,
            groupName: 'Matematika 9',
            at: now,
          ),
        ],
      );
      await openActions(tester, rig);
      expect(find.text('Arxivga o\'tkazildi'), findsOneWidget);
      expect(find.text('Guruhdan chiqarildi'), findsOneWidget);
      expect(find.text('Guruh almashtirildi'), findsOneWidget);
      expect(find.text('Matematika 9 → Fransuz tili, A1'), findsOneWidget);
      expect(find.text('Guruhga qo\'shildi'), findsOneWidget);
      expect(find.text('Izoh: Ko\'chib ketdi'), findsNWidgets(2));
      expect(find.text('Admin'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && plain(w.data ?? '') == 'Qarzi: 100 000 so\'m',
        ),
        findsOneWidget,
      );
      expect(find.text('Qarzi yo\'q — hammasi to\'langan'), findsOneWidget);
    });

    testWidgets('with nothing done yet it says so', (tester) async {
      await openActions(tester, twoGroupRig());
      expect(find.byKey(const ValueKey('actions-empty')), findsOneWidget);
    });

    testWidgets('the tab sits right after Izohlar', (tester) async {
      await pumpPanel(tester, twoGroupRig(), studentId: 2);
      final izoh = tester.getCenter(find.text('Izohlar'));
      final actions = tester.getCenter(find.text('Amallar'));
      expect(actions.dx, greaterThan(izoh.dx));
      expect((actions.dy - izoh.dy).abs(), lessThan(2));
    });
  });
}
