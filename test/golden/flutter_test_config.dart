import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Alchemist test config, scoped to `test/golden/`.
///
/// Per the alchemist README "Recommended Setup Guide": separates CI
/// goldens (rendered with the Ahem font, platform-stable, committed
/// under `goldens/ci/`) from platform goldens (only on the local host,
/// for debugging — see the `.gitignore` rule that drops everything
/// outside `goldens/ci/`).
///
/// We deliberately do **not** pass `holdcloseLightTheme` here.
/// google_fonts requires either bundled font assets or a runtime
/// fetch; neither is available in `flutter test`. Each screen widget
/// that cares about brand styling re-applies the relevant brand
/// color/theme tokens in its own subtree (e.g. `TabScaffoldBar`
/// overrides `NavigationBarTheme` directly with `holdcloseColors`),
/// so goldens stay brand-accurate without dragging the TextTheme
/// (and its google_fonts dependency) through the test framework.
///
/// `allowRuntimeFetching = false` is the belt-and-braces: if a screen
/// does inadvertently pull in a GoogleFonts TextStyle, the test fails
/// loudly here instead of silently hanging on a network round-trip.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  // ignore: do_not_use_environment
  const bool isRunningInCi = bool.fromEnvironment('CI', defaultValue: false);

  return AlchemistConfig.runWithConfig(
    config: const AlchemistConfig(
      platformGoldensConfig: PlatformGoldensConfig(
        enabled: !isRunningInCi,
      ),
    ),
    run: testMain,
  );
}
