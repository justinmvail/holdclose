import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The 10 brand color tokens from BUILD_SPEC.md §3.1.
///
/// Source of truth for every color used in screen build methods. Read
/// these via `Theme.of(context).colorScheme.X` or `careblazersColors.X`
/// — never as raw hex.
@immutable
class CareblazersColors extends ThemeExtension<CareblazersColors> {
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

  @override
  CareblazersColors copyWith({
    Color? primary,
    Color? primarySoft,
    Color? text,
    Color? cta,
    Color? accentDeep,
    Color? surfaceWarm,
    Color? background,
    Color? link,
    Color? error,
    Color? success,
  }) {
    return CareblazersColors(
      primary: primary ?? this.primary,
      primarySoft: primarySoft ?? this.primarySoft,
      text: text ?? this.text,
      cta: cta ?? this.cta,
      accentDeep: accentDeep ?? this.accentDeep,
      surfaceWarm: surfaceWarm ?? this.surfaceWarm,
      background: background ?? this.background,
      link: link ?? this.link,
      error: error ?? this.error,
      success: success ?? this.success,
    );
  }

  @override
  CareblazersColors lerp(
    covariant ThemeExtension<CareblazersColors>? other,
    double t,
  ) {
    if (other is! CareblazersColors) return this;
    return CareblazersColors(
      primary: Color.lerp(primary, other.primary, t)!,
      primarySoft: Color.lerp(primarySoft, other.primarySoft, t)!,
      text: Color.lerp(text, other.text, t)!,
      cta: Color.lerp(cta, other.cta, t)!,
      accentDeep: Color.lerp(accentDeep, other.accentDeep, t)!,
      surfaceWarm: Color.lerp(surfaceWarm, other.surfaceWarm, t)!,
      background: Color.lerp(background, other.background, t)!,
      link: Color.lerp(link, other.link, t)!,
      error: Color.lerp(error, other.error, t)!,
      success: Color.lerp(success, other.success, t)!,
    );
  }
}

/// Light brand palette (BUILD_SPEC.md §3.1). Source of truth for light
/// mode and the safe const fallback for any context that can't reach a
/// [BuildContext] (theme construction, top-level functions, static data).
const CareblazersColors careblazersColors = CareblazersColors(
  primary: Color(0xFF1F2A44),
  primarySoft: Color(0xFF2A3B61),
  text: Color(0xFF33373D),
  cta: Color(0xFFC97458),
  accentDeep: Color(0xFFB05C40),
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

/// Dark brand palette. Same token slots as [careblazersColors] but tuned
/// for a dark navy/charcoal canvas:
/// - `background`/`surfaceWarm` become dark navy + a slightly lifted
///   variant so cards separate from the scaffold.
/// - `text` is the warm off-white `_darkText` (≈13.5:1 on `_darkSurface`,
///   well past WCAG-AA for body text).
/// - `primary`/`primarySoft` (used for headings, icons, chips) are
///   lightened to a pale slate-blue so navy-on-navy stays legible.
/// - `cta`/`accentDeep` (the brand orange) are nudged brighter so the CTA
///   keeps AA contrast on the dark canvas while staying on-brand.
/// - `link`/`error`/`success` are lightened for contrast on dark.
const CareblazersColors careblazersColorsDark = CareblazersColors(
  primary: Color(0xFFB7C4E0),
  primarySoft: Color(0xFF8C9BBF),
  text: _darkText,
  cta: Color(0xFFE08A6B),
  accentDeep: Color(0xFFC97458),
  surfaceWarm: _darkSurfaceVariant,
  background: _darkSurface,
  link: Color(0xFF8FA2E8),
  error: Color(0xFFF06A6A),
  success: Color(0xFF5FBF8C),
);

/// Reads the active [CareblazersColors] theme extension off [context],
/// falling back to the light const if no ancestor theme registered one
/// (keeps tests + stray contexts safe — never crashes, never returns
/// null).
extension CareblazersColorsContext on BuildContext {
  CareblazersColors get cb =>
      Theme.of(this).extension<CareblazersColors>() ?? careblazersColors;
}

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
    secondary: Color(0xFFC97458),
    onSecondary: Color(0xFFFFFFFF),
    tertiary: Color(0xFFB05C40),
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
    extensions: const <ThemeExtension<dynamic>>[careblazersColors],
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
  final ColorScheme scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: careblazersColorsDark.primary,
    onPrimary: _darkSurface,
    secondary: careblazersColorsDark.cta,
    onSecondary: _darkSurface,
    tertiary: careblazersColorsDark.accentDeep,
    onTertiary: _darkSurface,
    error: careblazersColorsDark.error,
    onError: _darkSurface,
    surface: _darkSurface,
    onSurface: _darkText,
    surfaceContainerHighest: _darkSurfaceVariant,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: _darkSurface,
    extensions: const <ThemeExtension<dynamic>>[careblazersColorsDark],
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
