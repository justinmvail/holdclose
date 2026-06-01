import 'package:flutter/material.dart';

/// Which quick-add the caregiver chose from the Home Add sheet
/// (BUILD_SPEC.md Phase 14.13). Rides along with a captured transcript
/// (see [AddSheetTranscript]) so the destination screen knows which
/// field to pre-fill.
///
/// Defined here — alongside the intake plumbing that reads it — rather
/// than in the Add-sheet widget, so the destination screens + router can
/// interpret a transcript without importing the widget layer (which
/// would close an import cycle through [VoiceButton]). The Add sheet
/// re-exports both types for its existing call sites.
enum AddSheetKind { journalEntry, medDose, appointment, quickNote }

/// Nav-`extra` payload handed to a quick-add destination when the Add
/// sheet row's voice button captured a transcript. A plain immutable
/// value (mirrors `JournalWizardArgs`) — not a freezed model, since it
/// never persists or serializes; it only rides a single `push`.
@immutable
class AddSheetTranscript {
  const AddSheetTranscript({required this.text, required this.kind});

  final String text;
  final AddSheetKind kind;

  @override
  bool operator ==(Object other) =>
      other is AddSheetTranscript &&
      other.text == text &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(text, kind);
}

/// Bridges a voice transcript captured on a Home Add-sheet row into the
/// pre-fill value its destination screen expects (BUILD_SPEC.md Phase
/// 14.14).
///
/// The Add sheet pushes the chosen destination route with an
/// [AddSheetTranscript] in the nav `extra` (Phase 14.13). Each
/// destination's route builder asks this bridge for the slice of that
/// payload it cares about:
///
///   - `/journal/new` (journal-entry + quick-note rows) → seed the
///     wizard's situation step via `JournalWizardArgs(initialTranscript:
///     …)`. The router does the wrapping so this service stays free of a
///     screen import.
///   - `/appointments/new` → pre-fill the visit-notes textarea.
///   - `/medications/today` → pre-fill the dose-note field.
///
/// Every accessor returns null when the `extra` is absent, the wrong
/// type (a deep link, an edit-path hydration object, a plain row tap), a
/// mismatched kind, or a blank transcript — so a screen reached any
/// other way opens with no pre-fill.
class VoiceIntake {
  const VoiceIntake._();

  /// The trimmed transcript an Add-sheet [kind] row forwarded as nav
  /// [extra], or null when [extra] carries no usable transcript for that
  /// kind.
  static String? transcriptFor(Object? extra, AddSheetKind kind) {
    if (extra is! AddSheetTranscript) return null;
    if (extra.kind != kind) return null;
    final String text = extra.text.trim();
    return text.isEmpty ? null : text;
  }

  /// Transcript bound for the journal wizard — both the journal-entry
  /// row and the quick-note row land in the same wizard, so either kind
  /// counts.
  static String? journalTranscript(Object? extra) =>
      transcriptFor(extra, AddSheetKind.journalEntry) ??
      transcriptFor(extra, AddSheetKind.quickNote);

  /// Transcript bound for the appointment form's visit-notes field.
  static String? appointmentNotes(Object? extra) =>
      transcriptFor(extra, AddSheetKind.appointment);

  /// Transcript bound for the dose-log screen's dose-note field.
  static String? doseNote(Object? extra) =>
      transcriptFor(extra, AddSheetKind.medDose);
}

/// Snackbar copy shown when a voice capture is refused because mic /
/// speech permission is off. Warm + actionable, names the two ways
/// forward (Settings or typing), and never references the speech tech
/// itself (CLAUDE.md voice rules).
const String voiceCapturePermissionDeniedMessage =
    'Microphone access is off. Turn it on in Settings to add by voice, '
    'or type it in instead.';

/// Surface [voiceCapturePermissionDeniedMessage] on the nearest
/// [ScaffoldMessenger]. Called from the [VoiceButton] capture flow when
/// `capture()` raises [VoiceCapturePermissionDeniedException]. Replaces
/// any in-flight snackbar so repeated taps don't stack.
void showVoiceCapturePermissionDeniedSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(content: Text(voiceCapturePermissionDeniedMessage)),
    );
}
