import 'package:flutter/material.dart';

/// Shared corner-radius tokens so every card/button/field/sheet in the app
/// rounds the same amount instead of each screen picking its own number.
class AppRadius {
  AppRadius._();

  static const double card = 16;
  static const double button = 12;
  static const double field = 12;
  static const double sheet = 24;
}

/// The brand palette, taken from the logo: a yellow X on black. Neutrals are
/// plain zinc greys -- no tint -- so the yellow is the only colour that
/// draws the eye. Everything colour-related in the app comes from here or
/// from the ColorScheme built on it below; swapping to a dark look later
/// means changing this one file.
class AppColors {
  AppColors._();

  static const Color brandYellow = Color(0xFFFECA26);
  static const Color yellowSoft = Color(0xFFFEF3C7);

  /// Primary text, and the fill of ordinary (non-brand) filled buttons.
  static const Color ink = Color(0xFF18181B);
  static const Color inkSecondary = Color(0xFF52525B);
  static const Color inkMuted = Color(0xFF71717A);

  static const Color canvas = Color(0xFFF4F4F5);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE4E4E7);

  static const Color sidebar = Color(0xFF111113);
  static const Color sidebarHover = Color(0xFF232327);
  static const Color sidebarText = Color(0xFFA1A1AA);

  static const Color danger = Color(0xFFDC2626);
  static const Color success = Color(0xFF16A34A);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.ink,
      onPrimary: Colors.white,
      primaryContainer: AppColors.yellowSoft,
      onPrimaryContainer: AppColors.ink,
      secondary: AppColors.brandYellow,
      onSecondary: AppColors.ink,
      secondaryContainer: AppColors.yellowSoft,
      onSecondaryContainer: AppColors.ink,
      tertiary: AppColors.inkSecondary,
      onTertiary: Colors.white,
      error: AppColors.danger,
      onError: Colors.white,
      errorContainer: Color(0xFFFEE2E2),
      onErrorContainer: Color(0xFF7F1D1D),
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      onSurfaceVariant: AppColors.inkSecondary,
      surfaceDim: Color(0xFFE4E4E7),
      surfaceBright: AppColors.surface,
      surfaceContainerLowest: AppColors.surface,
      surfaceContainerLow: Color(0xFFFAFAFA),
      surfaceContainer: AppColors.canvas,
      surfaceContainerHigh: Color(0xFFEDEDEF),
      surfaceContainerHighest: AppColors.border,
      outline: Color(0xFFA1A1AA),
      outlineVariant: AppColors.border,
      inverseSurface: AppColors.ink,
      onInverseSurface: Colors.white,
      inversePrimary: AppColors.brandYellow,
      shadow: Colors.black,
      scrim: Colors.black,
      surfaceTint: Colors.transparent,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: colorScheme);
    final text = base.textTheme;
    final textTheme = text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.button),
    );
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.field),
      borderSide: const BorderSide(color: AppColors.border),
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.canvas,
      textTheme: textTheme,
      dividerTheme: const DividerThemeData(color: AppColors.border),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // AppBar uses this style as-is, and the theme's own text styles
        // only get their sizes once the theme is resolved -- so the size is
        // set here, on top of the base style that carries the app's font.
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: AppColors.ink,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: buttonShape,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: buttonShape,
          foregroundColor: AppColors.ink,
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: buttonShape,
          foregroundColor: AppColors.ink,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(
          borderSide: const BorderSide(color: AppColors.ink, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.brandYellow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: const WidgetStatePropertyAll(
          IconThemeData(color: AppColors.ink),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
      // The brand yellow is reserved for the one main action on a screen
      // (and the selected navigation item) -- not every filled button.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.brandYellow,
        foregroundColor: AppColors.ink,
        elevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
      chipTheme: ChipThemeData(
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.ink,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.ink,
      ),
    );
  }
}
