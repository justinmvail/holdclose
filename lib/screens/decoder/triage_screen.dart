import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/behavior.dart';
import '../../models/triage.dart';
import '../../providers/triage_provider.dart';
import '../../theme.dart';
import 'behavior_picker_screen.dart';
import 'decoder_result_screen.dart';

/// Triage (BUILD_SPEC.md §5.3) — three sequential single-select
/// questions whose answers constrain the decoder LLM call. Lives
/// between the behavior picker (§5.2) and the result screen (§5.4).
///
/// State strategy:
///   - The current question index (0/1/2) is local widget state so
///     Back between questions is a pure setState, not a route
///     push/pop.
///   - The caregiver's actual answers live in [triageProvider] so
///     they survive Back navigation between questions AND the push
///     to `/decoder/result` (going Back from result lands here with
///     Q3's selection still painted).
class TriageScreen extends ConsumerStatefulWidget {
  const TriageScreen({super.key, required this.args});

  /// Behavior + free-text flag handed forward from the picker
  /// (BUILD_SPEC.md §5.2 → §5.3) via `GoRouterState.extra`.
  final TriageArgs args;

  /// Number of triage questions per §5.3.
  static const int totalQuestions = 3;

  /// Stable widget keys for tests. Tests address by key (not by
  /// visible copy) so a wording edit doesn't ripple into a test
  /// rewrite.
  static const Key nextButtonKey = Key('triage-next-button');
  static const Key backButtonKey = Key('triage-back-button');
  static const Key progressKey = Key('triage-progress');
  static const Key behaviorChipKey = Key('triage-behavior-chip');

  static Key questionKey(int q) => Key('triage-question-$q');
  static Key optionKey(int q, int i) => Key('triage-option-$q-$i');

  @override
  ConsumerState<TriageScreen> createState() => _TriageScreenState();
}

class _TriageScreenState extends ConsumerState<TriageScreen> {
  /// 0-based question index. 0 = Q1, 1 = Q2, 2 = Q3.
  int _questionIndex = 0;

  /// Chip text in the AppBar. Free-text path renders a generic label
  /// since the per-caregiver text input is a later task; the canonical
  /// path renders the picked behavior's label verbatim.
  String get _behaviorLabel =>
      widget.args.behavior?.label ?? 'Something else';

  /// Behavior handed forward into [DecoderResultArgsExtra]. Free-text
  /// rides on a synthesized non-canonical [Behavior] so the result
  /// route doesn't have to special-case a missing one — the LLM call
  /// surface ([ClaudeCLIProvider.buildUserMessage]) already treats any
  /// non-canonical id as the free-text path.
  Behavior get _behavior {
    return widget.args.behavior ??
        const Behavior(
          id: 'freetext',
          label: 'Something else',
          glyph: '✍',
        );
  }

