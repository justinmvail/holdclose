import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/journal_entry.dart';
import '../../providers/storage_provider.dart';
import '../../theme.dart';

/// Hand-off shape for the chat coach's `[action:log_journal …]` action
/// when it bounces the caregiver into the wizard for confirmation.
/// Passed as `extra` on the `/journal/new` push.
class JournalWizardArgs {
  const JournalWizardArgs({
    this.occurredAt,
    this.situationText,
    this.attemptsText,
    this.initialTranscript,
  });

  final DateTime? occurredAt;
  final String? situationText;
  final String? attemptsText;

  /// A spoken phrase captured from the Home Add sheet's voice button
  /// (Phase 14.14). Seeds the situation step so the caregiver lands on
  /// the wizard with their own words already typed in — they confirm /
  /// edit rather than retype. [situationText] (the chat-coach path)
  /// wins when both are supplied.
  final String? initialTranscript;
}

/// "When did it happen?" presets the wizard surfaces (BUILD_SPEC.md
/// §5.5 wizard). The custom slot opens the platform date+time picker so
/// the caregiver isn't boxed into a preset for a 2am episode.
enum JournalWhen {
  justNow,
  earlierToday,
  yesterday,
  custom;

  String get label {
    switch (this) {
      case JournalWhen.justNow:
        return 'Just now';
      case JournalWhen.earlierToday:
        return 'Earlier today';
      case JournalWhen.yesterday:
        return 'Yesterday';
      case JournalWhen.custom:
        return 'Pick a time';
    }
  }
}

/// Three-step journal wizard at `/journal/new` — when / situation /
/// attempts (BUILD_SPEC.md §5.5 home + chat-harness path).
///
/// Replaces the legacy decoder-driven "auto-log" path for the cases
/// where the caregiver wants to keep a moment without walking the
/// behavior picker. Submit lands a [JournalEntry.wizard] row in the
/// same drift table the journal screen reads from, so the entry
/// shows up in the list immediately.
class JournalWizardScreen extends ConsumerStatefulWidget {
  const JournalWizardScreen({super.key, this.args});

  final JournalWizardArgs? args;

  static const Key whenPresetJustNowKey = Key('journal-wizard-when-just-now');
  static const Key whenPresetEarlierTodayKey =
      Key('journal-wizard-when-earlier-today');
  static const Key whenPresetYesterdayKey =
      Key('journal-wizard-when-yesterday');
  static const Key whenPresetCustomKey = Key('journal-wizard-when-custom');
  static const Key situationFieldKey = Key('journal-wizard-situation');
  static const Key attemptsFieldKey = Key('journal-wizard-attempts');
  static const Key nextButtonKey = Key('journal-wizard-next');
  static const Key backButtonKey = Key('journal-wizard-back');
  static const Key submitButtonKey = Key('journal-wizard-submit');
  static const Key progressKey = Key('journal-wizard-progress');

  static const int totalSteps = 3;

  @override
  ConsumerState<JournalWizardScreen> createState() =>
      _JournalWizardScreenState();
}

