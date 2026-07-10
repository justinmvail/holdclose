import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_plan_routine.dart';
import '../../models/medication.dart' show FrequencyKind;
import '../../providers/care_plan_provider.dart';
import '../../providers/care_tasks_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Medical → Routines (v2 Care Plan, BUILD_SPEC.md §5.13). A simple list
/// of [CarePlanRoutine]s — title + scheduled time — with a "+" button
/// to add a new one. The routines themselves project into the unified
/// patient timeline (see [patientTimelineEventsProvider]); this screen
/// is just the management surface for adding / editing / deleting.
class CarePlanRoutinesScreen extends ConsumerWidget {
  const CarePlanRoutinesScreen({super.key});

  static const Key listKey = Key('care-plan-routines-list');
  static const Key emptyStateKey = Key('care-plan-routines-empty');
  static const Key addFabKey = Key('care-plan-routines-add-fab');
  static Key rowKey(String id) => Key('care-plan-routine-row-$id');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CarePlanRoutine>> async =
        ref.watch(carePlanProvider);
    // Child-task counts per routine (unified task/routine model) — feeds the
    // "· N tasks" suffix. A loading/error count just renders no suffix.
    final Map<String, int> taskCounts =
        ref.watch(routineTaskCountsProvider).value ?? const <String, int>{};
    return Scaffold(
      backgroundColor: context.hc.background,
      floatingActionButton: FloatingActionButton.extended(
        key: addFabKey,
        heroTag: 'care-plan-routines-add-fab',
        backgroundColor: context.hc.ctaFilled,
        foregroundColor: Colors.white,
        onPressed: () => context.push('/medical/routines/new'),
        icon: const Icon(Icons.add),
        label: const Text('Add routine'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Routines'),
                ],
                title: 'Routines',
                backLabel: 'Back to Care',
                leadingIcon: Icons.assignment_outlined,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _Error(message: '$e'),
                data: (List<CarePlanRoutine> routines) {
                  if (routines.isEmpty) {
                    return const _EmptyState();
                  }
                  return ListView.separated(
                    key: listKey,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    itemCount: routines.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int i) {
                      final CarePlanRoutine r = routines[i];
                      final MaterialLocalizations loc =
                          MaterialLocalizations.of(context);
                      return Material(
                        color: context.hc.surfaceWarm,
                        borderRadius: BorderRadius.circular(12),
                        child: ListTile(
                          key: rowKey(r.id),
                          onTap: () =>
                              context.push('/medical/routines/${r.id}'),
                          title: Text(
                            r.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            '${loc.formatTimeOfDay(r.scheduledTime)} · '
                            '${_frequencyLabel(r.frequencyKind)}'
                            '${_tasksSuffix(taskCounts[r.id] ?? 0)}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// " · N tasks" suffix for a routine that bundles child tasks; empty
  /// when it has none (unified task/routine model).
  static String _tasksSuffix(int count) {
    if (count == 0) return '';
    return ' · $count task${count == 1 ? '' : 's'}';
  }

  static String _frequencyLabel(FrequencyKind k) {
    switch (k) {
      case FrequencyKind.daily:
        return 'Daily';
      case FrequencyKind.twiceDaily:
        return 'Twice daily';
      case FrequencyKind.weekly:
        return 'Weekly';
      case FrequencyKind.asNeeded:
        return 'As needed';
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Padding(
      key: CarePlanRoutinesScreen.emptyStateKey,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'No routines yet.',
            style: tt.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Add the rhythms you want to keep — morning hygiene, '
            'evening wind-down, "ask about water at 3 PM". Each one '
            'shows up on the schedule with your other day.',
            style: tt.bodyMedium?.copyWith(
              color: context.hc.text.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text("Couldn't load routines.\n\n$message"),
    );
  }
}
