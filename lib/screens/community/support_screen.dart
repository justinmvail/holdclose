import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/link_launcher_provider.dart';
import '../../seed/support_content.dart';
import '../../services/burnout_score.dart';
import '../../theme.dart';

/// The **Support** segment of the Community tab (BUILD_SPEC.md §5.16,
/// TASKS.md Phase 14.38) — caregiver wellbeing tools.
///
/// Rendered as the in-tab body when the Community sub-nav's Support
/// segment is active (it is NOT a routed screen of its own; the
/// `CommunityFeedScreen` owns the Scaffold + sub-nav). Three collapsible
/// cards, each expanding inline:
///
///   * **Burnout self-check** — the 10-item Likert form from
///     [burnoutQuestions], scored entirely on-device by [scoreBurnout]
///     (no LLM). After submit the result band + a coaching-style
///     response replace the form inline, with a "Retake" action.
///   * **Respite resources** — the national help lines in
///     [respiteResources] (each tappable to dial or open), plus a "search
///     local respite" link launching a web search ([respiteSearchUrl]).
///   * **Expert Q&A** — a read-only list of the curated [expertAnswers].
///
/// Per BUILD_SPEC.md §13.1 this is wellbeing/peer-support content, not
/// medical advice: the copy refers Holdclose to professional help and
/// never diagnoses or prescribes.
class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key});

  static const Key listKey = Key('support-list');

  /// Stable card ids, used to key each card's header + body.
  static const String selfCheckId = 'self-check';
  static const String respiteId = 'respite';
  static const String qandaId = 'qanda';

  static Key cardHeaderKey(String id) => Key('support-card-header-$id');
  static Key cardBodyKey(String id) => Key('support-card-body-$id');

  /// Self-check controls.
  static Key likertOptionKey(int question, int value) =>
      Key('support-likert-$question-$value');
  static const Key submitKey = Key('support-selfcheck-submit');
  static const Key resultKey = Key('support-selfcheck-result');
  static const Key retakeKey = Key('support-selfcheck-retake');

  /// Respite controls.
  static Key respiteResourceKey(String id) => Key('support-respite-$id');
  static const Key respiteSearchKey = Key('support-respite-search');

  /// Q&A entries.
  static Key expertAnswerKey(String id) => Key('support-qanda-$id');

  @override
  ConsumerState<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends ConsumerState<SupportScreen> {
  /// Selected rating (1–5) per question index. A question is unanswered
  /// when its index is absent.
  final Map<int, int> _answers = <int, int>{};

  /// The scored result, or null while the form is still being filled.
  BurnoutResult? _result;

  bool get _allAnswered => _answers.length == burnoutQuestions.length;

  void _selectAnswer(int question, int value) {
    setState(() => _answers[question] = value);
  }

  void _submit() {
    if (!_allAnswered) return;
    final List<int> ordered = <int>[
      for (int i = 0; i < burnoutQuestions.length; i++) _answers[i]!,
    ];
    setState(() => _result = scoreBurnout(ordered));
  }

  void _retake() {
    setState(() {
      _answers.clear();
      _result = null;
    });
  }

  Future<void> _launch(Uri uri) async {
    final LinkLauncher launcher = ref.read(linkLauncherProvider);
    await launcher.launch(uri);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: SupportScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        _CollapsibleCard(
          id: SupportScreen.selfCheckId,
          icon: Icons.spa_outlined,
          title: 'Burnout self-check',
          subtitle: 'A quick, private read on how you are holding up.',
          child: _SelfCheckBody(
            answers: _answers,
            result: _result,
            onSelect: _selectAnswer,
            onSubmit: _submit,
            onRetake: _retake,
            canSubmit: _allAnswered,
          ),
        ),
        const SizedBox(height: 12),
        _CollapsibleCard(
          id: SupportScreen.respiteId,
          icon: Icons.volunteer_activism_outlined,
          title: 'Respite resources',
          subtitle: 'Help lines and a way to find a break near you.',
          child: _RespiteBody(onLaunch: _launch),
        ),
        const SizedBox(height: 12),
        const _CollapsibleCard(
          id: SupportScreen.qandaId,
          icon: Icons.question_answer_outlined,
          title: 'Expert Q&A',
          subtitle: 'Practical, compassionate answers for caregivers.',
          child: _QandaBody(),
        ),
      ],
    );
  }
}

