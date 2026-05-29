import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/behavior.dart';
import '../../models/decoder_result.dart';
import '../../models/journal_entry.dart';
import '../../models/settings.dart';
import '../../models/triage.dart';
import '../../providers/decoder_result_provider.dart';
import '../../providers/link_launcher_provider.dart';
import '../../providers/storage_provider.dart';
import '../../providers/tts_provider.dart';
import '../../theme.dart';

/// Arguments handed from the triage screen (BUILD_SPEC.md §5.3) into the
/// decoder result screen (§5.4) via `GoRouterState.extra`. Carries the
/// caregiver's behavior pick + the three triage answers + the starting
/// attempt number (always 0 from the picker; >0 only when a deep-link or
/// future "redo from journal" flow re-enters the result).
@immutable
class DecoderResultArgsExtra {
  const DecoderResultArgsExtra({
    required this.behavior,
    required this.triage,
    this.initialAttempt = 0,
  });

  final Behavior behavior;
  final TriageAnswers triage;
  final int initialAttempt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DecoderResultArgsExtra &&
          other.behavior == behavior &&
          other.triage == triage &&
          other.initialAttempt == initialAttempt);

  @override
  int get hashCode => Object.hash(behavior, triage, initialAttempt);
}

/// The "Talk to Natali" outbound URL (BUILD_SPEC.md §5.4).
const String careCollectiveUrl =
    'https://careblazers.com/care-collective?utm_source=app&utm_medium=decoder';

/// The medical-advice disclaimer footer (BUILD_SPEC.md §13.1). Rendered
/// at the bottom of every result; the LLM also includes it verbatim in
/// the prompt's forbidden-output guard.
const String decoderFooterDisclaimer =
    'For caregiving communication only — not a substitute for medical '
    'advice. Call your doctor for medication or diagnosis questions.';

/// Decoder result screen — the wedge (BUILD_SPEC.md §5.4).
///
/// Watches `decoderResultProvider((behavior, triage, attempt))` and
/// renders streaming partials → final layout → three outcome buttons.
/// Mutates the local [_attempt] counter on "Try a different approach"
/// so the next watch spawns a fresh family instance with `attempt + 1`
/// — same LLM call surface, new journal row.
class DecoderResultScreen extends ConsumerStatefulWidget {
  const DecoderResultScreen({
    super.key,
    required this.behavior,
    required this.triage,
    this.initialAttempt = 0,
  });

  final Behavior behavior;
  final TriageAnswers triage;
  final int initialAttempt;

  static const Key playAllKey = Key('decoder-result-play-all');
  static const Key thatHelpedKey = Key('decoder-result-that-helped');
  static const Key differentApproachKey =
      Key('decoder-result-different-approach');
  static const Key talkToNataliKey = Key('decoder-result-talk-to-natali');
  static const Key retryKey = Key('decoder-result-retry');
  static const Key skeletonKey = Key('decoder-result-skeleton');
  static const Key streamingTextKey = Key('decoder-result-streaming-text');
  static const Key footerKey = Key('decoder-result-footer');

  static Key sayLinePlayKey(int index) =>
      Key('decoder-result-say-play-$index');
  static Key sayLineKey(int index) => Key('decoder-result-say-$index');
  static Key tweakLineKey(int index) =>
      Key('decoder-result-tweak-$index');
  static Key dontSayLineKey(int index) =>
      Key('decoder-result-dont-say-$index');

  @override
  ConsumerState<DecoderResultScreen> createState() =>
      _DecoderResultScreenState();
}

