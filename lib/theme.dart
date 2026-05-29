import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The 10 brand color tokens from BUILD_SPEC.md §3.1.
///
/// Source of truth for every color used in screen build methods. Read
/// these via `Theme.of(context).colorScheme.X` or `careblazersColors.X`
/// — never as raw hex.
@immutable
class CareblazersColors {
  const CareblazersColors({
    required this.primary,
    required this.primarySoft,
    required this.text,
    required this.cta,
    required this.accentDeep,
    required this.surfaceWarm,
    required this.background,
    required this.link,
    required this.error,
    required this.success,
  });

  final Color primary;
  final Color primarySoft;
  final Color text;
  final Color cta;
  final Color accentDeep;
  final Color surfaceWarm;
  final Color background;
  final Color link;
  final Color error;
  final Color success;
}

const CareblazersColors careblazersColors = CareblazersColors(
  primary: Color(0xFF1F2A44),
  primarySoft: Color(0xFF2A3B61),
  text: Color(0xFF33373D),
  cta: Color(0xFFFF6900),
  accentDeep: Color(0xFFCC3366),
  surfaceWarm: Color(0xFFF8F6F3),
  background: Color(0xFFFFFFFF),
  link: Color(0xFF4054B2),
  error: Color(0xFFCF2E2E),
  success: Color(0xFF2A7C4F),
);

// Dark palette derived per BUILD_SPEC.md §3.1: navy surface, warm-white
// text, orange CTA unchanged.
const Color _darkSurface = Color(0xFF0F1422);
const Color _darkSurfaceVariant = Color(0xFF1A2236);
const Color _darkText = Color(0xFFE8E6E2);

TextTheme _careblazersTextTheme({
  required Color bodyColor,
  required Color headingColor,
}) {
  return TextTheme(
    displayLarge: GoogleFonts.montserrat(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      color: headingColor,
    ),
    headlineLarge: GoogleFonts.montserrat(
      fontSize: 26,
      fontWeight: FontWeight.w700,
      color: headingColor,
    ),
    headlineMedium: GoogleFonts.montserrat(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      color: headingColor,
    ),
    titleLarge: GoogleFonts.montserrat(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      color: headingColor,
    ),
    bodyLarge: GoogleFonts.lato(
      fontSize: 20,
      fontWeight: FontWeight.w400,
      color: bodyColor,
    ),
    bodyMedium: GoogleFonts.lato(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      color: bodyColor,
    ),
    labelLarge: GoogleFonts.lato(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      color: bodyColor,
    ),
  );
}

ThemeData _buildLightTheme() {
  const ColorScheme scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF1F2A44),
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFFFF6900),
    onSecondary: Color(0xFFFFFFFF),
    tertiary: Color(0xFFCC3366),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFCF2E2E),
    onError: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF33373D),
    surfaceContainerHighest: Color(0xFFF8F6F3),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: careblazersColors.background,
    textTheme: _careblazersTextTheme(
      bodyColor: careblazersColors.text,
      headingColor: careblazersColors.primary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: careblazersColors.background,
      foregroundColor: careblazersColors.primary,
      elevation: 0,
      titleTextStyle: GoogleFonts.montserrat(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: careblazersColors.primary,
      ),
    ),
  );
}

ThemeData _buildDarkTheme() {
  const ColorScheme scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF1F2A44),
    onPrimary: _darkText,
    secondary: Color(0xFFFF6900),
    onSecondary: Color(0xFFFFFFFF),
    tertiary: Color(0xFFCC3366),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFCF2E2E),
    onError: Color(0xFFFFFFFF),
    surface: _darkSurface,
    onSurface: _darkText,
    surfaceContainerHighest: _darkSurfaceVariant,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: _darkSurface,
    textTheme: _careblazersTextTheme(
      bodyColor: _darkText,
      headingColor: _darkText,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: _darkSurface,
      foregroundColor: _darkText,
      elevation: 0,
      titleTextStyle: GoogleFonts.montserrat(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: _darkText,
      ),
    ),
  );
}

final ThemeData careblazersLightTheme = _buildLightTheme();
final ThemeData careblazersDarkTheme = _buildDarkTheme();
