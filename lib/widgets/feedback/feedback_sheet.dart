import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart' show CrashLog;
import '../../providers/auth_provider.dart';
import '../../providers/voice_capture_provider.dart';
import '../../services/feedback_service.dart';
import '../../services/log_buffer.dart';
import '../../services/voice_intake.dart';
import '../../theme.dart';
import '../holdclose_switch.dart';

/// Opens the alpha feedback sheet. Shared entry point so the overlay and
/// tests use one path. [route] is the screen the tester was on; [screenshot]
/// is the captured PNG (may be null if capture failed).
Future<void> showFeedbackSheet(
  BuildContext context, {
  required String route,
  Uint8List? screenshot,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.hc.background,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) =>
        FeedbackSheet(route: route, screenshot: screenshot),
  );
}

/// The report form. One category tap, one sentence, send. The tester's
/// name is asked once (first report) and remembered; the screen, a
/// screenshot, and build/device info ride along automatically so the
/// tester types as little as possible.
class FeedbackSheet extends ConsumerStatefulWidget {
  const FeedbackSheet({super.key, required this.route, this.screenshot});

  final String route;
  final Uint8List? screenshot;

  static const Key sheetKey = Key('alpha-feedback-sheet');
  static const Key nameFieldKey = Key('alpha-feedback-name');
  static const Key messageFieldKey = Key('alpha-feedback-message');
  static const Key micKey = Key('alpha-feedback-mic');
  static const Key screenshotToggleKey = Key('alpha-feedback-screenshot-toggle');
  static const Key logsToggleKey = Key('alpha-feedback-logs-toggle');
  static const Key crashLogToggleKey = Key('alpha-feedback-crash-toggle');
  static const Key sendButtonKey = Key('alpha-feedback-send');

  static Key categoryKey(FeedbackCategory c) =>
      Key('alpha-feedback-cat-${c.name}');

  /// Test seams for the on-device crash log. Default to the real [CrashLog]
  /// singleton; widget tests override them with synchronous fakes so the
  /// sheet never fires real `dart:io` reads/deletes (which cross the
  /// fake-async test boundary and flake). Not a production knob.
  @visibleForTesting
  static Future<String> Function() crashLogReader = CrashLog.instance.read;
  @visibleForTesting
  static Future<void> Function() crashLogClearer = CrashLog.instance.clear;

