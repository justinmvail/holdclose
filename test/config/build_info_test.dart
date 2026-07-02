import 'package:flutter_test/flutter_test.dart';
import 'package:holdclose/config/build_info.dart';

/// Under `flutter test` no --dart-define is set, so BuildInfo exercises its
/// un-stamped fallbacks — the single source of truth for the version name.
void main() {
  test('versionName falls back to the pubspec name when un-stamped', () {
    expect(BuildInfo.versionName, '0.1.0');
  });

  test('fullVersion is "<name>+<stamp>" and stamp defaults to dev', () {
    expect(BuildInfo.buildStamp, 'dev');
    expect(BuildInfo.fullVersion, '0.1.0+dev');
  });

  test('contextLine is null with no git/time injected', () {
    expect(BuildInfo.contextLine, isNull);
  });
}