class _DecoderResultScreenState
    extends ConsumerState<DecoderResultScreen> {
  late int _attempt;

  @override
  void initState() {
    super.initState();
    _attempt = widget.initialAttempt;
  }

  DecoderResultArgs get _args => (
        behavior: widget.behavior,
        triage: widget.triage,
        attempt: _attempt,
      );

  @override
  Widget build(BuildContext context) {
    final AsyncValue<DecoderProgress> progress =
        ref.watch(decoderResultProvider(_args));

    final bool canPlayAll = progress.maybeWhen(
      data: (DecoderProgress p) => p.done && p.partial != null,
      orElse: () => false,
    );

    // Riverpod 3.x leaves a stream that errored before its first data
    // emission in `AsyncLoading(error: …)` rather than `AsyncError(…)` —
    // its retry policy keeps the loading flag on while the error rides
    // along as a side-channel. The decoder result screen treats either
    // shape the same: if an error is attached at all, show the retry
    // view instead of the skeleton.
    final Widget body;
    if (progress.hasError) {
      body = _errorView(progress.error!);
    } else if (progress.hasValue) {
      final DecoderProgress p = progress.requireValue;
      body = p.done ? _doneView(p) : _streamingView(p);
    } else {
      body = _loadingView();
    }

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Decoder'),
        actions: <Widget>[
          Semantics(
            button: true,
            enabled: canPlayAll,
            label: 'Read the full script aloud.',
            child: IconButton(
              key: DecoderResultScreen.playAllKey,
              icon: const Icon(Icons.volume_up_outlined),
              tooltip: 'Read all sections aloud',
              onPressed: canPlayAll
                  ? () => _playAll(progress.requireValue.partial!)
                  : null,
            ),
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }

  // ---- Section builders --------------------------------------------------

  Widget _loadingView() {
    return const _StreamingShell(
      child: _PulsingSkeleton(key: DecoderResultScreen.skeletonKey),
    );
  }

  Widget _streamingView(DecoderProgress p) {
    // Prefer the structured partial parse when it's available — even
    // partial-but-structured content reads cleaner than the raw JSON
    // braces. Fall back to the accumulated text when nothing has parsed
    // yet so the caregiver sees motion, not a frozen skeleton.
    final Widget body = p.partial != null
        ? _PartialContent(result: p.partial!)
        : Text(
            p.accumulatedJson,
            key: DecoderResultScreen.streamingTextKey,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.text,
                ),
          );
    return _StreamingShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _PulsingSkeleton(key: DecoderResultScreen.skeletonKey),
          const SizedBox(height: 16),
          body,
        ],
      ),
    );
  }

  Widget _doneView(DecoderProgress p) {
    final DecoderResult r = p.partial!;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            header: true,
            sortKey: const OrdinalSortKey(0),
            child: Text(
              'Dr. Natali says:',
              style: textTheme.headlineLarge?.copyWith(
                color: careblazersColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 12),
          Semantics(
            sortKey: const OrdinalSortKey(1),
            child: _SaySection(
              entries: r.say,
              onPlayLine: _playOne,
            ),
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 16),
          Semantics(
            sortKey: const OrdinalSortKey(2),
            child: _TweakSection(entries: r.tweak),
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 16),
          Semantics(
            sortKey: const OrdinalSortKey(3),
            child: _DontSaySection(entries: r.dontSay),
          ),
          const SizedBox(height: 24),
          Semantics(
            sortKey: const OrdinalSortKey(4),
            child: const _FooterDisclaimer(),
          ),
          const SizedBox(height: 24),
          _OutcomeButtons(
            onThatHelped: p.entry == null
                ? null
                : () => _markPositive(p.entry!),
            onDifferentApproach: _tryDifferentApproach,
            onTalkToNatali: _openCareCollective,
          ),
        ],
      ),
    );
  }

  Widget _errorView(Object error) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String message = error is DecoderResultException
        ? error.message
        : error.toString();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            "We couldn't reach the coach.",
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.text,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Semantics(
            button: true,
            label: 'Try again. Re-request the coach.',
            child: ElevatedButton(
              key: DecoderResultScreen.retryKey,
              style: ElevatedButton.styleFrom(
                backgroundColor: careblazersColors.cta,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: () =>
                  ref.invalidate(decoderResultProvider(_args)),
              child: Text(
                'Try again',
                style: textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Outcome handlers --------------------------------------------------

  Future<void> _markPositive(JournalEntry entry) async {
    final StorageProvider storage = ref.read(storageProvider);
    await storage.updateJournalEntry(
      entry.copyWith(outcome: JournalOutcome.positive),
    );
    if (!mounted) return;
    context.go('/');
  }

  void _tryDifferentApproach() {
    setState(() {
      _attempt += 1;
    });
  }

  Future<void> _openCareCollective() async {
    final LinkLauncher launcher = ref.read(linkLauncherProvider);
    await launcher.launch(Uri.parse(careCollectiveUrl));
  }

  // ---- TTS helpers -------------------------------------------------------

  Future<void> _playAll(DecoderResult r) async {
    final TTSProvider tts = ref.read(ttsProvider);
    final AppSettings settings = _resolveSettings();
    final String voiceId = settings.voiceId ?? '';

    for (int i = 0; i < r.say.length; i++) {
      await tts.speak(r.say[i], voiceId: voiceId, speed: settings.speed);
      // 400ms pause between utterances so back-to-back lines sound
      // intentional, not chattering (BUILD_SPEC.md §7.4).
      if (i < r.say.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    for (final String t in r.tweak) {
      await tts.speak(t, voiceId: voiceId, speed: settings.speed);
    }
  }

  Future<void> _playOne(String text) async {
    final TTSProvider tts = ref.read(ttsProvider);
    final AppSettings settings = _resolveSettings();
    await tts.speak(
      text,
      voiceId: settings.voiceId ?? '',
      speed: settings.speed,
    );
  }

  AppSettings _resolveSettings() => ref.read(ttsSettingsProvider);
}

// ---------------------------------------------------------------------------
// Streaming / loading subtree
// ---------------------------------------------------------------------------

/// Shared shell for the loading + streaming views — the "Dr. Natali says:"
/// header is the stable anchor; whatever progress widget is passed sits
/// underneath it. Pulled out so the header text isn't duplicated and so
/// the streaming → done transition only animates the body.
class _StreamingShell extends StatelessWidget {
  const _StreamingShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Dr. Natali says:',
            style: textTheme.headlineLarge?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// Pulsing skeleton (BUILD_SPEC.md §5.4 — "subtle pulsing skeleton" while
/// streaming). Three stacked rounded bars at the rough proportions a
/// finished script lands at, with a low-amplitude opacity loop so the
/// motion stays gentle on an exhausted caregiver's eyes.
class _PulsingSkeleton extends StatefulWidget {
  const _PulsingSkeleton({super.key});

  @override
  State<_PulsingSkeleton> createState() => _PulsingSkeletonState();
}

class _PulsingSkeletonState extends State<_PulsingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    // Defer the repeat() until didChangeDependencies — by then we can
    // read MediaQuery.disableAnimations and skip the infinite ticker
    // when reduce-motion is on. Without this, `pumpAndSettle` in tests
    // (which forces disableAnimations=true) would still wait on the
    // AnimationController forever.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduceMotion =
        MediaQuery.of(context).disableAnimations;
    if (reduceMotion) {
      _controller.stop();
      _controller.value = 1.0;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.of(context).disableAnimations;
    if (reduceMotion) {
      return _staticSkeleton(context);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        final double t = 0.5 + 0.3 * _controller.value;
        return Opacity(
          opacity: t,
          child: _staticSkeleton(context),
        );
      },
    );
  }

  Widget _staticSkeleton(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _bar(24, 220),
        const SizedBox(height: 12),
        _bar(24, 280),
        const SizedBox(height: 12),
        _bar(24, 200),
      ],
    );
  }

  Widget _bar(double height, double maxWidth) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: careblazersColors.surfaceWarm,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

/// Renders whatever the partial-parsed [DecoderResult] currently has. The
/// LLM streams left-to-right (`say` first, then `tweak`, then
/// `dont_say`), so even an early partial parse usually has at least one
/// `say` entry — enough to start the fade-in.
class _PartialContent extends StatelessWidget {
  const _PartialContent({required this.result});

  final DecoderResult result;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (result.say.isNotEmpty)
          for (int i = 0; i < result.say.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                result.say[i],
                key: DecoderResultScreen.sayLineKey(i),
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.primary,
                ),
              ),
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Done-state sections
// ---------------------------------------------------------------------------

class _SaySection extends StatelessWidget {
  const _SaySection({required this.entries, required this.onPlayLine});

  final List<String> entries;
  final Future<void> Function(String line) onPlayLine;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Try saying:',
          style: textTheme.titleLarge?.copyWith(
            color: careblazersColors.primary,
          ),
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < entries.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _SayLine(
              key: DecoderResultScreen.sayLineKey(i),
              index: i,
              line: entries[i],
              onPlay: () => onPlayLine(entries[i]),
            ),
          ),
      ],
    );
  }
}

