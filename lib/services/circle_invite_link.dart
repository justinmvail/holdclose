import '../screens/team/circle_qr_screen.dart' show circleQrScheme;

/// Deep-link host for a care-circle invite: `careblazers://join/<token>`.
/// This is the LINK channel parallel to the QR's `careblazers:circle:<token>`
/// payload — both carry the same single-use invite token redeemed by
/// `POST /circles/join` (see [ForumApiClient.joinCircle]).
const String circleJoinHost = 'join';

/// Build the shareable HTTPS invite link for [token] given the backend
/// [origin] (the `FORUM_API_URL` WITHOUT its `/api/v1` suffix). The Worker
/// serves a public landing page at `GET /join/:token` that bounces into the
/// app via the `careblazers://join/<token>` deep link.
String circleInviteLink({required String origin, required String token}) {
  final String trimmed =
      origin.endsWith('/') ? origin.substring(0, origin.length - 1) : origin;
  return '$trimmed/join/$token';
}

/// Extract a care-circle invite token from an incoming deep-link URI, or
/// null when the URI isn't one of ours / carries no token.
///
/// Accepts BOTH channels for symmetry:
///   * `careblazers://join/<token>`   (host `join`, first path segment)
///   * `careblazers:circle:<token>`   (the QR payload scheme)
String? parseCircleInviteToken(Uri uri) {
  // QR-style opaque scheme: `careblazers:circle:<token>`. Uri parses this as
  // scheme=careblazers, path=`circle:<token>` (no authority), so match on the
  // raw string the same way the scanner does.
  final String raw = uri.toString();
  if (raw.startsWith(circleQrScheme)) {
    final String token = raw.substring(circleQrScheme.length).trim();
    return token.isEmpty ? null : token;
  }
  // Link-style: `careblazers://join/<token>`.
  if (uri.scheme == 'careblazers' && uri.host == circleJoinHost) {
    final List<String> segments =
        uri.pathSegments.where((String s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final String token = segments.first.trim();
    return token.isEmpty ? null : token;
  }
  return null;
}

/// Same as [parseCircleInviteToken] but tolerant of a raw string that may
/// fail [Uri.parse] (returns null rather than throwing).
String? parseCircleInviteTokenFromString(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null) return null;
  return parseCircleInviteToken(uri);
}
