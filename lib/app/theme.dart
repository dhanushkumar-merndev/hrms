import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Design tokens from design.md §2 (approximations of the references with
/// accessible contrast). Light theme only for now; dark mode is deferred.
class AppColors {
  const AppColors._();

  static const background = Color(0xFFF6F7F9);
  static const surface = Color(0xFFFFFFFF);
  static const text = Color(0xFF263342);
  static const textSecondary = Color(0xFF596678);
  static const primary = Color(0xFF4B59C7);
  static const border = Color(0xFFE3E7ED);

  static const attendanceCard = Color(0xFFDFE3FF);
  static const attendanceAction = Color(0xFF4B59C7);
  static const leaveCard = Color(0xFFE3F9FB);
  static const leaveAction = Color(0xFF007C89);
  static const salaryCard = Color(0xFFFFF0DD);
  static const salaryAction = Color(0xFFA94B00);
  static const peopleCard = Color(0xFFFFE5EF);
  static const peopleAction = Color(0xFFAE275B);
  static const approvalsCard = Color(0xFFD8F6F0);
  static const approvalsAction = Color(0xFF007768);
  static const documentsCard = Color(0xFFE8F4FB);
  static const documentsAction = Color(0xFF1D5F8A);
  static const workspaceCard = Color(0xFFEDE7F6);
  static const workspaceAction = Color(0xFF5B3E9E);

  static const error = Color(0xFFB42318);
  static const errorSoft = Color(0xFFFDECEA);
  static const warning = Color(0xFF8A5700);
  static const warningSoft = Color(0xFFFFF4D6);
  static const success = Color(0xFF287A35);
  static const successSoft = Color(0xFFE6F4E8);
  static const exceptionStrip = Color(0xFFFDEDEE);
  static const shiftBadge = Color(0xFFFFE0B8);
  static const holidayCard = Color(0xFFF7EDFA);
  static const holidayText = Color(0xFF7B2C8F);
}

class AppSpacing {
  const AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const page = 16.0;
  static const cardPadding = 20.0;
  static const cardRadius = 20.0;
  static const rowRadius = 16.0;
  static const iconTile = 52.0;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primary,
    surface: AppColors.surface,
    error: AppColors.error,
    brightness: Brightness.light,
  );
  const text = TextTheme(
    headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w500, color: AppColors.text, height: 1.2),
    headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, color: AppColors.text),
    titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: AppColors.text),
    titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.text),
    titleSmall: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.text),
    bodyLarge: TextStyle(fontSize: 16, color: AppColors.text, height: 1.4),
    bodyMedium: TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4),
    bodySmall: TextStyle(fontSize: 13, color: AppColors.textSecondary),
    labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    textTheme: text,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: AppColors.text),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(48, 48))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.attendanceCard,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 13,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
            // Inactive labels keep >= 4.5:1 contrast (the reference was too faint).
            color: states.contains(WidgetState.selected) ? AppColors.primary : AppColors.textSecondary,
          )),
    ),
    chipTheme: const ChipThemeData(side: BorderSide(color: AppColors.border)),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
