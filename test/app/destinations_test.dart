import 'package:expert_edu_center/app/navigation/destinations.dart';
import 'package:expert_edu_center/l10n/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const s = AppStrings.current;

  List<String> labels(Iterable<Destination> items) =>
      items.map((d) => d.label(s)).toList();

  test('the owner sees everything, in the design\'s order', () {
    expect(labels(sectionFor(AppRole.owner, NavSection.work)), [
      'Bugun',
      'Qabul',
      'O\'quvchilar',
      'Jadval',
    ]);
    expect(labels(sectionFor(AppRole.owner, NavSection.manage)), [
      'Guruhlar',
      'O\'qituvchilar',
      'Moliya',
      'Hisobotlar',
    ]);
    expect(menuFor(AppRole.owner), contains(Destination.settings));
  });

  test(
    'the admin sees Moliya too (paying and salary pages are open to them)',
    () {
      expect(menuFor(AppRole.admin), contains(Destination.finance));
      expect(Destination.finance.allowedFor(AppRole.admin), isTrue);
      expect(Destination.finance.allowedFor(AppRole.teacher), isFalse);
      expect(labels(sectionFor(AppRole.admin, NavSection.manage)), [
        'Guruhlar',
        'O\'qituvchilar',
        'Moliya',
        'Hisobotlar',
      ]);
    },
  );

  test('a teacher gets Bugun, Jadval and Sozlamalar only', () {
    expect(menuFor(AppRole.teacher), [
      Destination.today,
      Destination.timetable,
      Destination.settings,
    ]);
    expect(Destination.students.allowedFor(AppRole.teacher), isFalse);
    expect(Destination.debtors.allowedFor(AppRole.teacher), isFalse);
  });

  test('Qarzdorlar is reachable but not in the menu', () {
    expect(menuFor(AppRole.owner), isNot(contains(Destination.debtors)));
    expect(reachableFor(AppRole.owner), contains(Destination.debtors));
    expect(reachableFor(AppRole.admin), contains(Destination.debtors));
  });

  test(
    'the phone bar: owner Moliya, admin Qabul, teacher no payment button',
    () {
      final owner = phoneBarFor(AppRole.owner);
      expect(labels(owner.left), ['Bugun', 'O\'quvchilar']);
      expect(labels(owner.right), ['Jadval', 'Moliya']);
      expect(owner.showPaymentButton, isTrue);
      expect(owner.left[1].shortLabel(s), 'O\'quvchi');

      final admin = phoneBarFor(AppRole.admin);
      expect(labels(admin.right), ['Jadval', 'Moliya']);
      expect(admin.showPaymentButton, isTrue);

      final teacher = phoneBarFor(AppRole.teacher);
      expect(teacher.showPaymentButton, isFalse);
      expect(teacher.all, [Destination.today, Destination.timetable]);
    },
  );

  test('every phone bar destination is one the role may open', () {
    for (final role in AppRole.values) {
      for (final d in phoneBarFor(role).all) {
        expect(d.allowedFor(role), isTrue, reason: '$role -> $d');
      }
    }
  });

  test('role parsing and labels', () {
    expect(AppRole.parse('owner'), AppRole.owner);
    expect(AppRole.parse('admin'), AppRole.admin);
    expect(AppRole.parse('teacher'), AppRole.teacher);
    // Unknown means least privilege among the signed-in roles that exist.
    expect(AppRole.parse('something'), AppRole.admin);
    expect(AppRole.parse(null), AppRole.admin);
    expect(AppRole.owner.label(s), 'Egasi');
    expect(AppRole.admin.label(s), 'Ma\'mur');
  });

  test('screens without a phone layout say so rather than render broken', () {
    // The screens built only for the wide layout so far.
    for (final d in [
      Destination.admissions,
      Destination.timetable,
      Destination.finance,
      Destination.teachers,
      Destination.debtors,
    ]) {
      expect(d.phoneReady, isFalse, reason: '$d');
    }
    for (final d in [
      Destination.today,
      Destination.students,
      Destination.settings,
    ]) {
      expect(d.phoneReady, isTrue, reason: '$d');
    }
  });
}