class _SayLine extends StatelessWidget {
  const _SayLine({
    super.key,
    required this.index,
    required this.line,
    required this.onPlay,
  });

  final int index;
  final String line;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(8, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            button: true,
            label: 'Play this script line aloud.',
            child: IconButton(
              key: DecoderResultScreen.sayLinePlayKey(index),
              icon: const Icon(Icons.play_arrow),
              color: careblazersColors.cta,
              onPressed: onPlay,
              tooltip: 'Read this line aloud',
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '"$line"',
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TweakSection extends StatelessWidget {
  const _TweakSection({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Try this in the room:',
          style: textTheme.titleLarge?.copyWith(
            color: careblazersColors.primary,
          ),
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < entries.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '•  ',
                  style: textTheme.bodyLarge?.copyWith(
                    color: careblazersColors.primarySoft,
                  ),
                ),
                Expanded(
                  child: Text(
                    entries[i],
                    key: DecoderResultScreen.tweakLineKey(i),
                    style: textTheme.bodyLarge?.copyWith(
                      color: careblazersColors.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DontSaySection extends StatelessWidget {
  const _DontSaySection({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          "Don't say:",
          style: textTheme.titleLarge?.copyWith(
            color: careblazersColors.accentDeep,
          ),
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < entries.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '✗  ',
                  style: textTheme.bodyLarge?.copyWith(
                    color: careblazersColors.accentDeep,
                  ),
                ),
                Expanded(
                  child: Text(
                    entries[i],
                    key: DecoderResultScreen.dontSayLineKey(i),
                    style: textTheme.bodyLarge?.copyWith(
                      color: careblazersColors.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FooterDisclaimer extends StatelessWidget {
  const _FooterDisclaimer();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: DecoderResultScreen.footerKey,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        decoderFooterDisclaimer,
        style: textTheme.bodyMedium?.copyWith(
          color: careblazersColors.primarySoft,
          fontStyle: FontStyle.italic,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _OutcomeButtons extends StatelessWidget {
  const _OutcomeButtons({
    required this.onThatHelped,
    required this.onDifferentApproach,
    required this.onTalkToNatali,
  });

  final VoidCallback? onThatHelped;
  final VoidCallback onDifferentApproach;
  final VoidCallback onTalkToNatali;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          enabled: onThatHelped != null,
          label: 'That helped. Log this in the journal.',
          child: ElevatedButton(
            key: DecoderResultScreen.thatHelpedKey,
            style: ElevatedButton.styleFrom(
              backgroundColor: careblazersColors.cta,
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  careblazersColors.cta.withValues(alpha: 0.4),
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: onThatHelped,
            child: Text(
              '✓  That helped — log it',
              style: textTheme.labelLarge?.copyWith(color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          button: true,
          label: 'Try a different approach. Re-run the coach.',
          child: OutlinedButton(
            key: DecoderResultScreen.differentApproachKey,
            style: OutlinedButton.styleFrom(
              foregroundColor: careblazersColors.primary,
              side: BorderSide(color: careblazersColors.primary, width: 1.5),
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: onDifferentApproach,
            child: Text(
              '→  Try a different approach',
              style: textTheme.labelLarge?.copyWith(
                color: careblazersColors.primary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          button: true,
          label: 'Talk to Natali. Opens the Care Collective in your browser.',
          child: TextButton(
            key: DecoderResultScreen.talkToNataliKey,
            style: TextButton.styleFrom(
              foregroundColor: careblazersColors.link,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: onTalkToNatali,
            child: Text(
              '💬  I need to talk to Natali',
              style: textTheme.labelLarge?.copyWith(
                color: careblazersColors.link,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
