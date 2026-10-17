import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/debtors/data/debtors_repository.dart';
import 'package:expert_edu_center/features/debtors/presentation/debtors_screen.dart';
import 'package:expert_edu_center/features/groups/data/groups_repository.dart';
import 'package:expert_edu_center/features/groups/presentation/group_detail_screen.dart';
import 'package:expert_edu_center/features/admissions/data/qabul_repository.dart';
import 'package:expert_edu_center/features/billing/data/transactions_repository.dart';
import 'package:expert_edu_center/features/enrollments/data/enrollments_repository.dart';
import 'package:expert_edu_center/features/students/data/students_repository.dart';
import 'package:expert_edu_center/features/students/presentation/open_student.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';
import 'students_page_test.dart' show Rig, profile;

class FakeDebtors implements DebtorsRepository {
  @override
  Future<List<Debtor>> list() async => [
    Debtor(
      enrollmentId: 11,
      studentId: 7,
      studentFullName: 'Botir Aliyev',
      studentPhone: '998900000001',
      groupId: 1,
      groupName: 'Fransuz tili, A1',
      status: 'active',
      balance: 390000,
      oldestUnpaidDue: DateTime.now().subtract(const Duration(days: 3)),
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeGroups implements GroupsRepository {
  @override
  Future<List<RosterEntry>> roster(
    int groupId, {
    bool includeWithdrawn = false,
  }) async => [
    RosterEntry(
      enrollmentId: 1,
      studentId: 5,
      studentFullName: 'Yangi Odam',
      studentPhone: '998900000005',
      joinedAt: DateTime.now(),
      status: 'active',
      balance: 0,
      isNew: true,
    ),
    RosterEntry(
      enrollmentId: 2,
      studentId: 6,
      studentFullName: 'Eski Odam',
      studentPhone: '998900000006',
      joinedAt: DateTime(2026, 1, 5),
      status: 'active',
      balance: 100000,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Group group() => const Group(
  id: 1,
  name: 'Fransuz tili, A1',
  feeAmount: 390000,
  billingMode: 'fixed_day',
  billingDay: 1,
  isActive: true,
);

void main() {
  setUpAll(loadAppFonts);

  testWidgets(
    'Qarzdorlar has no payment button: a debtor opens the profile instead',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            debtorsRepositoryProvider.overrideWithValue(FakeDebtors()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: DebtorsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('To\'lov'), findsNothing);
      expect(find.text('To\'lov qabul qilish'), findsNothing);
      expect(find.byTooltip('To\'lovlar tarixi'), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DebtorsScreen)),
      );
      await tester.tap(find.byKey(const ValueKey('open-profile-11')));
      await tester.pump();
      expect(container.read(openStudentRequestProvider).value, 7);
    },
  );

  testWidgets('a group\'s list puts new students first, marked Yangi', (
    tester,
  ) async {
    final rig = _rig();
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_groupApp(rig));
    await tester.pumpAndSettle();
    expect(find.text('Yangi'), findsWidgets);
    final names = tester
        .widgetList<Text>(
          find.byWidgetPredicate(
            (w) =>
                w is Text && (w.data == 'Yangi Odam' || w.data == 'Eski Odam'),
          ),
        )
        .map((t) => t.data)
        .toList();
    expect(names.take(2), ['Yangi Odam', 'Eski Odam']);
  });

  testWidgets(
    'a student\'s profile opens right in the group page, as on O\'quvchilar',
    (tester) async {
      final rig = _rig();
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_groupApp(rig));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(GroupDetailScreen)),
      );
      // The first student's profile is already beside the list.
      expect(find.byKey(const ValueKey('panel-name')), findsOneWidget);
      await tester.tap(find.text('Eski Odam'));
      await tester.pumpAndSettle();
      expect(rig.students.profileCalls.last, 6);
      // Still on the group page; nobody was sent to O'quvchilar.
      expect(find.byType(GroupDetailScreen), findsOneWidget);
      expect(container.read(openStudentRequestProvider).value, isNull);
      // The same profile: payment, edit and "Boshqa guruhga qo'shish" are all here.
      expect(find.byKey(const ValueKey('panel-pay')), findsOneWidget);
      expect(find.byKey(const ValueKey('panel-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('panel-add-group')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('panel-pay')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('payment-amount')),
        '1000',
      );
      await tester.tap(find.byKey(const ValueKey('payment-save')));
      await tester.pumpAndSettle();
      expect(rig.transactions.payments.single.amount, 1000);
      expect(find.byType(GroupDetailScreen), findsOneWidget);
    },
  );

  testWidgets('in a narrow window the profile opens over the list instead', (
    tester,
  ) async {
    final rig = _rig();
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_groupApp(rig));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel-name')), findsNothing);
    await tester.tap(find.text('Eski Odam'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel-name')), findsOneWidget);
    expect(find.byType(GroupDetailScreen), findsOneWidget);
  });
}

Rig _rig() => Rig(
  profiles: {
    5: profile(5, 'Yangi Odam', balance: 0),
    6: profile(6, 'Eski Odam'),
  },
);

Widget _groupApp(Rig rig) => ProviderScope(
  overrides: [
    groupsRepositoryProvider.overrideWithValue(FakeGroups()),
    studentsRepositoryProvider.overrideWithValue(rig.students),
    transactionsRepositoryProvider.overrideWithValue(rig.transactions),
    enrollmentsRepositoryProvider.overrideWithValue(rig.enrollments),
    qabulRepositoryProvider.overrideWithValue(rig.qabul),
  ],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: GroupDetailScreen(group: group()),
  ),
);
