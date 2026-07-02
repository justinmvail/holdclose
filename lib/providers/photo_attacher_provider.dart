import 'dart:async';
import 'dart:io' show Platform;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/real_capture.dart';

part 'photo_attacher_provider.g.dart';

/// Photo-attach surface for the journal-entry detail screen
/// (BUILD_SPEC.md §5.6 — "Photo: 📷 attach button, thumbnail inline
/// once attached").
///
/// V1 ships without `image_picker` in pubspec.yaml (BUILD_SPEC.md §1
/// pin invariant). This interface is the swappable seam: production
/// wires [NoopPhotoAttacher], which returns a placeholder asset path
/// so the UI affordance is visible and the persistence wiring is
/// exercised; widget tests wire a stand-in that returns deterministic
/// paths and tracks invocations.
///
/// When a real camera/library plugin lands, only the concrete impl
/// changes — consumers keep reading through [photoAttacherProvider].
/// Which OS surface a photo pick should open. Kept plugin-agnostic (no
/// `image_picker` import here) so the interface + test fakes stay decoupled
/// from the concrete capture plugin; [RealPhotoAttacher] maps it to an
/// `ImageSource`.
enum PhotoSource { camera, library }

abstract class PhotoAttacher {
  /// Present the OS picker and return the chosen image's on-device path,
  /// or null if the user cancelled. [source] selects the camera vs. the
  /// photo library; it defaults to the library so existing callers
  /// (journal, expenses) keep their behavior.
  ///
  /// [maxSide] / [quality] bound the captured image at pick time (the
  /// plugin downscales + JPEG-compresses). Defaults suit stored photos
  /// (journal, docs). Callers that upload the image to a vision model —
  /// the prescription scan — pass a smaller [maxSide]/[quality] so the
  /// upload is small on every backend (labels stay legible ~1500px), NOT
  /// relying on any server to shrink it.
  Future<String?> pickPhoto({
    PhotoSource source = PhotoSource.library,
    int maxSide = 2048,
    int quality = 80,
  });
}

/// No-op impl used by production until an `image_picker`-backed
/// concrete lands. Returns a deterministic placeholder path so the
/// journal entry's "📷 attached" affordance is exercised end-to-end.
class NoopPhotoAttacher implements PhotoAttacher {
  const NoopPhotoAttacher();

  @override
  Future<String?> pickPhoto({
    PhotoSource source = PhotoSource.library,
    int maxSide = 2048,
    int quality = 80,
  }) async =>
      'assets/seed/sample-photo-1.jpg';
}

/// Whether to use real device capture (camera / microphone / dictation)
/// over the production fakes (#8). **Automatic** — real on a PHYSICAL
/// device, the [NoopPhotoAttacher] / Noop / Unavailable fakes on the iOS
/// simulator and under `flutter test`. So the demo + tests never touch the
/// OS camera, gallery, or mic, and a real-device build "just works" with no
/// flag to remember. `--dart-define=USE_REAL_CAPTURE=true` forces it on
/// anywhere (e.g. to exercise the real path).
bool get useRealCapture =>
    const bool.fromEnvironment('USE_REAL_CAPTURE', defaultValue: false) ||
    _isPhysicalDevice;

/// True only on a real device — not the iOS simulator, not under
/// `flutter test`. The iOS simulator exports `SIMULATOR_*` env vars a
/// physical device lacks; `flutter test` exports `FLUTTER_TEST`. Android
/// emulator detection needs a plugin, so Android stays on the fakes unless
/// `USE_REAL_CAPTURE` is set explicitly. Any detection failure falls back
/// to the safe (fake) path.
bool get _isPhysicalDevice {
  try {
    final Map<String, String> env = Platform.environment;
    if (env.containsKey('FLUTTER_TEST')) return false;
    if (Platform.isIOS) {
      return !env.containsKey('SIMULATOR_DEVICE_NAME') &&
          !env.containsKey('SIMULATOR_UDID');
    }
    return false; // Android / other: explicit USE_REAL_CAPTURE only
  } catch (_) {
    return false;
  }
}

/// Pure impl selector — [RealPhotoAttacher] when [useReal] is set, else
/// the [NoopPhotoAttacher] fake. Split out from the provider so both
/// branches are unit-testable without recompiling against the
/// `USE_REAL_CAPTURE` dart-define.
PhotoAttacher selectPhotoAttacher(bool useReal) =>
    useReal ? RealPhotoAttacher() : const NoopPhotoAttacher();

/// Riverpod-wired photo attacher. Widgets read this and get whichever
/// impl the build mode picked (real `image_picker` when [useRealCapture]
/// is set, the no-op fake otherwise) — or whatever a test overrode.
@Riverpod(keepAlive: true)
PhotoAttacher photoAttacher(Ref ref) => selectPhotoAttacher(useRealCapture);
