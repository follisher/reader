import 'package:flutter/material.dart';

/// Shared monochrome design tokens used by the shelf and both reader modes.
/// Keep this palette independent from fonts so hosts can provide their own type.
class ReaderPalette {
  ReaderPalette._();

  static const Color background = Color(0xFFFFFFFF);
  static const Color card = Color(0xFFF7F7F7);
  static const Color sheet = Color(0xFFF0F0F0);
  static const Color accent = Color(0xFF000000);
  static const Color accentDark = Color(0xFF424242);
  static const Color ink = Color(0xFF111111);
  static const Color inkSecondary = Color(0xFF616161);
  static const Color muted = Color(0xFF9E9E9E);
  static const Color mutedSecondary = Color(0xFF757575);
  static const Color heading = Color(0xFF212121);
  static const Color subheading = Color(0xFF424242);
  static const Color track = Color(0xFFE0E0E0);
  static const Color coverPlaceholder = Color(0xFFEAEAEA);
  static const Color removeBackground = Color(0xFFE3E3E3);
  static const Color removeForeground = Color(0xFF757575);
  static const Color hairline = Color(0x14000000);
  static const Color error = Color(0xFF424242);

  static const Color nightBackground = Color(0xFF121212);
  static const Color nightSheet = Color(0xFF1F1F1F);
  static const Color nightInk = Color(0xFFE0E0E0);
  static const Color nightHeading = Color(0xFFF5F5F5);
  static const Color nightSubheading = Color(0xFFBDBDBD);

  static ThemeData lightTheme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.light(
      primary: accent,
      onPrimary: Colors.white,
      secondary: accentDark,
      onSecondary: Colors.white,
      surface: card,
      onSurface: ink,
      error: error,
      onError: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: sheet,
      foregroundColor: ink,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(color: hairline),
    cardTheme: const CardThemeData(
      color: card,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: card,
      prefixIconColor: mutedSecondary,
      hintStyle: const TextStyle(color: muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: hairline),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: track,
    ),
  );

  static ThemeData darkTheme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: nightBackground,
    colorScheme: const ColorScheme.dark(
      primary: nightInk,
      onPrimary: Colors.black,
      secondary: nightSubheading,
      onSecondary: Colors.black,
      surface: nightSheet,
      onSurface: nightInk,
      error: nightSubheading,
      onError: Colors.black,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: nightSheet,
      foregroundColor: nightInk,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(color: Color(0x24FFFFFF)),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: nightInk,
      linearTrackColor: Color(0x3DFFFFFF),
    ),
  );
}
