import 'dart:async';

import 'package:holdclose/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  // google_fonts touches the asset bundle / network on TextStyle
  // construction; the binding has to be live for those calls.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // The font files aren't bundled in test assets and tests must not
    // hit the network. google_fonts fires fire-and-forget Futures from
    // TextStyle construction; when those fail (no asset, no network),
    // the errors surface as uncaught zone errors and fail unrelated
    // tests. Pre-initialize both themes inside a guarded zone here so
    // every loading future is rooted in a zone that swallows its
    // errors. Subsequent tests read the cached themes — no new loads.
    GoogleFonts.config.allowRuntimeFetching = false;
    final Completer<void> initialized = Completer<void>();
    unawaited(runZonedGuarded(
      () async {
        // Force lazy init of both themes inside this zone.
        holdcloseLightTheme.toString();
        holdcloseDarkTheme.toString();
        try {
          await GoogleFonts.pendingFonts();
        } catch (_) {
          // expected — fonts aren't bundled in tests
        }
        if (!initialized.isCompleted) initialized.complete();
      },
      (Object error, StackTrace stack) {
        // Swallow font-load errors only. Anything else is a real bug.
        final String message = error.toString();
        if (message.contains('google_fonts') ||
            message.contains('GoogleFonts') ||
            message.contains('was not found in the application assets') ||
            message.contains('Failed to load font')) {
          return;
        }
        if (!initialized.isCompleted) {
          initialized.completeError(error, stack);
        }
      },
    ));
    await initialized.future;
  });

  group('HoldcloseColors', () {
    test('all 10 tokens match BUILD_SPEC.md §3.1 verbatim', () {
      expect(holdcloseColors.primary, const Color(0xFF1F2A44));
      expect(holdcloseColors.primarySoft, const Color(0xFF2A3B61));
      expect(holdcloseColors.text, const Color(0xFF33373D));
      expect(holdcloseColors.cta, const Color(0xFFC97458));
      expect(holdcloseColors.accentDeep, const Color(0xFFB05C40));
      expect(holdcloseColors.surfaceWarm, const Color(0xFFF8F6F3));
      expect(holdcloseColors.background, const Color(0xFFFFFFFF));
      expect(holdcloseColors.link, const Color(0xFF4054B2));
      expect(holdcloseColors.error, const Color(0xFFCF2E2E));
      expect(holdcloseColors.success, const Color(0xFF2A7C4F));
    });
  });

  group('holdcloseLightTheme', () {
    test('uses Material 3', () {
      expect(holdcloseLightTheme.useMaterial3, isTrue);
    });

    test('brightness is light', () {
      expect(holdcloseLightTheme.brightness, Brightness.light);
    });

    test('colorScheme.primary is the navy brand token (#1F2A44)', () {
      expect(holdcloseLightTheme.colorScheme.primary, const Color(0xFF1F2A44));
      expect(holdcloseLightTheme.colorScheme.primary, holdcloseColors.primary);
    });

    test('colorScheme.secondary is the CTA salmon (#C97458)', () {
      expect(holdcloseLightTheme.colorScheme.secondary, holdcloseColors.cta);
    });

    test('colorScheme.tertiary is accentDeep (#B05C40)', () {
      expect(holdcloseLightTheme.colorScheme.tertiary, holdcloseColors.accentDeep);
    });

    test('colorScheme.error is the brand error red', () {
      expect(holdcloseLightTheme.colorScheme.error, holdcloseColors.error);
    });

    test('surface is white and surfaceContainerHighest is surfaceWarm', () {
      expect(holdcloseLightTheme.colorScheme.surface, holdcloseColors.background);
      expect(
        holdcloseLightTheme.colorScheme.surfaceContainerHighest,
        holdcloseColors.surfaceWarm,
      );
    });

    test('onSurface is the warm body-text color (#33373D)', () {
      expect(holdcloseLightTheme.colorScheme.onSurface, holdcloseColors.text);
    });

    test('scaffoldBackgroundColor is the brand background', () {
      expect(
        holdcloseLightTheme.scaffoldBackgroundColor,
        holdcloseColors.background,
      );
    });

    group('textTheme maps to BUILD_SPEC.md §3.2 type ramp', () {
      test('displayLarge — Montserrat 700 / 32', () {
        final TextStyle style = holdcloseLightTheme.textTheme.displayLarge!;
        expect(style.fontSize, 32);
        expect(style.fontWeight, FontWeight.w700);
      });

      test('headlineLarge — Montserrat 700 / 26', () {
        final TextStyle style = holdcloseLightTheme.textTheme.headlineLarge!;
        expect(style.fontSize, 26);
        expect(style.fontWeight, FontWeight.w700);
      });

      test('headlineMedium — Montserrat 600 / 22', () {
        final TextStyle style = holdcloseLightTheme.textTheme.headlineMedium!;
        expect(style.fontSize, 22);
        expect(style.fontWeight, FontWeight.w600);
      });

      test('titleLarge — Montserrat 600 / 20', () {
        final TextStyle style = holdcloseLightTheme.textTheme.titleLarge!;
        expect(style.fontSize, 20);
        expect(style.fontWeight, FontWeight.w600);
      });

      test('bodyLarge — Lato 400 / 20 (large default per audience)', () {
        final TextStyle style = holdcloseLightTheme.textTheme.bodyLarge!;
        expect(style.fontSize, 20);
        expect(style.fontWeight, FontWeight.w400);
      });

      test('bodyMedium — Lato 400 / 16', () {
        final TextStyle style = holdcloseLightTheme.textTheme.bodyMedium!;
        expect(style.fontSize, 16);
        expect(style.fontWeight, FontWeight.w400);
      });

      test('labelLarge — Lato 700 / 18', () {
        final TextStyle style = holdcloseLightTheme.textTheme.labelLarge!;
        expect(style.fontSize, 18);
        expect(style.fontWeight, FontWeight.w700);
      });
    });
  });

  group('holdcloseDarkTheme', () {
    test('uses Material 3', () {
      expect(holdcloseDarkTheme.useMaterial3, isTrue);
    });

    test('brightness is dark', () {
      expect(holdcloseDarkTheme.brightness, Brightness.dark);
    });

    test('surface is the dark navy (#0F1422)', () {
      expect(holdcloseDarkTheme.colorScheme.surface, const Color(0xFF0F1422));
    });

    test('onSurface is the warm-white text (#E8E6E2)', () {
      expect(holdcloseDarkTheme.colorScheme.onSurface, const Color(0xFFE8E6E2));
    });

    test('secondary is the dark-palette CTA (brightened for contrast)', () {
      // Dark mode brightens the brand orange so the CTA keeps AA contrast
      // on the dark canvas; it intentionally differs from the light CTA.
      expect(
        holdcloseDarkTheme.colorScheme.secondary,
        holdcloseColorsDark.cta,
      );
    });

    test('primary is the dark-palette primary (lightened slate-blue)', () {
      // Navy-on-navy is illegible, so dark mode lifts `primary` to a pale
      // slate-blue for headings/icons/chips.
      expect(
        holdcloseDarkTheme.colorScheme.primary,
        holdcloseColorsDark.primary,
      );
    });

    test('registers the dark HoldcloseColors extension', () {
      expect(
        holdcloseDarkTheme.extension<HoldcloseColors>(),
        same(holdcloseColorsDark),
      );
    });

    test('light theme registers the light HoldcloseColors extension', () {
      expect(
        holdcloseLightTheme.extension<HoldcloseColors>(),
        same(holdcloseColors),
      );
    });

    test('scaffoldBackgroundColor matches the dark surface', () {
      expect(
        holdcloseDarkTheme.scaffoldBackgroundColor,
        const Color(0xFF0F1422),
      );
    });
  });
}
