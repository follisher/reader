import 'package:flutter/material.dart';

/// Shared warm-paper design tokens used by the shelf and both reader modes.
/// Keep this palette independent from fonts so hosts can provide their own type.
class ReaderPalette {
  ReaderPalette._();

  static const Color background = Color(0xFFF2E9DC);
  static const Color card = Color(0xFFFBF5EC);
  static const Color sheet = Color(0xFFF6EFE3);
  static const Color accent = Color(0xFFB3572F);
  static const Color accentDark = Color(0xFF944522);
  static const Color ink = Color(0xFF3A322B);
  static const Color inkSecondary = Color(0xFF786C5E);
  static const Color muted = Color(0xFFA2957F);
  static const Color mutedSecondary = Color(0xFF9C8F7D);
  static const Color heading = Color(0xFF8B5E3C);
  static const Color subheading = Color(0xFF5F5A50);
  static const Color track = Color(0xFFECE0CF);
  static const Color hairline = Color(0x0F3A322B);
  static const Color error = Color(0xFFD9534F);

  static const Color nightBackground = Color(0xFF191712);
  static const Color nightSheet = Color(0xFF221F19);
  static const Color nightInk = Color(0xFFB5AB9C);
  static const Color nightHeading = Color(0xFFD6B58A);
  static const Color nightSubheading = Color(0xFFC9C4B3);

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
      primary: accent,
      onPrimary: Colors.white,
      secondary: accentDark,
      onSecondary: Colors.white,
      surface: nightSheet,
      onSurface: nightInk,
      error: error,
      onError: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: nightSheet,
      foregroundColor: nightInk,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
