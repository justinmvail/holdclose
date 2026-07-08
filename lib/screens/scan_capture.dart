import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/photo_attacher_provider.dart';
import '../theme.dart';

/// Generic scan capture shared by the AI document-scan features
/// (prescriptions, appointment cards, …): offer camera vs. library,
/// capture a small vision-optimized image, then run [extract].
///
/// Returns **null** when the caregiver cancels (no photo). Otherwise returns
/// the extracted draft — which may be [emptyDraft] if the label/card
/// couldn't be read (callers then open a blank form for manual entry, or
/// show [showScanCouldNotReadHint]).
Future<T?> captureScanDraft<T>(
  BuildContext context,
  WidgetRef ref, {
  required Future<T?> Function(String imagePath) extract,
  required T emptyDraft,
}) async {
  final PhotoAttacher picker = ref.read(photoAttacherProvider);

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

  // Vision-optimized capture: small upload, legible ~1536px, light on every
  // backend (dev shim AND the production vision API).
  final String? path =
      await picker.pickPhoto(source: source, maxSide: 1536, quality: 70);
  if (path == null || !context.mounted) return null;

  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  ));

  T? result;
  try {
    result = await extract(path);
  } catch (_) {
    result = null;
  }

  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop(); // dismiss progress
  }
  return result ?? emptyDraft;
}

/// Consistent "couldn't read it" snackbar across scan entry points.
void showScanCouldNotReadHint(BuildContext context) {
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
