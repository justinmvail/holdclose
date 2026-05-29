import 'dart:async';
import 'dart:io';

import 'package:alchemist/alchemist.dart';

/// Project-wide alchemist configuration.
///
/// Reads the runtime `CI` environment variable. When `CI=1` (or any
/// non-empty value), disables platform-specific golden generation
/// (macOS / linux / windows) so the test only asserts the CI-portable
/// golden. The argus autoloop's gate exports `CI=1` for exactly this
/// reason: without it, alchemist generates per-host `goldens/<platform>
/// /*.png` files that are gitignored (per alchemist's recommended
/// setup) and never committed — leading the post-push gate to fail in
/// argusRepo with "Could not be compared against non-existent file."
///
/// Local devs running `flutter test` outside the autoloop without
/// `CI=1` still get both variants; their macOS goldens land in
/// `test/**/goldens/macos/` and stay gitignored.
///
/// Uses `Platform.environment` (runtime lookup) rather than
/// `bool.fromEnvironment('CI')` (compile-time `--dart-define`) because
/// the autoloop's gate exports `CI` as a normal shell env var.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final isCi = (Platform.environment['CI'] ?? '').isNotEmpty;
  return AlchemistConfig.runWithConfig(
    config: AlchemistConfig(
      platformGoldensConfig: PlatformGoldensConfig(enabled: !isCi),
    ),
    run: testMain,
  );
}
