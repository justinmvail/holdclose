import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/home_clock_provider.dart';
import '../routing/router.dart';
import '../theme.dart';
import '../widgets/home/emergency_card_pin.dart';
import '../widgets/home/medications_today_card.dart';

/// Home tab root — the "Today" dashboard (BUILD_SPEC.md §4 Home IA,
/// Phase 14.7+).
///
/// AppBar-less. The body is a scrolling [ListView] (16px padding) whose
/// first row carries the time-of-day greeting on the left and a profile
/// affordance on the right that pushes Settings. The dashboard cards
/// (Phases 14.8–14.12) and the quick-action FAB (Phase 14.13) land as
/// further children of this same scroll view; this task lays only the
/// scroll view + greeting + profile.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const Key dashboardListKey = Key('home-dashboard-list');
  static const Key greetingKey = Key('home-greeting');
  static const Key profileButtonKey = Key('home-profile-button');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read the wall clock through the override-able provider so tests
    // pin the hour. Not watched on a timer — Home rebuilds often enough
    // (tab switches, resume) that a build-time read stays fresh.
    final DateTime now = ref.watch(homeClockProvider)();
    final AuthProvider auth = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: ListView(
          key: dashboardListKey,
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            // The signed-in caregiver's name drives the greeting. We
            // read it off the same auth stream Settings → Account uses
            // rather than caching a synchronous copy — the stream
            // replays the current state on subscribe, so there's no
            // first-frame flash.
            StreamBuilder<AuthState>(
              stream: auth.watchAuthState(),
              builder: (BuildContext context,
                  AsyncSnapshot<AuthState> snapshot) {
                final String name = switch (snapshot.data) {
                  AuthStateSignedIn(:final User user) =>
                    firstNameOf(user.name),
                  _ => '',
                };
                return _GreetingRow(hour: now.hour, name: name);
              },
            ),
            const SizedBox(height: 16),
            // First dashboard card: the pinned Emergency Card (Phase
            // 14.8). Further cards (14.10–14.12) and the quick-action FAB
            // (14.13) land as later children here.
            const EmergencyCardPin(),
            const SizedBox(height: 16),
            // Medications Today (Phase 14.9): today's doses with a status
            // dot + an X-of-Y count, tapping through to the full dose log.
            const MedicationsTodayCard(),
          ],
        ),
      ),
    );
  }
}

/// Greeting + profile affordance — the dashboard's top row.
class _GreetingRow extends StatelessWidget {
  const _GreetingRow({required this.hour, required this.name});

  final int hour;
  final String name;

  @override
  Widget build(BuildContext context) {
    final String prefix = greetingForHour(hour);
    // Fall back to a warm second-person address when the name is empty
    // (signed-out / pre-hydrate) so the line never trails a bare comma.
    final String line = name.isEmpty ? '$prefix, there' : '$prefix, $name';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(
            line,
            key: HomeScreen.greetingKey,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          key: HomeScreen.profileButtonKey,
          icon: const Icon(Icons.account_circle_outlined),
          iconSize: 32,
          color: careblazersColors.primary,
          tooltip: 'Profile & settings',
          onPressed: () =>
              GoRouter.of(context).pushNamed(CareblazersRoutes.settings),
        ),
      ],
    );
  }
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
