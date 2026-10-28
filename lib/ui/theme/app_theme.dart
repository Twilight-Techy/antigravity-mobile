import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Dark palette modelled on the Antigravity editor chrome.
class AppColors {
  static const background = Color(0xFF0D0E11);
  static const surface = Color(0xFF15171C);
  static const surfaceHigh = Color(0xFF1C1F26);
  static const surfaceHighest = Color(0xFF242832);
  static const border = Color(0xFF2A2F3A);
  static const text = Color(0xFFE7E9EE);
  static const textMuted = Color(0xFF9AA1AE);
  static const textFaint = Color(0xFF6B7280);
  static const accent = Color(0xFF5B8CFF);
  static const accentAlt = Color(0xFFA06BFF);
  static const success = Color(0xFF3FB97A);
  static const warning = Color(0xFFE5A93B);
  static const danger = Color(0xFFF0605D);
  static const codeBackground = Color(0xFF111318);

  static const accentGradient = LinearGradient(
    colors: [accent, accentAlt],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

const monoFamily = 'monospace';
const monoFallback = ['Menlo', 'Consolas', 'RobotoMono', 'Courier New', 'monospace'];

TextStyle monoStyle({double size = 13, Color? color, FontWeight? weight}) => TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      height: 1.4,
      color: color ?? AppColors.text,
      fontWeight: weight,
    );

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    secondary: AppColors.accentAlt,
    surface: AppColors.surface,
    surfaceContainerLowest: AppColors.background,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surfaceHigh,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHighest,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.textMuted,
    outline: AppColors.border,
    outlineVariant: AppColors.border,
    error: AppColors.danger,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    dividerColor: AppColors.border,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.text,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
      labelStyle: const TextStyle(color: AppColors.textMuted),
      hintStyle: const TextStyle(color: AppColors.textFaint),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.accent.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? AppColors.text : AppColors.textMuted,
          )),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surfaceHigh,
      side: const BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: const TextStyle(fontSize: 12.5, color: AppColors.text),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHighest,
      contentTextStyle: TextStyle(color: AppColors.text),
    ),
    listTileTheme: const ListTileThemeData(iconColor: AppColors.textMuted),
  );
}

const terminalTheme = TerminalTheme(
  cursor: Color(0xFFE7E9EE),
  selection: Color(0x665B8CFF),
  foreground: Color(0xFFE7E9EE),
  background: AppColors.background,
  black: Color(0xFF1C1F26),
  red: Color(0xFFF0605D),
  green: Color(0xFF3FB97A),
  yellow: Color(0xFFE5A93B),
  blue: Color(0xFF5B8CFF),
  magenta: Color(0xFFA06BFF),
  cyan: Color(0xFF3CC4D9),
  white: Color(0xFFD5D9E0),
  brightBlack: Color(0xFF6B7280),
  brightRed: Color(0xFFFF7B78),
  brightGreen: Color(0xFF5FD69A),
  brightYellow: Color(0xFFFFC75A),
  brightBlue: Color(0xFF82A8FF),
  brightMagenta: Color(0xFFBF94FF),
  brightCyan: Color(0xFF6FDCEB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFE5A93B),
  searchHitBackgroundCurrent: Color(0xFF3FB97A),
  searchHitForeground: Color(0xFF0D0E11),
);
