import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

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
abstract class PhotoAttacher {
  /// Present the OS picker (camera + library) and return the chosen
  /// image's on-device path. Returns null if the user cancelled.
  Future<String?> pickPhoto();
}

/// No-op impl used by production until an `image_picker`-backed
/// concrete lands. Returns a deterministic placeholder path so the
/// journal entry's "📷 attached" affordance is exercised end-to-end.
class NoopPhotoAttacher implements PhotoAttacher {
  const NoopPhotoAttacher();

  @override
  Future<String?> pickPhoto() async => 'assets/seed/sample-photo-1.jpg';
}

/// Riverpod-wired photo attacher. Widgets read this and get whichever
/// impl the host overrode (or the no-op default in production).
@Riverpod(keepAlive: true)
PhotoAttacher photoAttacher(Ref ref) => const NoopPhotoAttacher();
