/// Single source of truth for the app version + per-build metadata.
///
/// The version NAME is defined once here in [_fallbackName]; keep it equal to
/// `pubspec.yaml`'s `version:` name. `tools/run_device.sh` and
/// `tools/build_ipa.sh` read pubspec and pass
/// `--dart-define=APP_VERSION=<name>+<buildNumber>`, so on a stamped build
/// [versionName] / [fullVersion] reflect pubspec exactly; a plain
/// `flutter run` (no defines) falls back to [_fallbackName].
///
/// [buildStamp] is the distinct-per-compile build number (epoch seconds) the
/// scripts inject, surfaced in Settings → About so a tester can confirm which
/// binary is on the device.
class BuildInfo {
  const BuildInfo._();

  /// The ONE hardcoded copy of the marketing version name. Must match the
  /// `version:` name in pubspec.yaml.
  static const String _fallbackName = '0.1.0';

  static const String _appVersionDefine =
      String.fromEnvironment('APP_VERSION', defaultValue: '');

  /// Distinct build number per compile (epoch), or 'dev' when un-stamped.
  static const String buildStamp =
      String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev');
  static const String gitSha =
      String.fromEnvironment('GIT_SHA', defaultValue: '');
  static const String gitBranch =
      String.fromEnvironment('GIT_BRANCH', defaultValue: '');
  static const String buildTime =
      String.fromEnvironment('BUILD_TIME', defaultValue: '');

  /// Marketing version name, e.g. "0.1.0".
  static String get versionName {
    if (_appVersionDefine.isEmpty) return _fallbackName;
    final int plus = _appVersionDefine.indexOf('+');
    return plus == -1
        ? _appVersionDefine
        : _appVersionDefine.substring(0, plus);
  }

  /// "<name>+<build>" for logs / telemetry, e.g. "0.1.0+1783031319".
  static String get fullVersion => _appVersionDefine.isEmpty
      ? '$_fallbackName+$buildStamp'
      : _appVersionDefine;

  /// Human build context: "2026-07-02 22:28 UTC · dev @ 0197908+", or null on
  /// an un-stamped build (nothing was injected).
  static String? get contextLine {
    final String source = <String>[
      if (gitBranch.isNotEmpty) gitBranch,
      if (gitSha.isNotEmpty) gitSha,
    ].join(' @ ');
    final List<String> parts = <String>[
      if (buildTime.isNotEmpty) buildTime,
      if (source.isNotEmpty) source,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
