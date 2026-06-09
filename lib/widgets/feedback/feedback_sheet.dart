import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../services/feedback_service.dart';
import '../../theme.dart';

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
    backgroundColor: context.cb.background,
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
  static const Key screenshotToggleKey = Key('alpha-feedback-screenshot-toggle');
  static const Key sendButtonKey = Key('alpha-feedback-send');

  static Key categoryKey(FeedbackCategory c) =>
      Key('alpha-feedback-cat-${c.name}');

  @override
  ConsumerState<FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends ConsumerState<FeedbackSheet> {
  final TextEditingController _message = TextEditingController();
  final TextEditingController _name = TextEditingController();
  FeedbackCategory _category = FeedbackCategory.bug;
  bool _needsName = false;
  bool _includeScreenshot = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadName();
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
    final FeedbackReport report = FeedbackReport.create(
      category: _category,
      message: _message.text.trim(),
      route: widget.route,
      testerName: name,
      hasScreenshot: attach,
    );
    final bool delivered =
        await ref.read(feedbackControllerProvider).submit(
              report,
              attach ? widget.screenshot : null,
            );

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
                color: context.cb.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'On screen: ${widget.route}',
              style: textTheme.bodyMedium?.copyWith(
                color: context.cb.text.withValues(alpha: 0.7),
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
                    selectedColor: context.cb.primary,
                    labelStyle: TextStyle(
                      color: _category == c
                          ? Colors.white
                          : context.cb.text,
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
              decoration: const InputDecoration(
                labelText: 'What happened? What would make it better?',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (widget.screenshot != null) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      widget.screenshot!,
                      width: 40,
                      height: 64,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Include a screenshot of this screen',
                      style: textTheme.bodyMedium?.copyWith(fontSize: 14),
                    ),
                  ),
                  Switch(
                    key: FeedbackSheet.screenshotToggleKey,
                    value: _includeScreenshot,
                    activeThumbColor: context.cb.primary,
                    onChanged: (bool v) =>
                        setState(() => _includeScreenshot = v),
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
                  backgroundColor: context.cb.cta,
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
