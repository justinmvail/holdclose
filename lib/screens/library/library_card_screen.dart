import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/behavior.dart';
import '../../models/settings.dart';
import '../../providers/share_provider.dart';
import '../../providers/tts_provider.dart';
import '../../seed/library_cards.dart';
import '../../theme.dart';
import '../decoder/behavior_picker_screen.dart';

/// Library card detail (BUILD_SPEC.md §5.8).
///
/// Reads the card by [cardId] from [libraryCards]. Layout:
///   - AppBar: card title + share action (hands the body to
///     [Sharer.share] via the [sharerProvider] seam so tests can record
///     without firing the platform sheet).
///   - PLAY button — reads [LibraryCard.body] aloud via
///     [TTSProvider.speak]. Mirrors the decoder result screen's "Read
///     all aloud" UX (BUILD_SPEC.md §5.4) since there's no recorded
///     Natali audio in v1; OS TTS reads the placeholder body.
///   - Body in `bodyLarge` with generous line height.
///   - Related-behavior chips at the bottom that deep-link into
///     `/decoder/triage` with [TriageArgs.forBehavior] pre-set — the
///     caregiver skips the picker (BUILD_SPEC.md §5.8 "chips push
///     `/decoder/triage` with the behavior set, skipping the picker").
///
/// Pushed onto the root navigator (router.dart), so the AppBar
/// auto-renders a back arrow over the tab bar.
class LibraryCardScreen extends ConsumerWidget {
  const LibraryCardScreen({super.key, required this.cardId});

  final String cardId;

  static const Key playButtonKey = Key('library-card-play');
  static const Key shareButtonKey = Key('library-card-share');
  static const Key bodyTextKey = Key('library-card-body');
  static const Key titleTextKey = Key('library-card-title');
  static const Key relatedSectionKey = Key('library-card-related');
  static const Key notFoundKey = Key('library-card-not-found');

  /// Stable per-chip key keyed by the related behavior id. Tests tap
  /// by id rather than by visible label so a copy edit doesn't break
  /// the test.
  static Key relatedChipKey(String behaviorId) =>
      Key('library-card-related-chip-$behaviorId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LibraryCard? card = libraryCardById(cardId);
    if (card == null) {
      return _notFoundScaffold(context);
    }

    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: Text(
          card.title,
          key: titleTextKey,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            key: shareButtonKey,
            icon: const Icon(Icons.ios_share),
            tooltip: 'Share this card',
            onPressed: () => _share(ref, card),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PlayButton(
                onPressed: () => _playBody(ref, card),
              ),
              const SizedBox(height: 20),
              Text(
                card.body,
                key: bodyTextKey,
                // bodyLarge is 20pt Lato per BUILD_SPEC.md §3.2 — the
                // 20pt default body the audience (60+) reads with.
                // 1.5× line height keeps the longer-form primer
                // readable without forcing the caregiver to track lines.
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              if (card.relatedBehaviorIds.isNotEmpty)
                _RelatedBehaviorChips(
                  behaviorIds: card.relatedBehaviorIds,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _playBody(WidgetRef ref, LibraryCard card) async {
    final TTSProvider tts = ref.read(ttsProvider);
    final AppSettings settings = ref.read(ttsSettingsProvider);
    await tts.speak(
      card.body,
      voiceId: settings.voiceId ?? '',
      speed: settings.speed,
    );
  }

  Future<void> _share(WidgetRef ref, LibraryCard card) async {
    final Sharer sharer = ref.read(sharerProvider);
    // Lead the shared text with the title + hook so the caregiver's
    // recipient gets the orienting context, not just the body
    // paragraph in isolation. The subject is title-only so Mail
    // populates a clean subject line.
    final String text = '${card.title}\n\n${card.hook}\n\n${card.body}';
    await sharer.share(text, subject: card.title);
  }

  Widget _notFoundScaffold(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(title: const Text('Library card')),
      body: SafeArea(
        child: Center(
          key: notFoundKey,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              "We couldn't find that card.",
              textAlign: TextAlign.center,
              style: textTheme.headlineMedium?.copyWith(
                color: careblazersColors.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// PLAY button at the top of the body (BUILD_SPEC.md §5.8). Sized like
/// a full-width CTA so a thumb-tap from a caregiver glancing one-handed
/// at the phone reliably hits it. Uses the brand CTA color since this
/// is the screen's primary action when the caregiver wants to listen
/// rather than read.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Read this card aloud.',
      child: ElevatedButton.icon(
        key: LibraryCardScreen.playButtonKey,
        onPressed: onPressed,
        icon: const Icon(Icons.play_arrow, color: Colors.white),
        label: Text(
          'Read aloud',
          style: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: careblazersColors.cta,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
        ),
      ),
    );
  }
}

/// Strip of chips at the bottom of the card body — one per related
/// canonical behavior (BUILD_SPEC.md §5.8). Tapping a chip pushes
/// `/decoder/triage` with [TriageArgs.forBehavior] so the triage screen
/// renders with the behavior pre-selected and the caregiver skips the
/// picker.
class _RelatedBehaviorChips extends StatelessWidget {
  const _RelatedBehaviorChips({required this.behaviorIds});

  final List<String> behaviorIds;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    // Filter to behaviors that actually exist in [Behavior.canonical] —
    // a stale seed id shouldn't crash the detail screen; it just drops
    // out of the chip strip.
    final List<Behavior> resolved = <Behavior>[
      for (final String id in behaviorIds)
        if (Behavior.byId(id) != null) Behavior.byId(id)!,
    ];

    if (resolved.isEmpty) return const SizedBox.shrink();

    return Column(
      key: LibraryCardScreen.relatedSectionKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Related decoder behaviors',
          style: textTheme.titleLarge?.copyWith(
            color: careblazersColors.primary,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final Behavior b in resolved)
              _BehaviorChip(behavior: b),
          ],
        ),
      ],
    );
  }
}

class _BehaviorChip extends StatelessWidget {
  const _BehaviorChip({required this.behavior});

  final Behavior behavior;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label:
          '${behavior.label}. Double-tap to start the decoder with this behavior.',
      child: ActionChip(
        key: LibraryCardScreen.relatedChipKey(behavior.id),
        backgroundColor: careblazersColors.surfaceWarm,
        side: BorderSide(
          color: careblazersColors.primarySoft.withValues(alpha: 0.3),
        ),
        label: Text(
          '${behavior.glyph}  ${behavior.label}',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        onPressed: () => context.push(
          '/decoder/triage',
          extra: TriageArgs.forBehavior(behavior),
        ),
      ),
    );
  }
}
