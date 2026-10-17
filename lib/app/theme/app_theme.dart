import 'package:flutter/material.dart';

/// Shared corner-radius tokens so every card/button/field/sheet in the app
/// rounds the same amount instead of each screen picking its own number.
/// (V2 design: cards 14, buttons and inputs 10, chips are pills.)
class AppRadius {
  AppRadius._();

  static const double card = 14;
  static const double button = 10;
  static const double field = 10;
  static const double sheet = 22;
  static const double chip = 12;
}

/// The palette (V2 design, docs/v2-design/README.md): warm neutrals on an
/// off-white page, with ONE accent for everything interactive -- the main
/// action, the selected item, focus. Change [accent] and [accentSoft] /
/// [accentText] to re-theme the whole app; nothing else hard-codes it.
/// Everything colour-related comes from here or from the ColorScheme built
/// on it below.
class AppColors {
  AppColors._();

  /// The logo's yellow -- the logo only.
  static const Color brandYellow = Color(0xFFF2B705);

  /// The one accent: main buttons, selection, focus, links.
  static const Color accent = Color(0xFF5B4DDB);
  static const Color accentHover = Color(0xFF4A3DC4);

  /// Tinted background for selected items and highlights, and the text
  /// colour that goes on it.
  static const Color accentSoft = Color(0xFFEFEDFD);
  static const Color accentText = Color(0xFF3B2FA8);

  /// Primary text.
  static const Color ink = Color(0xFF17171A);
  static const Color inkSecondary = Color(0xFF44444C);
  static const Color inkMuted = Color(0xFF62626B);

  static const Color canvas = Color(0xFFF7F7F5);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE8E8E4);
  static const Color borderStrong = Color(0xFFD9D9D4);
  static const Color divider = Color(0xFFEFEFEC);

  /// The desktop sidebar: white, like the cards, set off by a border.
  static const Color sidebar = surface;
  static const Color sidebarHover = divider;
  static const Color sidebarText = inkSecondary;

  static const Color danger = Color(0xFFD92D20);
  static const Color success = Color(0xFF16A34A);

  /// Status chip colours: background and text, always shown with a text
  /// label -- colour alone never carries the meaning.
  static const Color okBg = Color(0xFFE4F5EC);
  static const Color okText = Color(0xFF0B5C3B);
  static const Color warnBg = Color(0xFFFFF1D6);
  static const Color warnText = Color(0xFF7A4800);
  static const Color dangerBg = Color(0xFFFDECEA);
  static const Color dangerText = Color(0xFF8F1D16);
  static const Color neutralBg = Color(0xFFEFEFEC);
  static const Color neutralText = Color(0xFF44444C);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.accent,
      onPrimary: Colors.white,
      primaryContainer: AppColors.accentSoft,
      onPrimaryContainer: AppColors.accentHover,
      secondary: AppColors.accent,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.accentSoft,
      onSecondaryContainer: AppColors.accentHover,
      tertiary: AppColors.inkSecondary,
      onTertiary: Colors.white,
      error: AppColors.danger,
      onError: Colors.white,
      errorContainer: AppColors.dangerBg,
      onErrorContainer: AppColors.dangerText,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      onSurfaceVariant: AppColors.inkSecondary,
      surfaceDim: AppColors.border,
      surfaceBright: AppColors.surface,
      surfaceContainerLowest: AppColors.surface,
      surfaceContainerLow: Color(0xFFFAFAF8),
      surfaceContainer: AppColors.canvas,
      surfaceContainerHigh: AppColors.divider,
      surfaceContainerHighest: AppColors.border,
      outline: AppColors.borderStrong,
      outlineVariant: AppColors.border,
      inverseSurface: AppColors.ink,
      onInverseSurface: Colors.white,
      inversePrimary: Color(0xFFB8B0F5),
      shadow: Colors.black,
      scrim: Colors.black,
      surfaceTint: Colors.transparent,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'DM Sans',
    );
    final text = base.textTheme;
    final textTheme = text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
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
          letterSpacing: -0.4,
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
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.accentSoft,
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
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
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
        color: AppColors.accent,
      ),
    );
  }
}
