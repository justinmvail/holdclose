import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/medication_draft.dart';
import '../../providers/photo_attacher_provider.dart';
import '../../providers/prescription_scanner_provider.dart';
import '../../services/prescription_scanner.dart';
import '../../theme.dart';
import '../../services/log_buffer.dart';

/// Shared orchestration for the AI prescription scan: choose camera vs.
/// library, capture a small vision-optimized image, run the scanner, and
/// return the proposed [MedicationDraft].
///
/// Contract:
///   * returns **null** when the caregiver cancels (no photo taken);
///   * returns a [MedicationDraft] when a photo WAS captured — which may be
///     [MedicationDraft.isEmpty] if the label couldn't be read (callers
///     decide whether to open a blank form or show a "couldn't read" hint).
///
/// Used by the Medications list (first scan → review screen) and the review
/// screen itself (optional second photo → merge into the current fields),
/// so the label may wrap around the bottle and still be captured fully.
Future<MedicationDraft?> capturePrescriptionDraft(
  BuildContext context,
  WidgetRef ref,
) async {
  final PhotoAttacher picker = ref.read(photoAttacherProvider);
  final PrescriptionScanner scanner = ref.read(prescriptionScannerProvider);

  final PhotoSource? source = await showModalBottomSheet<PhotoSource>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take photo'),
            onTap: () => Navigator.of(sheetContext).pop(PhotoSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from library'),
            onTap: () => Navigator.of(sheetContext).pop(PhotoSource.library),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;

  // Vision-optimized capture: a prescription label is legible ~1536px, so
  // capture small (keeps the upload light on every backend — dev shim AND
  // the production vision API — instead of shipping a multi-MB photo).
  final String? path =
      await picker.pickPhoto(source: source, maxSide: 1536, quality: 70);
  if (path == null || !context.mounted) return null;

  // Blocking progress while the model reads the label. Deliberately not
  // awaited — it resolves when we pop it below, not before.
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  ));

  MedicationDraft? draft;
  try {
    draft = await scanner.extractFromImage(imagePath: path);
  } catch (e) {
    // Caregiver still gets the "couldn't read it" hint below — but the WHY
    // (licence gate, network, a 500, a parse miss) rode into the void until a
    // report could reproduce it. Keep the trace.
    logNonFatal('scan.prescription', e);
    draft = null;
  }

  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop(); // dismiss progress
  }
  // A photo WAS taken; hand back an empty draft (not null) if the read
  // failed, so callers can tell "cancelled" from "couldn't read it".
  return draft ?? const MedicationDraft();
}

/// Snackbar helper for a scan that read nothing usable — keeps the "couldn't
/// read" copy consistent across entry points. Uses the brand CTA color.
void showScanEmptyHint(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text(
        "Couldn't read that photo. Try again in better light, or enter the "
        'details by hand.',
      ),
      backgroundColor: context.hc.primary,
    ),
  );
}
