import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';

extension BuildContextX on BuildContext {
  AppStrings get strings => AppStrings.current;

  ColorScheme get colors => Theme.of(this).colorScheme;

  TextTheme get textTheme => Theme.of(this).textTheme;
}