class _JournalWizardScreenState extends ConsumerState<JournalWizardScreen> {
  int _step = 0;
  JournalWhen? _whenPreset;
  DateTime? _customOccurredAt;
  final TextEditingController _situationController = TextEditingController();
  final TextEditingController _attemptsController = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final JournalWizardArgs? args = widget.args;
    if (args == null) return;
    if (args.occurredAt != null) {
      _whenPreset = JournalWhen.custom;
      _customOccurredAt = args.occurredAt;
    }
    if (args.situationText != null) {
      _situationController.text = args.situationText!;
    } else if (args.initialTranscript != null) {
      // Voice intake (Phase 14.14): the spoken phrase is the caregiver's
      // own account of the moment, so it seeds the "what was happening?"
      // step. They edit from there.
      _situationController.text = args.initialTranscript!;
    }
    if (args.attemptsText != null) {
      _attemptsController.text = args.attemptsText!;
    }
  }

  @override
  void dispose() {
    _situationController.dispose();
    _attemptsController.dispose();
    super.dispose();
  }

  DateTime _resolveOccurredAt() {
    final DateTime now = DateTime.now();
    switch (_whenPreset ?? JournalWhen.justNow) {
      case JournalWhen.justNow:
        return now;
      case JournalWhen.earlierToday:
        // 4 hours ago, clamped to the start of today so a 2am tap
        // doesn't roll into yesterday.
        final DateTime tentative = now.subtract(const Duration(hours: 4));
        final DateTime startOfToday =
            DateTime(now.year, now.month, now.day);
        return tentative.isBefore(startOfToday) ? startOfToday : tentative;
      case JournalWhen.yesterday:
        // Yesterday at the same wall-clock time — close enough to
        // "yesterday afternoon" without making the wizard ask twice.
        return now.subtract(const Duration(days: 1));
      case JournalWhen.custom:
        return _customOccurredAt ?? now;
    }
  }

  Future<void> _pickCustomDateTime() async {
    final DateTime now = DateTime.now();
    final DateTime initial = _customOccurredAt ?? now;
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now,
    );
    if (!mounted || date == null) return;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted || time == null) return;
    setState(() {
      _whenPreset = JournalWhen.custom;
      _customOccurredAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  bool get _canAdvance {
    switch (_step) {
      case 0:
        return _whenPreset != null &&
            (_whenPreset != JournalWhen.custom || _customOccurredAt != null);
      case 1:
        return _situationController.text.trim().isNotEmpty;
      case 2:
        return _attemptsController.text.trim().isNotEmpty;
    }
    return false;
  }

  void _onNext() {
    if (_step < JournalWizardScreen.totalSteps - 1) {
      setState(() => _step += 1);
    }
  }

  void _onBack() {
    if (_step > 0) {
      setState(() => _step -= 1);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    final StorageProvider storage = ref.read(storageProvider);
    final DateTime now = DateTime.now();
    final JournalEntry entry = JournalEntry.wizard(
      id: 'journal-${now.millisecondsSinceEpoch}-'
          '${math.Random().nextInt(1 << 32)}',
      createdAt: now,
      occurredAt: _resolveOccurredAt(),
      situationText: _situationController.text.trim(),
      attemptsText: _attemptsController.text.trim(),
    );
    try {
      await storage.insertJournalEntry(entry);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Entry saved to your journal.')),
      );
      // Pop back to wherever the wizard was opened from — home, chat,
      // or the journal tab itself.
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        context.goNamed('home');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save — try again."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Log a moment'),
        leading: IconButton(
          key: JournalWizardScreen.backButtonKey,
          icon: const Icon(Icons.arrow_back),
          onPressed: _onBack,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _ProgressDots(
                key: JournalWizardScreen.progressKey,
                step: _step,
                total: JournalWizardScreen.totalSteps,
              ),
              const SizedBox(height: 20),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _stepContent(textTheme),
                ),
              ),
              Row(
                children: <Widget>[
                  if (_step == JournalWizardScreen.totalSteps - 1)
                    Expanded(
                      child: ElevatedButton(
                        key: JournalWizardScreen.submitButtonKey,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: careblazersColors.cta,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed:
                            (_canAdvance && !_submitting) ? _submit : null,
                        child: Text(
                          _submitting ? 'Saving…' : 'Save entry',
                          style: textTheme.labelLarge,
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ElevatedButton(
                        key: JournalWizardScreen.nextButtonKey,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: careblazersColors.cta,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: _canAdvance ? _onNext : null,
                        child: Text('Next', style: textTheme.labelLarge),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepContent(TextTheme textTheme) {
    switch (_step) {
      case 0:
        return _whenStep(textTheme);
      case 1:
        return _situationStep(textTheme);
      case 2:
        return _attemptsStep(textTheme);
    }
    return const SizedBox.shrink();
  }

  Widget _whenStep(TextTheme textTheme) {
    return Column(
      key: const ValueKey<int>(0),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('When did it happen?', style: textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'A close-enough answer is fine — the journal is for you.',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.text.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 20),
        _PresetTile(
          tileKey: JournalWizardScreen.whenPresetJustNowKey,
          label: JournalWhen.justNow.label,
          selected: _whenPreset == JournalWhen.justNow,
          onTap: () => setState(() => _whenPreset = JournalWhen.justNow),
        ),
        const SizedBox(height: 10),
        _PresetTile(
          tileKey: JournalWizardScreen.whenPresetEarlierTodayKey,
          label: JournalWhen.earlierToday.label,
          selected: _whenPreset == JournalWhen.earlierToday,
          onTap: () => setState(() => _whenPreset = JournalWhen.earlierToday),
        ),
        const SizedBox(height: 10),
        _PresetTile(
          tileKey: JournalWizardScreen.whenPresetYesterdayKey,
          label: JournalWhen.yesterday.label,
          selected: _whenPreset == JournalWhen.yesterday,
          onTap: () => setState(() => _whenPreset = JournalWhen.yesterday),
        ),
        const SizedBox(height: 10),
        _PresetTile(
          tileKey: JournalWizardScreen.whenPresetCustomKey,
          label: _customOccurredAt == null
              ? JournalWhen.custom.label
              : _formatCustomTime(_customOccurredAt!),
          selected: _whenPreset == JournalWhen.custom,
          onTap: _pickCustomDateTime,
        ),
      ],
    );
  }

  Widget _situationStep(TextTheme textTheme) {
    return Column(
      key: const ValueKey<int>(1),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('What was happening?', style: textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'A few sentences in your own words. The voice you would use '
          'telling a friend about it.',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.text.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          key: JournalWizardScreen.situationFieldKey,
          controller: _situationController,
          minLines: 5,
          maxLines: 10,
          maxLength: 2000,
          decoration: const InputDecoration(
            hintText: 'She kept asking to call her mother…',
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _attemptsStep(TextTheme textTheme) {
    return Column(
      key: const ValueKey<int>(2),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('What did you try?', style: textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Whatever you reached for — words, redirects, walking away to '
          'breathe. "Nothing yet" is a real answer too.',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.text.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          key: JournalWizardScreen.attemptsFieldKey,
          controller: _attemptsController,
          minLines: 5,
          maxLines: 10,
          maxLength: 2000,
          decoration: const InputDecoration(
            hintText: 'I told her Mom was at the store and we walked '
                'to the kitchen for tea.',
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  static String _formatCustomTime(DateTime dt) {
    final String hh = dt.hour.toString().padLeft(2, '0');
    final String mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.month}/${dt.day} at $hh:$mm';
  }
}

class _ProgressDots extends StatelessWidget {
  const _ProgressDots({super.key, required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List<Widget>.generate(total, (int i) {
        final bool active = i <= step;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: active
                  ? careblazersColors.cta
                  : careblazersColors.text.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.tileKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key tileKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Material(
      key: tileKey,
      color: selected
          ? careblazersColors.primary
          : careblazersColors.surfaceWarm,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Row(
            children: <Widget>[
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected
                    ? Colors.white
                    : careblazersColors.text.withValues(alpha: 0.45),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: textTheme.bodyLarge?.copyWith(
                    color: selected
                        ? Colors.white
                        : careblazersColors.text,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
