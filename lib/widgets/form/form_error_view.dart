import 'package:flutter/material.dart';

import '../../theme.dart';

/// Shared load-failure body for a data-backed screen — the `error:` arm
/// of an `AsyncValue.when`.
///
/// Renders [message] centered on the canvas in branded body text. Each
/// caller composes its own surface-specific copy — typically
/// `"We couldn't load X.\n$error"` — so the rendered text stays
/// byte-identical to the per-screen `_ErrorView` copies this replaced.
class FormErrorView extends StatelessWidget {
  const FormErrorView({super.key, required this.message});

  /// The full text to render — headline + raw error detail included.
  final String message;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          message,
          style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
