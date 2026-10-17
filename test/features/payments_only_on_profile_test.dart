import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/debtors/data/debtors_repository.dart';
import 'package:expert_edu_center/features/debtors/presentation/debtors_screen.dart';
import 'package:expert_edu_center/features/students/presentation/open_student.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

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
}
