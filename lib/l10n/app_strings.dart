/// Every user-facing string of the V2 shell and the screens built on it, in
/// one place: plain Uzbek (Latin), no locale switching. Older screens still
/// carry their own literals and move here as each phase rebuilds them --
/// new screens must take their text from this file.
class AppStrings {
  const AppStrings();

  static const current = AppStrings();

  // --- App -----------------------------------------------------------
  String get appName => 'Expert Edu Center';
  String get brandName => 'Expert';
  String get brandSubtitle => 'Learning Center';

  // --- Auth ----------------------------------------------------------
  String get phone => 'Telefon';
  String get password => 'Parol';
  String get login => 'Kirish';
  String get logout => 'Chiqish';
  String get requiredField => 'Bu maydon majburiy';

  // --- Updates -------------------------------------------------------
  String get updateAvailable => 'Yangilanish mavjud';
  String get downloadingUpdate => 'Yuklab olinmoqda';
  String get update => 'Yangilash';

  // --- Navigation ----------------------------------------------------
  String get navSectionWork => 'Ish stoli';
  String get navSectionManage => 'Boshqaruv';
  String get navToday => 'Bugun';
  String get navAdmissions => 'Qabul';
  String get navStudents => 'O\'quvchilar';
  String get navStudentShort => 'O\'quvchi';
  String get navTimetable => 'Jadval';
  String get navGroups => 'Guruhlar';
  String get navTeachers => 'O\'qituvchilar';
  String get navFinance => 'Moliya';
  String get navReports => 'Hisobotlar';
  String get navSettings => 'Sozlamalar';
  String get navDebtors => 'Qarzdorlar';
  String get navMainMenu => 'Asosiy menyu';
  String get navMore => 'Boshqa bo\'limlar';

  // --- Roles ---------------------------------------------------------
  String get roleOwner => 'Egasi';
  String get roleAdmin => 'Ma\'mur';
  String get roleTeacher => 'O\'qituvchi';

  // --- Top bar and command bar ---------------------------------------
  String get commandBarHint => 'Qidirish yoki buyruq yozish';
  String get commandBarShortcut => 'Ctrl K';
  String get commandBarShortcutMac => '⌘ K';
  String get commandBarTitle => 'Buyruqlar paneli';
  String get commandSectionActions => 'Amallar';
  String get commandSectionGoTo => 'Bo\'limlar';
  String get commandSectionStudents => 'O\'quvchilar';
  String get commandNothingFound => 'Hech narsa topilmadi';
  String get commandSearching => 'Qidirilmoqda...';
  String get commandOpenHint => 'Ochish';
  String get newItem => 'Yangi';

  // --- Quick actions -------------------------------------------------
  String get newLead => 'Yangi so\'rov';
  String get newStudent => 'Yangi o\'quvchi';
  String get paymentRecorded => 'To\'lov qabul qilindi';
  String get pickStudent => 'O\'quvchini tanlang';
  String get searchStudentHint => 'Ism yoki telefon bo\'yicha qidiring';
  String get studentHasNoGroup => 'Bu o\'quvchi hali guruhga yozilmagan';
  String get pickGroup => 'Guruhni tanlang';
  String get owes => 'Qarz';

  // --- Common --------------------------------------------------------
  String get refresh => 'Yangilash';
  String get close => 'Yopish';
  String get cancel => 'Bekor qilish';
  String get retry => 'Qayta urinish';
  String get comingSoon => 'Tez orada';
  String get phoneNotReadyTitle => 'Bu bo\'lim telefon uchun hali tayyor emas';
  String get phoneNotReadyBody =>
      'Uni kompyuterda oching. Telefon uchun qulay ko\'rinish keyingi yangilanishlarda qo\'shiladi.';
}
