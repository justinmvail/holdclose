import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The 10 brand color tokens from BUILD_SPEC.md §3.1.
///
/// Source of truth for every color used in screen build methods. Read
/// these via `Theme.of(context).colorScheme.X` or `holdcloseColors.X`
/// — never as raw hex.
@immutable
class HoldcloseColors extends ThemeExtension<HoldcloseColors> {
  const HoldcloseColors({
    required this.primary,
    required this.primarySoft,
    required this.text,
    required this.cta,
    required this.ctaFilled,
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

  /// The salmon brand accent. Use for DECORATIVE, non-text-bearing marks
  /// (icons, chip tints, borders, focus rings). At 3.43:1 white text on
  /// this fails WCAG-AA, so it is NOT a filled-button background — use
  /// [ctaFilled] for anything that carries white/on-secondary label text.
  final Color cta;

  /// Accessible filled-CTA background. Darker than [cta] so white
  /// (`onSecondary`) text on it clears WCAG-AA (4.72:1 in light mode).
  /// Every filled primary button (ElevatedButton / FilledButton / FAB)
  /// reads its background from here and its foreground from
  /// `colorScheme.onSecondary`, so dark mode pairs correctly.
  final Color ctaFilled;

  final Color accentDeep;
  final Color surfaceWarm;
  final Color background;
  final Color link;
  final Color error;
  final Color success;

  @override
  HoldcloseColors copyWith({
    Color? primary,
    Color? primarySoft,
    Color? text,
    Color? cta,
    Color? ctaFilled,
    Color? accentDeep,
    Color? surfaceWarm,
    Color? background,
    Color? link,
    Color? error,
    Color? success,
  }) {
    return HoldcloseColors(
      primary: primary ?? this.primary,
      primarySoft: primarySoft ?? this.primarySoft,
      text: text ?? this.text,
      cta: cta ?? this.cta,
      ctaFilled: ctaFilled ?? this.ctaFilled,
      accentDeep: accentDeep ?? this.accentDeep,
      surfaceWarm: surfaceWarm ?? this.surfaceWarm,
      background: background ?? this.background,
      link: link ?? this.link,
      error: error ?? this.error,
      success: success ?? this.success,
    );
  }

  @override
  HoldcloseColors lerp(
    covariant ThemeExtension<HoldcloseColors>? other,
    double t,
  ) {
    if (other is! HoldcloseColors) return this;
    return HoldcloseColors(
      primary: Color.lerp(primary, other.primary, t)!,
      primarySoft: Color.lerp(primarySoft, other.primarySoft, t)!,
      text: Color.lerp(text, other.text, t)!,
      cta: Color.lerp(cta, other.cta, t)!,
      ctaFilled: Color.lerp(ctaFilled, other.ctaFilled, t)!,
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
const HoldcloseColors holdcloseColors = HoldcloseColors(
  primary: Color(0xFF1F2A44),
  primarySoft: Color(0xFF2A3B61),
  text: Color(0xFF33373D),
  cta: Color(0xFFC97458),
  // Filled-button background: white text on this measures 4.72:1 (WCAG-AA
  // pass), vs. 3.43:1 on the lighter decorative [cta].
  ctaFilled: Color(0xFFB05C40),
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

/// Dark brand palette. Same token slots as [holdcloseColors] but tuned
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
const HoldcloseColors holdcloseColorsDark = HoldcloseColors(
  primary: Color(0xFFB7C4E0),
  primarySoft: Color(0xFF8C9BBF),
  text: _darkText,
  cta: Color(0xFFE08A6B),
  // Filled-button background on dark: pairs with the dark-navy
  // `onSecondary`, so the bright orange carries dark text at high contrast.
  ctaFilled: Color(0xFFE08A6B),
  accentDeep: Color(0xFFC97458),
  surfaceWarm: _darkSurfaceVariant,
  background: _darkSurface,
  link: Color(0xFF8FA2E8),
  error: Color(0xFFF06A6A),
  success: Color(0xFF5FBF8C),
);

/// Reads the active [HoldcloseColors] theme extension off [context],
/// falling back to the light const if no ancestor theme registered one
/// (keeps tests + stray contexts safe — never crashes, never returns
/// null).
extension HoldcloseColorsContext on BuildContext {
  HoldcloseColors get hc =>
      Theme.of(this).extension<HoldcloseColors>() ?? holdcloseColors;
}

TextTheme _holdcloseTextTheme({
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
    // `secondary` is the FILLED-CTA background (the accessible #B05C40, not
    // the lighter decorative salmon), so `onSecondary` white text on a
    // filled button clears WCAG-AA. Decorative salmon stays on `cb.cta`.
    secondary: Color(0xFFB05C40),
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
    scaffoldBackgroundColor: holdcloseColors.background,
    extensions: const <ThemeExtension<dynamic>>[holdcloseColors],
    textTheme: _holdcloseTextTheme(
      bodyColor: holdcloseColors.text,
      headingColor: holdcloseColors.primary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: holdcloseColors.background,
      foregroundColor: holdcloseColors.primary,
      elevation: 0,
      titleTextStyle: GoogleFonts.montserrat(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: holdcloseColors.primary,
      ),
    ),
  );
}

ThemeData _buildDarkTheme() {
  final ColorScheme scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: holdcloseColorsDark.primary,
    onPrimary: _darkSurface,
    secondary: holdcloseColorsDark.cta,
    onSecondary: _darkSurface,
    tertiary: holdcloseColorsDark.accentDeep,
    onTertiary: _darkSurface,
    error: holdcloseColorsDark.error,
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
    extensions: const <ThemeExtension<dynamic>>[holdcloseColorsDark],
    textTheme: _holdcloseTextTheme(
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

final ThemeData holdcloseLightTheme = _buildLightTheme();
final ThemeData holdcloseDarkTheme = _buildDarkTheme();
