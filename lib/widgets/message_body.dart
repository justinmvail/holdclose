import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../seed/library_cards.dart';
import '../theme.dart';

/// Citation marker recognised inside an assistant message body
/// (TASKS.md Phase 11.3 + 11.5). Mirrors the private regex in
/// [ChatService.parseCitations] — the id charset matches the slugs in
/// [libraryCards]. Phase 11.5's chat-system-prompt update pins the
/// model to that closed set, but the renderer still tolerates an
/// unknown id by falling back to the raw marker text rather than
/// crashing the message.
final RegExp _citationMarker = RegExp(r'\[card:([a-zA-Z0-9_-]+)\]');

/// Renders an assistant message body with inline citation chips
/// (TASKS.md Phase 11.5, BUILD_SPEC.md §5 chat surface).
///
/// Each `[card:<id>]` marker the model emits is replaced with a chip
/// reading "Dr. Natali on <card title>" — salmon background, white
/// 14pt text — that pushes `/library/<id>` (the existing Phase 23
/// library-detail route) on tap. Surrounding prose flows around the
/// chip in the same [Text.rich] span so a sentence-ending citation
/// reads as one continuous line, wrapping at the chip boundary if the
/// title runs long.
///
/// [body] is the full assistant message body — markers included; the
/// widget extracts them. [style] is applied to the prose; the chip
/// uses its own brand-pinned style so the citation stays legible even
/// if a parent [TextStyle] downsizes the body copy. [onCitationTap]
/// is an optional override used by widget tests so taps can be
/// observed without spinning up a full [GoRouter]; production leaves
/// it null and the widget pushes through the ambient router.
class MessageBody extends StatelessWidget {
  const MessageBody({
    super.key,
    required this.body,
    this.style,
    this.textAlign,
    this.onCitationTap,
  });

  final String body;
  final TextStyle? style;
  final TextAlign? textAlign;
  final void Function(String cardId)? onCitationTap;

  /// Stable per-chip key so widget tests can tap a specific citation
  /// without depending on the visible label.
  static Key citationChipKey(String cardId) =>
      Key('message-body-citation-$cardId');

  @override
  Widget build(BuildContext context) {
    final TextStyle baseStyle = style ?? DefaultTextStyle.of(context).style;
    final List<InlineSpan> spans = <InlineSpan>[];

    int cursor = 0;
    for (final RegExpMatch match in _citationMarker.allMatches(body)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: body.substring(cursor, match.start)));
      }
      final String id = match.group(1)!;
      final LibraryCard? card = libraryCardById(id);
      if (card == null) {
        // Unknown id slips through — Phase 11.5's closed-set prompt
        // makes this rare, but a stale model output shouldn't crash
        // the bubble. Render the raw marker so the failure is visible
        // in dev without losing the surrounding sentence.
        spans.add(TextSpan(text: body.substring(match.start, match.end)));
      } else {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _CitationChip(
            card: card,
            onTap: () {
              if (onCitationTap != null) {
                onCitationTap!(card.id);
              } else {
                GoRouter.of(context).push('/library/${card.id}');
              }
            },
          ),
        ));
      }
      cursor = match.end;
    }
    if (cursor < body.length) {
      spans.add(TextSpan(text: body.substring(cursor)));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      textAlign: textAlign,
    );
  }
}

/// The salmon, white-on-cta inline chip itself. Sized to sit on a
/// single text line — the vertical padding is small so the chip's
/// height stays close to the surrounding cap height; horizontal
/// padding gives the label room to breathe. The chip's text is pinned
/// to 14pt Lato so a parent that scales body copy up (Settings →
/// large type) doesn't drag the chip into multi-line wrapping inside
/// the [WidgetSpan].
class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.card, required this.onTap});

  final LibraryCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(14);
    return Material(
      key: MessageBody.citationChipKey(card.id),
      color: careblazersColors.cta,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Text(
            'Dr. Natali on ${card.title}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
