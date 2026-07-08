import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/voice_capture_provider.dart';
import '../services/voice_intake.dart';
import '../theme.dart';

/// A compact circular mic button. On press it captures one spoken phrase
/// through the [voiceCaptureProvider] seam and, when a non-blank
/// transcript comes back, hands it to [onTranscript]. While the capture
/// future is in flight the glyph swaps to a small progress ring and the
/// button disables itself, so a second tap can't start an overlapping
/// capture.
///
/// The button owns no routing — callers decide what to do with the
/// transcript. In the Home Add sheet each row forwards it to that row's
/// destination route as an `AddSheetTranscript` (BUILD_SPEC.md Phase
/// 14.13); the downstream pre-fill is Phase 14.14's job.
class VoiceButton extends ConsumerStatefulWidget {
  const VoiceButton({
    super.key,
    required this.onTranscript,
    this.semanticLabel = 'Add by voice',
  });

  /// Invoked with the trimmed transcript when capture yields non-blank
  /// text. Not called for a null/blank/aborted capture.
  final ValueChanged<String> onTranscript;

  /// Screen-reader label + tooltip for the button.
  final String semanticLabel;

  @override
  ConsumerState<VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends ConsumerState<VoiceButton> {
  bool _capturing = false;

  Future<void> _capture() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    try {
      final String? transcript =
          await ref.read(voiceCaptureProvider).capture();
      if (!mounted) return;
      final String text = transcript?.trim() ?? '';
      if (text.isNotEmpty) widget.onTranscript(text);
    } on VoiceCapturePermissionDeniedException {
      // Mic blocked — surface a clear, actionable prompt instead of
      // failing silently (Phase 14.14). A null/blank capture stays
      // silent; only a denied permission speaks up.
      if (!mounted) return;
      showVoiceCapturePermissionDeniedSnackBar(context);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _capturing ? null : _capture,
      tooltip: widget.semanticLabel,
      icon: _capturing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.mic_none, color: context.hc.primarySoft),
    );
  }
}
