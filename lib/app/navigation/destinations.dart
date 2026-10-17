import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';

/// Who is signed in, as far as the menu is concerned. The server knows
/// 'owner' and 'admin' today; 'teacher' arrives with the teacher login
/// (Phase 8) and already has its menu here.
enum AppRole {
  owner,
  admin,
  teacher;

  static AppRole parse(String? role) => switch (role) {
    'owner' => AppRole.owner,
    'teacher' => AppRole.teacher,
    _ => AppRole.admin,
  };

  String label(AppStrings s) => switch (this) {
    AppRole.owner => s.roleOwner,
    AppRole.admin => s.roleAdmin,
    AppRole.teacher => s.roleTeacher,
  };
}

enum NavSection { work, manage }

/// Every place the main navigation can go. The menu order, the section a
/// destination sits in, and who may see it all live in this one file, so
/// the sidebar, the phone bar, the command bar and the page guard can't
/// disagree.
enum Destination {
  today(
    Icons.home_outlined,
    NavSection.work,
    phoneReady: true,
    roles: {AppRole.owner, AppRole.admin, AppRole.teacher},
  ),
  admissions(
    Icons.filter_alt_outlined,
    NavSection.work,
    phoneReady: false,
    roles: {AppRole.owner, AppRole.admin},
  ),
  students(
    Icons.people_outline_rounded,
    NavSection.work,
    phoneReady: true,
    roles: {AppRole.owner, AppRole.admin},
  ),
  timetable(
    Icons.calendar_today_outlined,
    NavSection.work,
    phoneReady: false,
    roles: {AppRole.owner, AppRole.admin, AppRole.teacher},
  ),
  groups(
    Icons.layers_outlined,
    NavSection.manage,
    phoneReady: true,
    roles: {AppRole.owner, AppRole.admin},
  ),
  teachers(
    Icons.how_to_reg_outlined,
    NavSection.manage,
    phoneReady: false,
    roles: {AppRole.owner, AppRole.admin},
  ),
  finance(
    Icons.credit_card_outlined,
    NavSection.manage,
    phoneReady: false,
    roles: {AppRole.owner, AppRole.admin},
  ),
  reports(
    Icons.bar_chart_rounded,
    NavSection.manage,
    phoneReady: true,
    roles: {AppRole.owner, AppRole.admin},
  ),
  settings(
    Icons.tune_rounded,
    null,
    phoneReady: true,
    roles: {AppRole.owner, AppRole.admin, AppRole.teacher},
  ),

  /// Reachable from the command bar and the dashboard, not the menu.
  debtors(
    Icons.account_balance_wallet_outlined,
    null,
    phoneReady: false,
    roles: {AppRole.owner, AppRole.admin},
    inMenu: false,
  );

  const Destination(
    this.icon,
    this.section, {
    required this.roles,
    required this.phoneReady,
    this.inMenu = true,
  });

  /// Outline icon -- the design keeps it outline when selected too; the
  /// highlight carries the selection.
  final IconData icon;

  /// The sidebar group; null for the pinned bottom item (Sozlamalar) and
  /// for destinations that aren't in the menu.
  final NavSection? section;
  final Set<AppRole> roles;
  final bool inMenu;

  /// Whether the screen has a phone layout yet. Until it does, the phone
  /// shows a notice instead of a broken page (desktop is the main target;
  /// each phase that rebuilds a screen flips this to true).
  final bool phoneReady;

  String label(AppStrings s) => switch (this) {
    Destination.today => s.navToday,
    Destination.admissions => s.navAdmissions,
    Destination.students => s.navStudents,
    Destination.timetable => s.navTimetable,
    Destination.groups => s.navGroups,
    Destination.teachers => s.navTeachers,
    Destination.finance => s.navFinance,
    Destination.reports => s.navReports,
    Destination.settings => s.navSettings,
    Destination.debtors => s.navDebtors,
  };

  /// The short label under a phone-bar icon.
  String shortLabel(AppStrings s) =>
      this == Destination.students ? s.navStudentShort : label(s);

  bool allowedFor(AppRole role) => roles.contains(role);
}

/// The sidebar's destinations for [role], in menu order.
List<Destination> menuFor(AppRole role) => [
  for (final d in Destination.values)
    if (d.inMenu && d.allowedFor(role)) d,
];

/// The sidebar group's destinations for [role].
List<Destination> sectionFor(AppRole role, NavSection section) => [
  for (final d in menuFor(role))
    if (d.section == section) d,
];

/// Every destination [role] may open, menu or not -- what the command bar
/// can jump to and what the page guard allows.
List<Destination> reachableFor(AppRole role) => [
  for (final d in Destination.values)
    if (d.allowedFor(role)) d,
];

/// The phone's bottom bar: two destinations, the payment button in the
/// middle, two more. Owner and admin both get Moliya in the last slot.
/// Teachers have no payment button and no slots beyond these two.
class PhoneBarLayout {
  const PhoneBarLayout({
    required this.left,
    required this.right,
    required this.showPaymentButton,
  });

  final List<Destination> left;
  final List<Destination> right;
  final bool showPaymentButton;

  List<Destination> get all => [...left, ...right];
}

PhoneBarLayout phoneBarFor(AppRole role) => switch (role) {
  AppRole.owner => const PhoneBarLayout(
    left: [Destination.today, Destination.students],
    right: [Destination.timetable, Destination.finance],
    showPaymentButton: true,
  ),
  AppRole.admin => const PhoneBarLayout(
    left: [Destination.today, Destination.students],
    right: [Destination.timetable, Destination.finance],
    showPaymentButton: true,
  ),
  AppRole.teacher => const PhoneBarLayout(
    left: [Destination.today],
    right: [Destination.timetable],
    showPaymentButton: false,
  ),
};
