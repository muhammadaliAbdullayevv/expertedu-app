import 'dart:ui' show Tristate;

import 'package:expert_edu_center/app/navigation/destinations.dart';
import 'package:expert_edu_center/app/shell/app_sidebar.dart';
import 'package:expert_edu_center/app/shell/phone_bottom_bar.dart';
import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/core/widgets/status_chip.dart';
import 'package:expert_edu_center/features/dashboard/presentation/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  setUpAll(loadAppFonts);

  group('theme tokens', () {
    test('one accent, the V2 palette', () {
      expect(AppColors.accent, const Color(0xFF5B4DDB));
      expect(AppColors.accentSoft, const Color(0xFFEFEDFD));
      expect(AppColors.canvas, const Color(0xFFF7F7F5));
      expect(AppRadius.card, 14);
      expect(AppRadius.button, 10);
      final theme = AppTheme.light();
      expect(theme.colorScheme.primary, AppColors.accent);
      expect(theme.textTheme.bodyMedium?.fontFamily, 'DM Sans');
    });

    testWidgets('status chips always show their text', (tester) async {
      await tester.pumpWidget(
        host(
          Column(
            children: [
              for (final tone in StatusTone.values)
                StatusChip('Matn ${tone.name}', tone: tone),
            ],
          ),
        ),
      );
      for (final tone in StatusTone.values) {
        expect(find.text('Matn ${tone.name}'), findsOneWidget);
      }
    });
  });

  group('sidebar', () {
    Widget sidebar({
      AppRole role = AppRole.owner,
      Destination selected = Destination.today,
      ValueChanged<Destination>? onSelect,
      bool compact = false,
    }) => host(
      Row(
        children: [
          AppSidebar(
            role: role,
            selected: selected,
            onSelect: onSelect ?? (_) {},
            counts: const {
              Destination.admissions: 4,
              Destination.students: 125,
            },
            userName: 'Madina Karimova',
            onUserTap: () {},
            compact: compact,
          ),
        ],
      ),
    );

    testWidgets('groups, badges and the user card', (tester) async {
      await tester.pumpWidget(sidebar());
      expect(find.text('ISH STOLI'), findsOneWidget);
      expect(find.text('BOSHQARUV'), findsOneWidget);
      for (final label in [
        'Bugun',
        'Qabul',
        'O\'quvchilar',
        'Jadval',
        'Guruhlar',
        'O\'qituvchilar',
        'Moliya',
        'Hisobotlar',
        'Sozlamalar',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('125'), findsOneWidget);
      // Qabul never shows a number, even when one is passed in.
      expect(find.text('4'), findsNothing);
      expect(find.text('MK'), findsOneWidget);
      expect(find.text('Madina Karimova'), findsOneWidget);
      expect(find.text('Egasi'), findsOneWidget);
    });

    testWidgets(
      'on local test data the sidebar says so; on the real server it does not',
      (tester) async {
        await tester.pumpWidget(sidebar());
        expect(find.text('Mahalliy rejim'), findsNothing);
        await tester.pumpWidget(
          host(
            Row(
              children: [
                AppSidebar(
                  role: AppRole.owner,
                  selected: Destination.today,
                  onSelect: (_) {},
                  userName: 'Madina Karimova',
                  onUserTap: () {},
                  localMode: true,
                ),
              ],
            ),
          ),
        );
        expect(find.text('Mahalliy rejim'), findsOneWidget);
      },
    );

    testWidgets('an admin gets Hisobotlar but no Moliya', (tester) async {
      await tester.pumpWidget(sidebar(role: AppRole.admin));
      expect(find.text('Moliya'), findsNothing);
      expect(find.text('Hisobotlar'), findsOneWidget);
      expect(find.text('Ma\'mur'), findsOneWidget);
    });

    testWidgets('a teacher gets two items and Sozlamalar', (tester) async {
      await tester.pumpWidget(sidebar(role: AppRole.teacher));
      expect(find.text('Bugun'), findsOneWidget);
      expect(find.text('Jadval'), findsOneWidget);
      expect(find.text('Sozlamalar'), findsOneWidget);
      expect(find.text('Qabul'), findsNothing);
      expect(find.text('BOSHQARUV'), findsNothing);
    });

    testWidgets('tapping selects a destination', (tester) async {
      Destination? picked;
      await tester.pumpWidget(sidebar(onSelect: (d) => picked = d));
      await tester.tap(find.text('Jadval'));
      expect(picked, Destination.timetable);
      await tester.tap(find.text('Sozlamalar'));
      expect(picked, Destination.settings);
    });

    testWidgets('the selected item is marked for screen readers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(sidebar(selected: Destination.students));
      final selected = tester.getSemantics(
        find.bySemanticsLabel('O\'quvchilar').first,
      );
      expect(selected.flagsCollection.isSelected, Tristate.isTrue);
      expect(selected.flagsCollection.isButton, isTrue);
      final other = tester.getSemantics(find.bySemanticsLabel('Jadval').first);
      expect(other.flagsCollection.isSelected, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('the compact rail keeps tooltips, drops labels', (
      tester,
    ) async {
      await tester.pumpWidget(sidebar(compact: true));
      expect(find.text('Bugun'), findsNothing);
      expect(find.byTooltip('Bugun'), findsOneWidget);
      expect(find.byTooltip('Moliya'), findsOneWidget);
    });
  });

  group('phone bottom bar', () {
    Widget bar(AppRole role, {ValueChanged<Destination>? onSelect}) => host(
      Column(
        children: [
          const Spacer(),
          PhoneBottomBar(
            layout: phoneBarFor(role),
            selected: Destination.today,
            onSelect: onSelect ?? (_) {},
          ),
        ],
      ),
    );

    testWidgets('has the destinations and no payment button', (tester) async {
      await tester.pumpWidget(bar(AppRole.owner));
      // Payments are taken on a student's profile only.
      expect(find.bySemanticsLabel('To\'lov qabul qilish'), findsNothing);
      expect(find.text('To\'lov qabul qilish'), findsNothing);
      expect(find.text('Bugun'), findsOneWidget);
      expect(find.text('O\'quvchi'), findsOneWidget);
      expect(find.text('Moliya'), findsOneWidget);
    });

    testWidgets('touch targets are at least 44 high', (tester) async {
      await tester.pumpWidget(bar(AppRole.owner));
      for (final label in ['Bugun', 'O\'quvchi', 'Jadval', 'Moliya']) {
        final size = tester.getSize(
          find
              .ancestor(of: find.text(label), matching: find.byType(InkWell))
              .first,
        );
        expect(size.height, greaterThanOrEqualTo(44), reason: label);
      }
    });

    testWidgets('selecting a tab', (tester) async {
      Destination? picked;
      await tester.pumpWidget(bar(AppRole.admin, onSelect: (d) => picked = d));
      expect(find.text('Moliya'), findsNothing);
      await tester.tap(find.text('Hisobotlar'));
      expect(picked, Destination.reports);
    });

    testWidgets('a teacher has no payment button', (tester) async {
      await tester.pumpWidget(bar(AppRole.teacher));
      expect(find.bySemanticsLabel('To\'lov qabul qilish'), findsNothing);
    });
  });

  test('the date line reads "Shanba, 17-oktyabr"', () {
    expect(uzLongDate(DateTime(2026, 10, 17)), 'Shanba, 17-oktyabr');
    expect(uzLongDate(DateTime(2026, 1, 5)), 'Dushanba, 5-yanvar');
    expect(uzLongDate(DateTime(2026, 12, 31)), 'Payshanba, 31-dekabr');
  });
}