  void _goBack() {
    if (_questionIndex == 0) {
      // First question — Back exits the triage flow entirely. Use
      // pop() rather than go() so we land on whatever pushed us
      // (typically the behavior picker).
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _questionIndex -= 1;
    });
  }

  void _goNext(TriageAnswers triage) {
    if (_questionIndex < TriageScreen.totalQuestions - 1) {
      setState(() {
        _questionIndex += 1;
      });
      return;
    }
    // Q3 → Next: hand off to the result screen. We deliberately do
    // NOT await the LLM call here — the result screen owns the
    // streaming + journal-log orchestration so we can navigate
    // immediately and let it render its skeleton while bytes arrive.
    context.push(
      '/decoder/result',
      extra: DecoderResultArgsExtra(
        behavior: _behavior,
        triage: triage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TriageAnswers answers = ref.watch(triageProvider);
    final TextTheme textTheme = Theme.of(context).textTheme;

    final Object? currentSelection = _selectionFor(_questionIndex, answers);
    final bool nextEnabled = currentSelection != null;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        leading: Semantics(
          button: true,
          label: _questionIndex == 0
              ? 'Back. Leave triage.'
              : 'Back to previous question.',
          child: BackButton(
            key: TriageScreen.backButtonKey,
            onPressed: _goBack,
            color: careblazersColors.primary,
          ),
        ),
        title: _BehaviorChip(label: _behaviorLabel),
        centerTitle: true,
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Text(
                '${_questionIndex + 1} of ${TriageScreen.totalQuestions}',
                key: TriageScreen.progressKey,
                style: textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.primarySoft,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                _promptFor(_questionIndex),
                key: TriageScreen.questionKey(_questionIndex),
                style: textTheme.headlineMedium?.copyWith(
                  color: careblazersColors.primary,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: _OptionList(
                  questionIndex: _questionIndex,
                  selection: currentSelection,
                  onSelect: (Object value) =>
                      _applySelection(_questionIndex, value),
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                button: true,
                enabled: nextEnabled,
                label: _questionIndex == TriageScreen.totalQuestions - 1
                    ? 'Next. Get the script.'
                    : 'Next question.',
                child: ElevatedButton(
                  key: TriageScreen.nextButtonKey,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: careblazersColors.cta,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        careblazersColors.cta.withValues(alpha: 0.35),
                    disabledForegroundColor:
                        Colors.white.withValues(alpha: 0.7),
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed: nextEnabled ? () => _goNext(answers) : null,
                  child: Text(
                    'Next →',
                    style: textTheme.labelLarge?.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _applySelection(int questionIndex, Object value) {
    final Triage notifier = ref.read(triageProvider.notifier);
    switch (questionIndex) {
      case 0:
        notifier.selectWhen(value as TriageWhen);
      case 1:
        notifier.selectWhatChanged(value as TriageWhatChanged);
      case 2:
        notifier.selectWhatTried(value as TriageWhatTried);
    }
  }

  Object? _selectionFor(int questionIndex, TriageAnswers a) {
    switch (questionIndex) {
      case 0:
        return a.when;
      case 1:
        return a.whatChanged;
      case 2:
        return a.whatTried;
      default:
        return null;
    }
  }

  String _promptFor(int questionIndex) {
    switch (questionIndex) {
      case 0:
        return 'When does it tend to happen?';
      case 1:
        return 'What changed recently?';
      case 2:
        return 'What have you already tried?';
      default:
        return '';
    }
  }
}

// ---------------------------------------------------------------------------
// Options (BUILD_SPEC.md §5.3)
// ---------------------------------------------------------------------------

/// Labels paired with their typed enum value, in the order
/// BUILD_SPEC.md §5.3 lists. Tests assert this order indirectly via
/// the `optionKey(q, i)` indices.
const List<(TriageWhen, String)> _q1Options = <(TriageWhen, String)>[
  (TriageWhen.morning, 'Morning'),
  (TriageWhen.afternoon, 'Afternoon'),
  (TriageWhen.lateAfternoonEvening, 'Late afternoon / evening'),
  (TriageWhen.night, 'Night'),
  (TriageWhen.justStarted, "Just started — don't know yet"),
];

const List<(TriageWhatChanged, String)> _q2Options =
    <(TriageWhatChanged, String)>[
  (TriageWhatChanged.nothing, 'Nothing'),
  (TriageWhatChanged.schedule, 'Schedule'),
  (TriageWhatChanged.medication, 'Medication'),
  (TriageWhatChanged.health, 'Health (UTI, illness)'),
  (TriageWhatChanged.environment, 'Environment (new place, visitors)'),
  (TriageWhatChanged.dontKnow, "Don't know"),
];

const List<(TriageWhatTried, String)> _q3Options =
    <(TriageWhatTried, String)>[
  (TriageWhatTried.talked, 'Talked to them about it'),
  (TriageWhatTried.triedToExplain, 'Tried to explain'),
  (TriageWhatTried.walkedAway, 'Walked away'),
  (TriageWhatTried.distracted, 'Distracted them'),
  (TriageWhatTried.nothingYet, 'Nothing yet — just started'),
];

class _OptionList extends StatelessWidget {
  const _OptionList({
    required this.questionIndex,
    required this.selection,
    required this.onSelect,
  });

  final int questionIndex;
  final Object? selection;
  final void Function(Object value) onSelect;

  List<(Object, String)> get _options {
    switch (questionIndex) {
      case 0:
        return _q1Options;
      case 1:
        return _q2Options;
      case 2:
        return _q3Options;
      default:
        return const <(Object, String)>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<(Object, String)> options = _options;
    return ListView.separated(
      itemCount: options.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (BuildContext context, int i) {
        final (Object value, String label) = options[i];
        final bool selected = value == selection;
        return _PillButton(
          key: TriageScreen.optionKey(questionIndex, i),
          label: label,
          selected: selected,
          onTap: () => onSelect(value),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Visuals
// ---------------------------------------------------------------------------

class _PillButton extends StatelessWidget {
  const _PillButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color background = selected
        ? careblazersColors.primary
        : careblazersColors.surfaceWarm;
    final Color foreground =
        selected ? Colors.white : careblazersColors.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(32),
        elevation: selected ? 0 : 1,
        shadowColor: Colors.black.withValues(alpha: 0.1),
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(32),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 18,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style:
                        textTheme.labelLarge?.copyWith(color: foreground),
                  ),
                ),
                if (selected)
                  Icon(Icons.check, color: foreground, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BehaviorChip extends StatelessWidget {
  const _BehaviorChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: TriageScreen.behaviorChipKey,
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        label,
        style: textTheme.titleLarge?.copyWith(
          color: careblazersColors.primary,
          fontSize: 16,
        ),
      ),
    );
  }
}