  @override
  ConsumerState<FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends ConsumerState<FeedbackSheet> {
  final TextEditingController _message = TextEditingController();
  final TextEditingController _name = TextEditingController();
  FeedbackCategory _category = FeedbackCategory.bug;
  bool _needsName = false;

  /// True while a spoken phrase is being dictated into the message field
  /// (fb_1781129218678980 — "let me use voice to text when filing a bug").
  bool _dictating = false;

  /// Whether the screen capture rides along. **Opt-in** (default OFF): a
  /// screenshot of the current screen can carry the loved one's PHI (meds,
  /// the emergency card, journal text), so the caregiver must deliberately
  /// choose to attach it rather than have it default on.
  bool _includeScreenshot = false;

  /// Whether the recent-log snapshot rides along with the report. On by
  /// default — the logs are what make "works but wrong" reports diagnosable
  /// — but visible and declinable, because the buffer can carry whatever any
  /// log line happened to print. The note under the toggle spells that out.
  bool _includeLogs = true;
  bool _submitting = false;

  /// A prior launch's uncaught-error trace ([CrashLog]), loaded on open.
  /// Empty when the last run didn't crash. When present, the sheet offers a
  /// declinable toggle to attach it so a crash-on-launch still gets a
  /// channel — on-device + user-initiated, never auto-uploaded.
  String _crashLog = '';
  bool _includeCrashLog = true;

  @override
  void initState() {
    super.initState();
    _loadName();
    _loadCrashLog();
  }

  /// Pull the persisted crash trace (if the last run crashed) so the sheet
  /// can offer it as attachable context. Silent when there's nothing to
  /// attach — the toggle only appears when a trace exists.
  Future<void> _loadCrashLog() async {
    final String crash = await FeedbackSheet.crashLogReader();
    if (!mounted || crash.trim().isEmpty) return;
    setState(() => _crashLog = crash);
  }

  Future<void> _loadName() async {
    final String? stored = await ref.read(testerNameStoreProvider).get();
    String? name =
        (stored != null && stored.trim().isNotEmpty) ? stored.trim() : null;
    // Fall back to the signed-in (Google) account name so an authenticated
    // tester is never blocked behind the "what should I call you?" prompt —
    // we already know who they are. Only ask when we have no name at all.
    if (name == null) {
      try {
        final AuthState state =
            await ref.read(authProvider).watchAuthState().first;
        if (state is AuthStateSignedIn && state.user.name.trim().isNotEmpty) {
          name = state.user.name.trim();
        }
      } catch (_) {
        // No auth available — fall through to asking for a name.
      }
    }
    if (!mounted) return;
    setState(() {
      _needsName = name == null;
      if (name != null) _name.text = name;
    });
    // Remember it for next time + attribution, if it wasn't already stored.
    if (stored == null && name != null) {
      await ref.read(testerNameStoreProvider).set(name);
    }
  }

  @override
  void dispose() {
    _message.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Capture a spoken phrase into the message field (fb_1781129218678980).
  /// Appends to whatever's already typed; streams partials in as they're
  /// recognized. Reuses the shared [VoiceCapture] seam — no new speech
  /// pipeline — so tests inject a fake and a denied mic shows the standard
  /// snackbar.
  Future<void> _dictate() async {
    if (_dictating) return;
    setState(() => _dictating = true);
    final String base = _message.text;
    final String prefix = base.isEmpty ? '' : '${base.trimRight()} ';
    void fill(String words) {
      final String joined = '$prefix$words';
      _message
        ..text = joined
        ..selection = TextSelection.collapsed(offset: joined.length);
    }

    try {
      final String? transcript = await ref.read(voiceCaptureProvider).capture(
        onPartial: (String partial) {
          if (mounted && partial.trim().isNotEmpty) fill(partial);
        },
      );
      if (!mounted) return;
      final String text = transcript?.trim() ?? '';
      if (text.isEmpty) {
        _message
          ..text = base
          ..selection = TextSelection.collapsed(offset: base.length);
      } else {
        fill(text);
      }
    } on VoiceCapturePermissionDeniedException {
      if (!mounted) return;
      _message
        ..text = base
        ..selection = TextSelection.collapsed(offset: base.length);
      showVoiceCapturePermissionDeniedSnackBar(context);
    } finally {
      if (mounted) setState(() => _dictating = false);
    }
  }

  bool get _canSend =>
      !_submitting &&
      _message.text.trim().isNotEmpty &&
      (!_needsName || _name.text.trim().isNotEmpty);

  Future<void> _send() async {
    if (!_canSend) return;
    setState(() => _submitting = true);

    final String name = _name.text.trim();
    if (_needsName && name.isNotEmpty) {
      await ref.read(testerNameStoreProvider).set(name);
    }

    final bool attach = _includeScreenshot && widget.screenshot != null;
    // Fold the recent-log snapshot and (if present + opted-in) the prior
    // crash trace into one logs blob — both under visible consent toggles.
    final bool attachCrash = _includeCrashLog && _crashLog.trim().isNotEmpty;
    final String logs = <String>[
      if (_includeLogs) LogBuffer.instance.snapshot(),
      if (attachCrash) '=== Crash from a previous run ===\n$_crashLog',
    ].where((String s) => s.trim().isNotEmpty).join('\n\n');
    final FeedbackReport report = FeedbackReport.create(
      category: _category,
      message: _message.text.trim(),
      route: widget.route,
      testerName: name,
      hasScreenshot: attach,
      // Snapshot recent on-device logs so the report carries context that
      // a screenshot + sentence can't (the "works but wrong" class) —
      // but ONLY with the tester's visible consent (the toggles below).
      logs: logs,
    );
    final bool delivered =
        await ref.read(feedbackControllerProvider).submit(
              report,
              attach ? widget.screenshot : null,
            );
    // The crash has now been carried into a report — drop it so it isn't
    // re-offered on every future report.
    if (attachCrash) {
      await FeedbackSheet.crashLogClearer();
    }

    if (!mounted) return;
    // Resolve the messenger before the pop — the sheet's own context is
    // torn down by pop, so we can't read inherited widgets off it after.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          delivered
              ? 'Thanks — your note was saved and sent.'
              : 'Thanks — saved. It will send when you’re back online.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      // Lift the content above the keyboard while it's open.
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          key: FeedbackSheet.sheetKey,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Report a bug or idea',
              style: textTheme.titleLarge?.copyWith(
                color: context.hc.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'On screen: ${widget.route}',
              style: textTheme.bodyMedium?.copyWith(
                color: context.hc.text.withValues(alpha: 0.7),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final FeedbackCategory c in FeedbackCategory.values)
                  ChoiceChip(
                    key: FeedbackSheet.categoryKey(c),
                    label: Text(c.label),
                    selected: _category == c,
                    selectedColor: context.hc.primary,
                    labelStyle: TextStyle(
                      color: _category == c
                          ? Colors.white
                          : context.hc.text,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_needsName) ...<Widget>[
              TextField(
                key: FeedbackSheet.nameFieldKey,
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'What should I call you?',
                  hintText: 'First name or initials',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: FeedbackSheet.messageFieldKey,
              controller: _message,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'What happened? What would make it better?',
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
                // Dictate the report instead of typing it
                // (fb_1781129218678980). Same on-device capture seam the chat
                // composer uses.
                suffixIcon: Semantics(
                  button: true,
                  enabled: !_dictating,
                  label: _dictating
                      ? 'Listening. Speak your report.'
                      : 'Dictate your report.',
                  child: IconButton(
                    key: FeedbackSheet.micKey,
                    onPressed: _dictating ? null : _dictate,
                    icon: _dictating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.mic, color: context.hc.cta),
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (widget.screenshot != null) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  // Bounded via SizedBox so an intrinsic-width pass (which the
                  // adjacent switch's cross-fade can trigger) reads a fixed
                  // 40px, not the image's natural width — otherwise the Row's
                  // Expanded text contributes its full unwrapped width and the
                  // row overflows mid-animation.
                  SizedBox(
                    width: 40,
                    height: 64,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        widget.screenshot!,
                        width: 40,
                        height: 64,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Attach a screenshot (may show your loved one's details)",
                      style: textTheme.bodyMedium?.copyWith(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  HoldcloseSwitch(
                    key: FeedbackSheet.screenshotToggleKey,
                    value: _includeScreenshot,
                    onChanged: (bool v) =>
                        setState(() => _includeScreenshot = v),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Icon(Icons.receipt_long_outlined,
                    size: 20, color: context.hc.primarySoft),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Include recent app activity logs',
                    style: textTheme.bodyMedium?.copyWith(fontSize: 14),
                  ),
                ),
                HoldcloseSwitch(
                  key: FeedbackSheet.logsToggleKey,
                  value: _includeLogs,
                  onChanged: (bool v) => setState(() => _includeLogs = v),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text(
                'Technical notes about what the app was doing — no photos, '
                'and nothing leaves your phone until you send.',
                style: textTheme.bodySmall?.copyWith(
                  color: context.hc.text.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ),
            // Only shown when a previous run left a crash trace on device.
            if (_crashLog.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded,
                      size: 20, color: context.hc.primarySoft),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Include the report from the last time the app closed '
                      'unexpectedly',
                      style: textTheme.bodyMedium?.copyWith(fontSize: 14),
                    ),
                  ),
                  HoldcloseSwitch(
                    key: FeedbackSheet.crashLogToggleKey,
                    value: _includeCrashLog,
                    onChanged: (bool v) =>
                        setState(() => _includeCrashLog = v),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: FeedbackSheet.sendButtonKey,
                style: FilledButton.styleFrom(
                  backgroundColor: context.hc.cta,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _canSend ? _send : null,
                child: Text(_submitting ? 'Sending…' : 'Send report'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
