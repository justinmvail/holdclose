import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/home_clock_provider.dart';
import '../theme.dart';
import '../widgets/home/add_action_sheet.dart';
import '../widgets/home/catch_me_up_card.dart';
import '../widgets/home/community_recap_card.dart';
import '../widgets/home/schedule_card.dart';
import '../widgets/path_header.dart';

/// Home tab root — the "Today" dashboard (BUILD_SPEC.md §4 Home IA,
/// Phase 14.7+).
///
/// AppBar-less. The body is a scrolling [ListView] (16px padding) whose
/// first row carries the time-of-day greeting on the left and a profile
/// affordance on the right that pushes Settings. The dashboard cards
/// (Phases 14.8–14.12) are children of this scroll view; the quick-action
/// FAB (Phase 14.13) sits in the scaffold's `floatingActionButton` slot.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const Key dashboardListKey = Key('home-dashboard-list');
  static const Key greetingKey = Key('home-greeting');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read the wall clock through the override-able provider so tests
    // pin the hour. Not watched on a timer — Home rebuilds often enough
    // (tab switches, resume) that a build-time read stays fresh.
    final DateTime now = ref.watch(homeClockProvider)();
    final AuthProvider auth = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: context.hc.background,
      // The labeled quick-add affordance for the app's most frequent
      // actions (log a dose, add an appointment, a journal entry, a quick
      // note). Bottom-right `endFloat` keeps it clear of the shell's
      // center-mic tab button (which sits in the middle slot of the bar
      // on the OUTER scaffold, below this branch body) so the two never
      // collide. The mic is voice-first; this is the non-voice path.
      floatingActionButton: const AddActionFab(),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // The signed-in caregiver's name drives the greeting. We
            // read it off the same auth stream Settings → Account uses
            // rather than caching a synchronous copy — the stream
            // replays the current state on subscribe, so there's no
            // first-frame flash. The greeting becomes the [PathHeader]
            // title so Home's heading shares the same visual language
            // as the other four tab landings; the profile affordance
            // lives in the [PathHeader.trailing] slot.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: KeyedSubtree(
                key: HomeScreen.greetingKey,
                child: StreamBuilder<AuthState>(
                  stream: auth.watchAuthState(),
                  builder: (BuildContext context,
                      AsyncSnapshot<AuthState> snapshot) {
                    final String name = switch (snapshot.data) {
                      AuthStateSignedIn(:final User user) =>
                        firstNameOf(user.name),
                      _ => '',
                    };
                    return PathHeader(
                      breadcrumbs: const <PathHeaderCrumb>[
                        PathHeaderCrumb(label: 'Home'),
                      ],
                      title: greetingLine(now.hour, name),
                      backLabel: 'Back to Home',
                      leadingIcon: Icons.home_outlined,
                      // Profile/settings now lives in PathHeader's standard
                      // top-right cluster (on every screen), so Home no
                      // longer supplies its own.
                    );
                  },
                ),
              ),
            ),
            Expanded(
              child: ListView(
                key: dashboardListKey,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                children: const <Widget>[
                  // Schedule: Today + Tomorrow, drawn from the unified
                  // patient timeline (appointments, doses, health-log
                  // entries, journal entries, care-plan routines).
                  // Replaces the single-row Next Appointment card so the
                  // caregiver sees the days ahead, not just the next item.
                  ScheduleCard(),
                  SizedBox(height: 16),
                  // Catch me up (Phase 14.12): an optional streamed
                  // recap of the last 24h, cached for 30 min. It owns
                  // its own bottom gap and collapses to nothing on a
                  // quiet day, so there's no spacer around it here —
                  // a hidden card leaves the dashboard pixel-identical
                  // to having no card at all.
                  CatchMeUpCard(),
                  // From the Community (alpha fb_1780962188695173): a
                  // compact recap of a few recent community posts at the
                  // very bottom of the dashboard, tapping through to the
                  // Community tab. The card above owns its own 16px bottom
                  // gap, so this sits directly beneath it; the recap card
                  // collapses to nothing when the community backend isn't
                  // configured or has no posts, leaving the dashboard
                  // pixel-identical to having no card at all.
                  CommunityRecapCard(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Good morning, Sarah" / "Good evening, there" — the personalized
/// greeting line that becomes the Home tab's [PathHeader] title. Falls
/// back to a warm second-person address ("there") when [name] is empty
/// so the line never trails a bare comma. Exposed so tests can assert
/// the wording without driving a widget tree.
String greetingLine(int hour, String name) {
  final String prefix = greetingForHour(hour);
  return name.isEmpty ? '$prefix, there' : '$prefix, $name';
}

/// Time-of-day greeting prefix (BUILD_SPEC.md Phase 14.7).
///
/// `morning` before noon, `afternoon` through 4:59pm, `evening` from
/// 5pm on. Pure so the hour boundaries are unit-testable without a
/// widget tree.
@visibleForTesting
String greetingForHour(int hour) {
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  return 'Good evening';
}

/// The first whitespace-delimited token of [fullName], used to address
/// the caregiver by first name in the greeting. Returns an empty string
/// for an empty/whitespace name.
@visibleForTesting
String firstNameOf(String fullName) {
  final String trimmed = fullName.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.split(RegExp(r'\s+')).first;
}
