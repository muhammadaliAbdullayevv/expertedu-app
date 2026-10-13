/// Plain, hardcoded-Uzbek strings -- no locale switching, matching the
/// shop app's own AppStrings. Grows as new screens are built; keep
/// alphabetically loose, grouped by feature, not strictly sorted.
class AppStrings {
  const AppStrings();

  static const current = AppStrings();

  String get appName => 'Expert Edu Center';

  String get phone => 'Telefon';

  String get password => 'Parol';

  String get login => 'Kirish';

  String get requiredField => 'Bu maydon majburiy';

  String get logout => 'Chiqish';

  String get updateAvailable => 'Yangilanish mavjud';

  String get downloadingUpdate => 'Yuklab olinmoqda';

  String get update => 'Yangilash';
}
