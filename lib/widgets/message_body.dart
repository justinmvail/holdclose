import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/chat_actions.dart' show journalCitationPrefix;
import '../theme.dart';

/// Renders an assistant message body — plain prose plus inline
/// "action result" chips the chat coach stamped via the
/// `[action:log_journal …]` harness (TASKS.md home-tab refactor).
///
/// The model never embeds chip markers in its prose anymore (the
/// CITATIONS path that backed library cards is retired); the chat
/// service strips the action tags before this widget sees the body,
/// then passes the resulting citation list (`journal:<entry_id>`
/// ids) via [citations]. The widget appends a chip per id so the
/// caregiver still has a tap target into the entry the coach just
/// logged.
class MessageBody extends StatelessWidget {
  const MessageBody({
    super.key,
    required this.body,
    this.citations = const <String>[],
    this.style,
    this.textAlign,
    this.onCitationTap,
  });

  final String body;

  /// Per-action citations stamped onto the assistant message — v1 only
  /// emits `journal:<entry_id>` strings.
  final List<String> citations;

  final TextStyle? style;
  final TextAlign? textAlign;

  /// Optional tap override for tests so taps can be observed without
  /// pumping a real [GoRouter]. Production leaves null and the widget
  /// pushes through the ambient router.
  final void Function(String citation)? onCitationTap;

  static Key citationChipKey(String citation) =>
      Key('message-body-citation-$citation');

  @override
  Widget build(BuildContext context) {
    final TextStyle baseStyle = style ?? DefaultTextStyle.of(context).style;
    if (citations.isEmpty) {
      return Text(body, style: baseStyle, textAlign: textAlign);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(body, style: baseStyle, textAlign: textAlign),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final String c in citations)
              _CitationChip(
                citation: c,
                onTap: () {
                  if (onCitationTap != null) {
                    onCitationTap!(c);
                    return;
                  }
                  if (c.startsWith(journalCitationPrefix)) {
                    final String id =
                        c.substring(journalCitationPrefix.length);
                    GoRouter.of(context).push('/journal/$id');
                  }
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.citation, required this.onTap});

  final String citation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(14);
    final (String label, IconData icon) = _resolveDisplay(citation);
    return Material(
      key: MessageBody.citationChipKey(citation),
      color: context.cb.cta,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 14, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static (String, IconData) _resolveDisplay(String citation) {
    if (citation.startsWith(journalCitationPrefix)) {
      return ('Journal entry logged', Icons.bookmark_added_outlined);
    }
    return (citation, Icons.bolt_outlined);
  }
}