/// A surfaceWarm card whose body expands/collapses inline on a header tap.
/// Holds its own expansion state so each card opens independently. The
/// body subtree is removed while collapsed, so any state the body reads
/// (the self-check answers) must live in the parent — which it does
/// (`_SupportScreenState`).
class _CollapsibleCard extends StatefulWidget {
  const _CollapsibleCard({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  State<_CollapsibleCard> createState() => _CollapsibleCardState();
}

class _CollapsibleCardState extends State<_CollapsibleCard> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Material(
      color: context.hc.surfaceWarm,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            button: true,
            expanded: _expanded,
            label: '${widget.title}. ${widget.subtitle} '
                'Double-tap to ${_expanded ? 'collapse' : 'expand'}.',
            child: InkWell(
              key: SupportScreen.cardHeaderKey(widget.id),
              borderRadius: BorderRadius.circular(16),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
                child: Row(
                  children: <Widget>[
                    Icon(widget.icon, color: context.hc.primarySoft),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            widget.title,
                            style: textTheme.titleLarge?.copyWith(
                              color: context.hc.primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.subtitle,
                            style: textTheme.bodyMedium?.copyWith(
                              color: context.hc.primarySoft,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: context.hc.primarySoft,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              key: SupportScreen.cardBodyKey(widget.id),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

/// The self-check form, or the scored result once submitted.
class _SelfCheckBody extends StatelessWidget {
  const _SelfCheckBody({
    required this.answers,
    required this.result,
    required this.onSelect,
    required this.onSubmit,
    required this.onRetake,
    required this.canSubmit,
  });

  final Map<int, int> answers;
  final BurnoutResult? result;
  final void Function(int question, int value) onSelect;
  final VoidCallback onSubmit;
  final VoidCallback onRetake;
  final bool canSubmit;

  @override
  Widget build(BuildContext context) {
    final BurnoutResult? r = result;
    if (r != null) {
      return _SelfCheckResult(result: r, onRetake: onRetake);
    }

    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Rate each statement from 1 (${burnoutScaleLabels.first}) to '
          '5 (${burnoutScaleLabels.last}). Your answers stay on this phone.',
          style: textTheme.bodyMedium?.copyWith(color: context.hc.text),
        ),
        const SizedBox(height: 16),
        for (int i = 0; i < burnoutQuestions.length; i++) ...<Widget>[
          _LikertQuestion(
            index: i,
            prompt: burnoutQuestions[i],
            selected: answers[i],
            onSelect: (int value) => onSelect(i, value),
          ),
          const SizedBox(height: 16),
        ],
        Semantics(
          button: true,
          enabled: canSubmit,
          label: canSubmit
              ? 'See my result.'
              : 'Answer every statement to see your result.',
          child: ElevatedButton(
            key: SupportScreen.submitKey,
            onPressed: canSubmit ? onSubmit : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: context.hc.cta,
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  context.hc.cta.withValues(alpha: 0.4),
              disabledForegroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(
              'See my result',
              style: textTheme.labelLarge?.copyWith(color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

/// One question prompt over a row of five rating dots.
class _LikertQuestion extends StatelessWidget {
  const _LikertQuestion({
    required this.index,
    required this.prompt,
    required this.selected,
    required this.onSelect,
  });

  final int index;
  final String prompt;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${index + 1}. $prompt',
          style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            for (int value = minAnswer; value <= maxAnswer; value++) ...<Widget>[
              Expanded(
                child: _LikertDot(
                  question: index,
                  value: value,
                  selected: selected == value,
                  onTap: () => onSelect(value),
                ),
              ),
              if (value < maxAnswer) const SizedBox(width: 8),
            ],
          ],
        ),
      ],
    );
  }
}

class _LikertDot extends StatelessWidget {
  const _LikertDot({
    required this.question,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int question;
  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String label = burnoutScaleLabels[value - 1];
    return Semantics(
      button: true,
      selected: selected,
      label: '$value, $label.',
      child: Material(
        color: selected ? context.hc.primary : context.hc.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected
                ? context.hc.primary
                : context.hc.primarySoft.withValues(alpha: 0.4),
          ),
        ),
        child: InkWell(
          key: SupportScreen.likertOptionKey(question, value),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                '$value',
                style: textTheme.labelLarge?.copyWith(
                  color: selected
                      ? context.hc.background
                      : context.hc.primarySoft,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The scored self-check result: band headline, response copy, Retake.
class _SelfCheckResult extends StatelessWidget {
  const _SelfCheckResult({required this.result, required this.onRetake});

  final BurnoutResult result;
  final VoidCallback onRetake;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      key: SupportScreen.resultKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          result.headline,
          style: textTheme.headlineMedium?.copyWith(
            color: context.hc.primary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          result.message,
          style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
        ),
        const SizedBox(height: 16),
        Semantics(
          button: true,
          label: 'Retake the self-check.',
          child: OutlinedButton.icon(
            key: SupportScreen.retakeKey,
            onPressed: onRetake,
            icon: Icon(Icons.refresh, color: context.hc.primary),
            label: Text(
              'Retake',
              style: textTheme.labelLarge?.copyWith(
                color: context.hc.primary,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: context.hc.primarySoft),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}

/// The respite help-line list + the "search local respite" link.
class _RespiteBody extends StatelessWidget {
  const _RespiteBody({required this.onLaunch});

  final Future<void> Function(Uri uri) onLaunch;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final RespiteResource resource in respiteResources) ...<Widget>[
          _ResourceRow(resource: resource, onLaunch: onLaunch),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 4),
        Semantics(
          button: true,
          label: 'Search the web for respite care near you.',
          child: OutlinedButton.icon(
            key: SupportScreen.respiteSearchKey,
            onPressed: () => onLaunch(respiteSearchUrl()),
            icon: Icon(Icons.search, color: context.hc.link),
            label: Text(
              'Search local respite',
              style: textTheme.labelLarge?.copyWith(
                color: context.hc.link,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: context.hc.link),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({required this.resource, required this.onLaunch});

  final RespiteResource resource;
  final Future<void> Function(Uri uri) onLaunch;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Uri? phoneUri = resource.phoneUri;
    // Prefer dialing the line; fall back to the website for web-only
    // resources. At least one is always present in the seed.
    final Uri? target =
        phoneUri ?? (resource.url != null ? Uri.parse(resource.url!) : null);
    final String action = phoneUri != null
        ? 'Call ${resource.phone}.'
        : 'Open ${resource.name}.';

    return Semantics(
      button: target != null,
      label: '${resource.name}. ${resource.description} $action',
      child: Material(
        color: context.hc.background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: SupportScreen.respiteResourceKey(resource.id),
          borderRadius: BorderRadius.circular(12),
          onTap: target == null ? null : () => onLaunch(target),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  resource.name,
                  style: textTheme.bodyLarge?.copyWith(
                    color: context.hc.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  resource.description,
                  style: textTheme.bodyMedium?.copyWith(
                    color: context.hc.text,
                  ),
                ),
                if (resource.phone != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.call,
                        size: 18,
                        color: context.hc.link,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        resource.phone!,
                        style: textTheme.bodyMedium?.copyWith(
                          color: context.hc.link,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The read-only Expert Q&A list.
class _QandaBody extends StatelessWidget {
  const _QandaBody();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final ExpertAnswer entry in expertAnswers) ...<Widget>[
          Padding(
            key: SupportScreen.expertAnswerKey(entry.id),
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.question,
                  style: textTheme.bodyLarge?.copyWith(
                    color: context.hc.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  entry.answer,
                  style: textTheme.bodyMedium?.copyWith(
                    color: context.hc.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '— ${entry.attribution}',
                  style: textTheme.bodyMedium?.copyWith(
                    color: context.hc.primarySoft,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
