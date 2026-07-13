import 'package:flutter/material.dart';

import '../theme.dart';

/// A forum member's face: their uploaded photo when they have one, otherwise
/// the initial-letter circle the app has always drawn.
///
/// Centralised because the fallback is the common case — most caregivers never
/// set a photo — and because every surface that shows an author (feed, post
/// detail, your own profile) must degrade the same way when an image is
/// missing, slow, or broken. A network image that fails MUST NOT leave a hole
/// or throw a red box in the middle of the community feed; [errorBuilder]
/// drops back to the initial, which is always renderable.
///
/// Widget tests + goldens pass a null [avatarUrl] (the fakes never mint one),
/// so no test ever reaches for the network.
class ForumAvatar extends StatelessWidget {
  const ForumAvatar({
    super.key,
    required this.displayName,
    this.avatarUrl,
    this.size = 36,
  });

  /// Drives the fallback initial. Empty → `?`.
  final String displayName;

  /// The photo to show, from the backend's media origin. Null/empty → initial.
  final String? avatarUrl;

  /// Diameter in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    final String? url = (avatarUrl?.isEmpty ?? true) ? null : avatarUrl;
    final Widget initial = _Initial(displayName: displayName, size: size);

    if (url == null) return initial;

    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // While the photo loads, hold the initial — the row must never jump.
        loadingBuilder: (
          BuildContext context,
          Widget child,
          ImageChunkEvent? progress,
        ) =>
            progress == null ? child : initial,
        // A dead URL, an offline phone, a corrupt object: fall back, never
        // fail. The feed keeps rendering.
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            initial,
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial({required this.displayName, required this.size});

  final String displayName;
  final double size;

  /// The circle size the initial's type scale was originally tuned against
  /// (the community feed's author row). The letter scales proportionally from
  /// there, so the feed renders byte-identically to before this widget was
  /// extracted while a larger avatar (the profile screen's 72pt) still gets a
  /// proportionate letter instead of a lost little glyph.
  static const double _baseSize = 36;

  @override
  Widget build(BuildContext context) {
    final TextStyle? base = Theme.of(context).textTheme.titleLarge;
    final String initial = displayName.isEmpty
        ? '?'
        : displayName.substring(0, 1).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.hc.primary,
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: base?.copyWith(
          color: context.hc.background,
          fontWeight: FontWeight.w700,
          fontSize: base.fontSize == null
              ? null
              : base.fontSize! * (size / _baseSize),
        ),
      ),
    );
  }
}
