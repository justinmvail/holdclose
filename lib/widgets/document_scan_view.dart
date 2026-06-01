import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';

/// A tappable thumbnail of a scanned document image (TASKS.md Phase
/// 14.24) — the POA signed-document scan and the front/back photos of an
/// identification card.
///
/// Given an on-disk [path], renders a rounded thumbnail of the image and,
/// on tap, opens [showDocumentScanViewer] — a full-screen, pinch-zoomable
/// viewer. When [path] is null (no scan captured yet) it renders a muted
/// placeholder instead, and the tap is disabled.
///
/// The image is loaded with [Image.file] and an [errorBuilder] so a
/// missing / unreadable file degrades to the same placeholder rather than
/// throwing — widget tests and goldens run without real image bytes on
/// disk, so the placeholder path is the one they exercise.
class DocumentScanThumbnail extends StatelessWidget {
  const DocumentScanThumbnail({
    super.key,
    required this.path,
    required this.label,
    this.width = 96,
    this.height = 128,
  });

  /// On-disk image path, or null when no scan/photo has been captured.
  final String? path;

  /// Caption shown beneath the thumbnail (e.g. "Scan", "Front", "Back")
  /// and woven into the semantic label for screen readers.
  final String label;

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String? scanPath = path;
    final bool hasScan = scanPath != null && scanPath.isNotEmpty;

    final Widget thumb = Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: careblazersColors.primary.withValues(alpha: 0.12),
          width: 1.5,
        ),
      ),
      child: hasScan
          ? Image.file(
              File(scanPath),
              fit: BoxFit.cover,
              errorBuilder: (BuildContext context, Object _, StackTrace? __) =>
                  const _ScanPlaceholder(),
            )
          : const _ScanPlaceholder(),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          button: hasScan,
          image: true,
          label: hasScan
              ? '$label scan. Double-tap to view full screen.'
              : 'No $label scan on file.',
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: hasScan
                ? () => showDocumentScanViewer(context, scanPath, title: label)
                : null,
            child: thumb,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primarySoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Muted placeholder shown when a thumbnail has no image (or the image
/// can't be read).
class _ScanPlaceholder extends StatelessWidget {
  const _ScanPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.image_outlined,
        size: 28,
        color: careblazersColors.primarySoft.withValues(alpha: 0.6),
      ),
    );
  }
}

/// Key for the full-screen viewer surface so tests can assert it opened.
const Key documentScanViewerKey = Key('document-scan-viewer');

/// Open a full-screen, pinch-zoomable viewer for the image at [path]
/// (TASKS.md Phase 14.24). Dismissed by the close button or a tap on the
/// scrim. Uses [showDialog] so it layers above the current navigator
/// without disturbing the go_router stack.
Future<void> showDocumentScanViewer(
  BuildContext context,
  String path, {
  String? title,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (BuildContext context) {
      return Dialog.fullscreen(
        key: documentScanViewerKey,
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4,
                  child: Center(
                    child: Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder:
                          (BuildContext context, Object _, StackTrace? __) =>
                              Icon(
                        Icons.broken_image_outlined,
                        size: 64,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Semantics(
                  button: true,
                  label: 'Close the ${title ?? 'document'} viewer.',
                  child: IconButton(
                    key: const Key('document-scan-viewer-close'),
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
