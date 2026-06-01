import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'community_subnav_provider.g.dart';

/// A monotonic "you were just re-entered" signal for the Community tab's
/// in-tab Feed/Learn/Support sub-nav (Phase 14.36).
///
/// The active segment itself lives in `CommunityFeedScreen`'s local
/// widget state — that's deliberate, so pushing into a post detail and
/// popping back preserves the segment the caregiver was on (the screen
/// is never disposed under a root-navigator push). But selecting the
/// Community destination from the bottom bar must drop the caregiver
/// back on the Feed segment (the tab's landing, per
/// `docs/MENU_LAYOUT_SPEC.md`: "tapping the active tab returns to its
/// landing"). The two requirements pull in opposite directions, so the
/// reset is driven by an explicit signal rather than by tearing the
/// screen down.
///
/// [TabScaffold] calls [bump] whenever the Community destination is
/// selected — both a switch from another tab and an active-tab re-tap.
/// `CommunityFeedScreen` watches this counter and snaps its segment back
/// to Feed whenever the value changes.
///
/// A plain incrementing `int` (rather than a "set segment to N" command)
/// keeps the segment authority in the widget: the provider only ever
/// says "you were just re-entered", never "be on segment N". `keepAlive`
/// so the count survives the rebuilds a tab switch triggers.
@Riverpod(keepAlive: true)
class CommunityTabReentry extends _$CommunityTabReentry {
  @override
  int build() => 0;

  /// Fire the re-entry signal. Called from the bottom-bar tap handler
  /// when the Community destination is selected.
  void bump() => state = state + 1;
}
