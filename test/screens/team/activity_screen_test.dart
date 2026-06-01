import 'dart:async';
import 'dart:convert';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/care_task.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/care_tasks_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart'
    show dosesTodayProvider;
import 'package:careblazers/screens/team/activity_screen.dart';
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
// `Provider` (the model) collides with riverpod's `Provider`; `hide` keeps
// the model name resolvable in the fixtures.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;

/// Fixed "now": 9 AM on Mon Jun 1 2026.
DateTime _fixedNow() => DateTime(2026, 6, 1, 9, 0);

ActivityFeedItem _item({
  required String id,
  required ActivityCategory category,
  required DateTime createdAt,
  String summary = 'summary',
  String route = '/',
}) =>
    ActivityFeedItem(
      id: id,
      category: category,
      summary: summary,
      createdAt: createdAt,
      route: route,
    );

Medication _med(String id, String name, String dosage) => Medication(
      id: id,
      name: name,
      dosage: dosage,
      route: MedicationRoute.oral,
    );

ScheduledDose _dose({
  required String medId,
  required String name,
  required DateTime scheduledFor,
  DoseStatus? status,
  DateTime? takenAt,
}) =>
    ScheduledDose(
      medication: _med(medId, name, '10 mg'),
      schedule: DoseSchedule(
        id: 'sched-$medId',
        medicationId: medId,
        frequencyKind: FrequencyKind.daily,
        timesOfDay: <TimeOfDay>[
          TimeOfDay(hour: scheduledFor.hour, minute: scheduledFor.minute),
        ],
        daysOfWeek: const <int>{},
        startsOn: DateTime(2026, 5, 1),
      ),
      scheduledFor: scheduledFor,
      log: status == null
          ? null
          : DoseLog(
              id: 'log-$medId',
              medicationId: medId,
              scheduledFor: scheduledFor,
              takenAt: takenAt,
              status: status,
            ),
    );

JournalEntry _decoderEntry({
  required String id,
  required DateTime createdAt,
  required Behavior behavior,
}) =>
    JournalEntry(
      id: id,
      behavior: behavior,
      triage: const TriageAnswers(),
      result: DecoderResult(
        say: const <String>[],
        tweak: const <String>[],
        dontSay: const <String>[],
        generatedAt: createdAt,
      ),
      outcome: JournalOutcome.positive,
      attempt: 1,
      createdAt: createdAt,
    );

CareTask _task({
  required String id,
  required String title,
  DateTime? completedAt,
}) =>
    CareTask(
      id: id,
      title: title,
      completedAt: completedAt,
      patientId: 'demo-patient-mary',
    );

/// A fake task notifier so the aggregation test can inject a known task set
/// without standing up a drift DB for the board.
class _FakeCareTasks extends CareTasks {
  _FakeCareTasks(this._tasks);

  final List<CareTask> _tasks;

  @override
  Future<List<CareTask>> build() async => _tasks;
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 820));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GoRouter router = GoRouter(
    initialLocation: '/team/activity',
    routes: <RouteBase>[
      GoRoute(
        path: '/team',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Center(child: Text('DEST /team'))),
      ),
      GoRoute(
        path: '/team/activity',
        builder: (BuildContext c, GoRouterState s) => const ActivityScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'tasks',
            builder: (BuildContext c, GoRouterState s) =>
                const Scaffold(body: Text('TASKS')),
          ),
        ],
      ),
      GoRoute(
        path: '/journal/:id',
        builder: (BuildContext c, GoRouterState s) =>
            Scaffold(body: Text('JOURNAL ${s.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/medications/today',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: Text('DOSE LOG')),
      ),
      GoRoute(
        path: '/appointments/:id',
        builder: (BuildContext c, GoRouterState s) =>
            Scaffold(body: Text('APPT ${s.pathParameters['id']}')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        activityClockProvider.overrideWithValue(_fixedNow),
        ...overrides,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: careblazersLightTheme,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ---- mergeActivity — the ordering invariant ----------------------------

  group('mergeActivity (Phase 14.32)', () {
    test('sorts every item by createdAt desc — no truncation', () {
      final List<ActivityFeedItem> items = <ActivityFeedItem>[
        _item(
          id: 'a',
          category: ActivityCategory.note,
          createdAt: DateTime(2026, 6, 1, 8, 0),
        ),
        _item(
          id: 'b',
          category: ActivityCategory.dose,
          createdAt: DateTime(2026, 6, 1, 8, 55),
        ),
        _item(
          id: 'c',
          category: ActivityCategory.task,
          createdAt: DateTime(2026, 6, 1, 7, 0),
        ),
        _item(
          id: 'd',
          category: ActivityCategory.appointment,
          createdAt: DateTime(2026, 6, 1, 8, 40),
        ),
      ];

      final List<ActivityFeedItem> sorted = mergeActivity(items);

      expect(sorted.map((ActivityFeedItem i) => i.id).toList(),
          <String>['b', 'd', 'a', 'c']);
      // Unlike the Home card, the whole set survives.
      expect(sorted.length, 4);
    });

    test('an out-of-order insertion across sources still lands in order', () {
      final List<ActivityFeedItem> scrambled = <ActivityFeedItem>[
        _item(
          id: 'old',
          category: ActivityCategory.appointment,
          createdAt: DateTime(2026, 6, 1, 6, 0),
        ),
        _item(
          id: 'mid',
          category: ActivityCategory.note,
          createdAt: DateTime(2026, 6, 1, 8, 30),
        ),
        // Newest of all, inserted last, from yet another source.
        _item(
          id: 'newest',
          category: ActivityCategory.shift,
          createdAt: DateTime(2026, 6, 1, 8, 55),
        ),
      ];

      expect(
        mergeActivity(scrambled).map((ActivityFeedItem i) => i.id).toList(),
        <String>['newest', 'mid', 'old'],
      );
    });

    test('result order is independent of input order', () {
      final List<ActivityFeedItem> ascending = <ActivityFeedItem>[
        _item(
          id: 'a',
          category: ActivityCategory.note,
          createdAt: DateTime(2026, 6, 1, 1),
        ),
        _item(
          id: 'b',
          category: ActivityCategory.dose,
          createdAt: DateTime(2026, 6, 1, 2),
        ),
        _item(
          id: 'c',
          category: ActivityCategory.task,
          createdAt: DateTime(2026, 6, 1, 3),
        ),
      ];
      expect(
        mergeActivity(ascending).map((ActivityFeedItem i) => i.id),
        mergeActivity(ascending.reversed.toList())
            .map((ActivityFeedItem i) => i.id),
      );
    });

    test('empty in, empty out', () {
      expect(mergeActivity(const <ActivityFeedItem>[]), isEmpty);
    });
  });

  // ---- filterActivity — the filter combinations --------------------------

  group('filterActivity (Phase 14.32)', () {
    final List<ActivityFeedItem> pool = <ActivityFeedItem>[
      _item(
        id: 'dose',
        category: ActivityCategory.dose,
        createdAt: DateTime(2026, 6, 1, 5),
      ),
      _item(
        id: 'note',
        category: ActivityCategory.note,
        createdAt: DateTime(2026, 6, 1, 4),
      ),
      _item(
        id: 'task',
        category: ActivityCategory.task,
        createdAt: DateTime(2026, 6, 1, 3),
      ),
      _item(
        id: 'shift',
        category: ActivityCategory.shift,
        createdAt: DateTime(2026, 6, 1, 2),
      ),
      _item(
        id: 'expense',
        category: ActivityCategory.expense,
        createdAt: DateTime(2026, 6, 1, 1),
      ),
      _item(
        id: 'appt',
        category: ActivityCategory.appointment,
        createdAt: DateTime(2026, 6, 1, 6),
      ),
    ];

    test('empty selection (All) returns everything, appointments included',
        () {
      final List<ActivityFeedItem> out =
          filterActivity(pool, <ActivityCategory>{});
      expect(out.length, pool.length);
      expect(out.any((ActivityFeedItem i) => i.id == 'appt'), isTrue);
    });

    test('a single category keeps only that category', () {
      final List<ActivityFeedItem> out =
          filterActivity(pool, <ActivityCategory>{ActivityCategory.dose});
      expect(out.map((ActivityFeedItem i) => i.id).toList(), <String>['dose']);
    });

    test('a multi-select keeps the union of selected categories', () {
      final List<ActivityFeedItem> out = filterActivity(
        pool,
        <ActivityCategory>{ActivityCategory.note, ActivityCategory.expense},
      );
      expect(
        out.map((ActivityFeedItem i) => i.id).toSet(),
        <String>{'note', 'expense'},
      );
    });

    test('selecting any chip hides appointments (they have no chip)', () {
      final List<ActivityFeedItem> out = filterActivity(
        pool,
        <ActivityCategory>{ActivityCategory.task, ActivityCategory.shift},
      );
      expect(out.any((ActivityFeedItem i) => i.id == 'appt'), isFalse);
      expect(out.map((ActivityFeedItem i) => i.id).toSet(),
          <String>{'task', 'shift'});
    });

    test('appointment is not among the filterable chip categories', () {
      expect(activityFilterCategories.contains(ActivityCategory.appointment),
          isFalse);
      expect(activityFilterCategories, <ActivityCategory>[
        ActivityCategory.dose,
        ActivityCategory.note,
        ActivityCategory.task,
        ActivityCategory.shift,
        ActivityCategory.expense,
      ]);
    });
  });

  // ---- source → item mapping ---------------------------------------------

  group('source mapping (Phase 14.32)', () {
    test('journal decoder entry maps to behavior label + journal route', () {
      final JournalEntry entry = _decoderEntry(
        id: 'je-1',
        createdAt: DateTime(2026, 6, 1, 8),
        behavior:
            const Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅'),
      );
      final ActivityFeedItem item = journalActivityFeedItem(entry);
      expect(item.category, ActivityCategory.note);
      expect(item.summary, 'Sundowning');
      expect(item.route, '/journal/je-1');
      expect(item.id, 'journal-je-1');
      expect(item.createdAt, entry.createdAt);
    });

    test('wizard entry uses the caregiver situation text, blank falls back',
        () {
      expect(
        activityJournalSummary(JournalEntry.wizard(
          id: 'wz-1',
          createdAt: DateTime(2026, 6, 1, 8),
          situationText: 'She kept asking for her mother',
        )),
        'She kept asking for her mother',
      );
      expect(
        activityJournalSummary(JournalEntry.wizard(
          id: 'wz-2',
          createdAt: DateTime(2026, 6, 1, 8),
          situationText: '   ',
        )),
        'Journal note',
      );
    });

    test('dose maps to verb + name + dosage, taken time, dose-log route', () {
      final ActivityFeedItem item = doseActivityFeedItem(_dose(
        medId: 'm-1',
        name: 'Donepezil',
        scheduledFor: DateTime(2026, 6, 1, 8, 0),
        status: DoseStatus.taken,
        takenAt: DateTime(2026, 6, 1, 8, 5),
      ));
      expect(item.category, ActivityCategory.dose);
      expect(item.summary, 'Gave Donepezil 10 mg');
      expect(item.route, '/medications/today');
      expect(item.createdAt, DateTime(2026, 6, 1, 8, 5));
    });

    test('skipped / missed doses read their own verb', () {
      expect(
        activityDoseSummary(_dose(
          medId: 'm',
          name: 'Aricept',
          scheduledFor: DateTime(2026, 6, 1, 8),
          status: DoseStatus.skipped,
        )),
        'Skipped Aricept 10 mg',
      );
      expect(
        activityDoseSummary(_dose(
          medId: 'm',
          name: 'Aricept',
          scheduledFor: DateTime(2026, 6, 1, 8),
          status: DoseStatus.missed,
        )),
        'Missed Aricept 10 mg',
      );
    });

    test('dose with no takenAt falls back to the scheduled time', () {
      expect(
        doseActivityFeedItem(_dose(
          medId: 'm-2',
          name: 'Metformin',
          scheduledFor: DateTime(2026, 6, 1, 7, 30),
          status: DoseStatus.skipped,
        )).createdAt,
        DateTime(2026, 6, 1, 7, 30),
      );
    });

    test('appointment maps to provider name + appointment route', () {
      final Appointment appt = Appointment(
        id: 'ap-1',
        providerId: 'pr-1',
        startsAt: DateTime(2026, 6, 4, 14, 30),
        durationMinutes: 30,
        location: 'Clinic',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      );
      const Provider provider = Provider(
        id: 'pr-1',
        name: 'Dr. Ortega',
        role: ProviderRole.neurologist,
        phone: '',
        address: '',
      );
      final ActivityFeedItem item = appointmentActivityFeedItem(appt, provider);
      expect(item.category, ActivityCategory.appointment);
      expect(item.summary, 'Appointment with Dr. Ortega');
      expect(item.route, '/appointments/ap-1');
      expect(item.createdAt, appt.startsAt);
    });

    test('appointment with a missing provider reads the soft fallback', () {
      expect(activityAppointmentSummary(null), 'Appointment with your provider');
    });

    test('completed task maps to a completion summary + task-board route', () {
      final ActivityFeedItem item = taskActivityFeedItem(_task(
        id: 't-1',
        title: 'Refill meds',
        completedAt: DateTime(2026, 6, 1, 8, 15),
      ));
      expect(item.category, ActivityCategory.task);
      expect(item.summary, 'Completed Refill meds');
      expect(item.route, '/team/tasks');
      expect(item.id, 'task-t-1');
      expect(item.createdAt, DateTime(2026, 6, 1, 8, 15));
    });
  });

  // ---- color + label mapping ---------------------------------------------

  group('activityCategoryColor / Label (Phase 14.32)', () {
    test('each category maps to its documented hue', () {
      expect(activityCategoryColor(ActivityCategory.dose),
          ActivityScreen.doseColor);
      expect(activityCategoryColor(ActivityCategory.note),
          ActivityScreen.noteColor);
      expect(activityCategoryColor(ActivityCategory.appointment),
          ActivityScreen.appointmentColor);
      expect(activityCategoryColor(ActivityCategory.task),
          careblazersColors.link);
      expect(activityCategoryColor(ActivityCategory.shift),
          careblazersColors.success);
      expect(activityCategoryColor(ActivityCategory.expense),
          careblazersColors.primary);
    });

    test('each category reads its chip label', () {
      expect(activityCategoryLabel(ActivityCategory.dose), 'Doses');
      expect(activityCategoryLabel(ActivityCategory.note), 'Notes');
      expect(activityCategoryLabel(ActivityCategory.task), 'Tasks');
      expect(activityCategoryLabel(ActivityCategory.shift), 'Shifts');
      expect(activityCategoryLabel(ActivityCategory.expense), 'Expenses');
      expect(
          activityCategoryLabel(ActivityCategory.appointment), 'Appointments');
    });
  });

  // ---- activityRelativeTime ----------------------------------------------

  group('activityRelativeTime (Phase 14.32)', () {
    final DateTime now = DateTime(2026, 6, 1, 12, 0);

    test('under a minute reads "just now"', () {
      expect(activityRelativeTime(now.subtract(const Duration(seconds: 30)), now),
          'just now');
    });

    test('minutes / hours / days / weeks in the past', () {
      expect(activityRelativeTime(now.subtract(const Duration(minutes: 20)), now),
          '20 min ago');
      expect(activityRelativeTime(now.subtract(const Duration(hours: 1)), now),
          '1 hr ago');
      expect(activityRelativeTime(now.subtract(const Duration(hours: 5)), now),
          '5 hrs ago');
      expect(activityRelativeTime(now.subtract(const Duration(days: 1)), now),
          '1 day ago');
      expect(activityRelativeTime(now.subtract(const Duration(days: 7)), now),
          '1 wk ago');
      expect(activityRelativeTime(now.subtract(const Duration(days: 14)), now),
          '2 wks ago');
    });

    test('a future timestamp reads "in <n>"', () {
      expect(activityRelativeTime(now.add(const Duration(days: 2)), now),
          'in 2 days');
    });
  });

  // ---- widget behaviour ---------------------------------------------------

  List<ActivityFeedItem> mixedFeed() => <ActivityFeedItem>[
        _item(
          id: 'appt-1',
          category: ActivityCategory.appointment,
          createdAt: _fixedNow().subtract(const Duration(minutes: 10)),
          summary: 'Appointment with Dr. Ortega',
          route: '/appointments/1',
        ),
        _item(
          id: 'note-1',
          category: ActivityCategory.note,
          createdAt: _fixedNow().subtract(const Duration(minutes: 20)),
          summary: 'Sundowning',
          route: '/journal/1',
        ),
        _item(
          id: 'dose-1',
          category: ActivityCategory.dose,
          createdAt: _fixedNow().subtract(const Duration(hours: 2)),
          summary: 'Gave Donepezil 10 mg',
          route: '/medications/today',
        ),
        _item(
          id: 'task-1',
          category: ActivityCategory.task,
          createdAt: _fixedNow().subtract(const Duration(hours: 3)),
          summary: 'Completed Refill meds',
          route: '/team/tasks',
        ),
      ];

  group('ActivityScreen — render + filters', () {
    testWidgets('All (default) shows every row including the appointment',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider.overrideWith((ref) async => mixedFeed()),
        ],
      );

      // "Activity" appears twice — the breadcrumb's terminal crumb and the
      // page title.
      expect(find.text('Activity'), findsNWidgets(2));
      expect(find.byKey(ActivityScreen.allChipKey), findsOneWidget);
      for (final String id in <String>['appt-1', 'note-1', 'dose-1', 'task-1']) {
        expect(find.byKey(ActivityScreen.rowKey(id)), findsOneWidget);
      }
    });

    testWidgets('selecting Doses narrows to dose rows and hides appointments',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider.overrideWith((ref) async => mixedFeed()),
        ],
      );

      await tester.tap(find.byKey(ActivityScreen.chipKey(ActivityCategory.dose)));
      await tester.pumpAndSettle();

      expect(find.byKey(ActivityScreen.rowKey('dose-1')), findsOneWidget);
      expect(find.byKey(ActivityScreen.rowKey('note-1')), findsNothing);
      expect(find.byKey(ActivityScreen.rowKey('task-1')), findsNothing);
      // No Appointments chip exists, so the appointment drops out too.
      expect(find.byKey(ActivityScreen.rowKey('appt-1')), findsNothing);
    });

    testWidgets('multi-select keeps the union; All clears back to everything',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider.overrideWith((ref) async => mixedFeed()),
        ],
      );

      await tester.tap(find.byKey(ActivityScreen.chipKey(ActivityCategory.dose)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ActivityScreen.chipKey(ActivityCategory.note)));
      await tester.pumpAndSettle();

      expect(find.byKey(ActivityScreen.rowKey('dose-1')), findsOneWidget);
      expect(find.byKey(ActivityScreen.rowKey('note-1')), findsOneWidget);
      expect(find.byKey(ActivityScreen.rowKey('task-1')), findsNothing);

      await tester.tap(find.byKey(ActivityScreen.allChipKey));
      await tester.pumpAndSettle();
      expect(find.byKey(ActivityScreen.rowKey('task-1')), findsOneWidget);
      expect(find.byKey(ActivityScreen.rowKey('appt-1')), findsOneWidget);
    });

    testWidgets('the category dot wears its category hue',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider.overrideWith((ref) async => mixedFeed()),
        ],
      );

      Color dotColor(String id) {
        final Container dot =
            tester.widget<Container>(find.byKey(ActivityScreen.dotKey(id)));
        return (dot.decoration! as BoxDecoration).color!;
      }

      expect(dotColor('dose-1'), ActivityScreen.doseColor);
      expect(dotColor('note-1'), ActivityScreen.noteColor);
      expect(dotColor('appt-1'), ActivityScreen.appointmentColor);
      expect(dotColor('task-1'), careblazersColors.link);
    });

    testWidgets('tapping a row pushes its source detail',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider.overrideWith(
            (ref) async => <ActivityFeedItem>[
              _item(
                id: 'note-42',
                category: ActivityCategory.note,
                createdAt: _fixedNow(),
                summary: 'A moment',
                route: '/journal/42',
              ),
            ],
          ),
        ],
      );

      expect(find.text('JOURNAL 42'), findsNothing);
      await tester.tap(find.byKey(ActivityScreen.rowKey('note-42')));
      await tester.pumpAndSettle();
      expect(find.text('JOURNAL 42'), findsOneWidget);
    });

    testWidgets('pull-to-refresh re-queries and keeps the feed up',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider.overrideWith((ref) async => mixedFeed()),
        ],
      );

      expect(find.byType(RefreshIndicator), findsOneWidget);

      // Fling the list downward to fire the RefreshIndicator → _refresh,
      // which invalidates the source providers and re-awaits the feed.
      await tester.fling(
          find.byKey(ActivityScreen.listKey), const Offset(0, 320), 1200);
      await tester.pumpAndSettle();

      expect(find.byKey(ActivityScreen.rowKey('dose-1')), findsOneWidget);
    });

    testWidgets('empty — shows the empty state', (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider
              .overrideWith((ref) async => const <ActivityFeedItem>[]),
        ],
      );

      expect(find.byKey(ActivityScreen.emptyKey), findsOneWidget);
      expect(find.text('Nothing here yet.'), findsOneWidget);
    });

    testWidgets('error — shows the muted error body, no rows',
        (WidgetTester tester) async {
      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider
              .overrideWith((ref) async => throw StateError('boom')),
        ],
      );

      expect(find.byKey(ActivityScreen.errorKey), findsOneWidget);
      expect(find.byKey(ActivityScreen.rowKey('note-1')), findsNothing);
    });

    testWidgets('loading — shows neither the list nor the empty state',
        (WidgetTester tester) async {
      final Completer<List<ActivityFeedItem>> pending =
          Completer<List<ActivityFeedItem>>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(const <ActivityFeedItem>[]);
      });

      await tester.binding.setSurfaceSize(const Size(420, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            activityClockProvider.overrideWithValue(_fixedNow),
            teamActivityProvider.overrideWith((ref) => pending.future),
          ],
          child: const MaterialApp(home: ActivityScreen()),
        ),
      );
      await tester.pump();

      expect(find.byKey(ActivityScreen.listKey), findsNothing);
      expect(find.byKey(ActivityScreen.emptyKey), findsNothing);
    });
  });

  // ---- pagination ---------------------------------------------------------

  group('ActivityScreen — pagination (Phase 14.32)', () {
    testWidgets('renders the first page; scrolling loads more',
        (WidgetTester tester) async {
      // 25 rows, newest first by index (note-0 is newest, note-24 oldest).
      final List<ActivityFeedItem> many = <ActivityFeedItem>[
        for (int i = 0; i < 25; i++)
          _item(
            id: 'note-$i',
            category: ActivityCategory.note,
            createdAt: _fixedNow().subtract(Duration(minutes: i)),
            summary: 'Note $i',
            route: '/journal/$i',
          ),
      ];

      await _pumpScreen(
        tester,
        overrides: <Override>[
          teamActivityProvider.overrideWith((ref) async => many),
        ],
      );

      // First page is bounded: the newest row is up and the oldest row
      // (beyond the first page of [activityPageSize]) isn't in the tree at
      // all — only the first 20 rows + a load-more footer are materialized.
      expect(find.byKey(ActivityScreen.rowKey('note-0')), findsOneWidget);
      expect(find.byKey(ActivityScreen.rowKey('note-24')), findsNothing);

      // Scrolling toward the bottom grows the window a page at a time until
      // the oldest row materializes (proving the feed isn't capped at one
      // page).
      final Finder list = find.byKey(ActivityScreen.listKey);
      final Finder oldest = find.byKey(ActivityScreen.rowKey('note-24'));
      for (int i = 0; i < 15 && oldest.evaluate().isEmpty; i++) {
        await tester.drag(list, const Offset(0, -500));
        await tester.pumpAndSettle();
      }

      expect(oldest, findsOneWidget);
    });
  });

  // ---- teamActivity provider — live aggregation wiring -------------------

  group('teamActivityProvider — aggregation (Phase 14.32)', () {
    Future<void> seedProvider(CareblazersDatabase db, Provider p) async {
      await db.into(db.providersTable).insertOnConflictUpdate(
            ProvidersTableCompanion.insert(
              id: p.id,
              name: p.name,
              payload: jsonEncode(p.toJson()),
            ),
          );
    }

    testWidgets('merges journal + dose + appointment + task + seams, newest '
        'first; excludes unlogged doses and open tasks',
        (WidgetTester tester) async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      await storage.insertJournalEntry(_decoderEntry(
        id: 'j-1',
        createdAt: DateTime(2026, 6, 1, 8, 55),
        behavior:
            const Behavior(id: 'wandering', label: 'Wandering', glyph: '🚶'),
      ));

      final CareblazersDatabase apptDb =
          CareblazersDatabase(NativeDatabase.memory());
      addTearDown(apptDb.close);
      final AppointmentRepository apptRepo =
          AppointmentRepository(apptDb, clock: _fixedNow);
      await seedProvider(
        apptDb,
        const Provider(
          id: 'pr-1',
          name: 'Dr. Ortega',
          role: ProviderRole.neurologist,
          phone: '',
          address: '',
        ),
      );
      await apptRepo.upsertAppointment(Appointment(
        id: 'ap-1',
        providerId: 'pr-1',
        startsAt: DateTime(2026, 6, 1, 8, 30),
        durationMinutes: 30,
        location: 'Clinic',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      ));

      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          storageBackendProvider.overrideWithValue(storage),
          appointmentRepositoryBackendProvider.overrideWithValue(apptRepo),
          dosesTodayProvider.overrideWith(
            (ref) async => <ScheduledDose>[
              _dose(
                medId: 'm-1',
                name: 'Donepezil',
                scheduledFor: DateTime(2026, 6, 1, 8, 0),
                status: DoseStatus.taken,
                takenAt: DateTime(2026, 6, 1, 8, 5),
              ),
              // Unlogged upcoming dose — must NOT surface as activity.
              _dose(
                medId: 'm-2',
                name: 'Metformin',
                scheduledFor: DateTime(2026, 6, 1, 20, 0),
              ),
            ],
          ),
          careTasksProvider.overrideWith(() => _FakeCareTasks(<CareTask>[
                _task(
                  id: 't-done',
                  title: 'Refill meds',
                  completedAt: DateTime(2026, 6, 1, 7, 0),
                ),
                // Open task — must NOT surface as activity.
                _task(id: 't-open', title: 'Call pharmacy'),
              ])),
          activityShiftItemsProvider.overrideWith(
            (ref) async => <ActivityFeedItem>[
              _item(
                id: 'shift-1',
                category: ActivityCategory.shift,
                createdAt: DateTime(2026, 6, 1, 6, 0),
                summary: 'Maria took the morning shift',
                route: '/team/shifts',
              ),
            ],
          ),
          activityExpenseItemsProvider.overrideWith(
            (ref) async => <ActivityFeedItem>[
              _item(
                id: 'expense-1',
                category: ActivityCategory.expense,
                createdAt: DateTime(2026, 6, 1, 5, 0),
                summary: 'Pharmacy \$24.00',
                route: '/team/expenses',
              ),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);

      // Keep the autoDispose provider + its stream-backed journal dependency
      // mounted while we await.
      container.listen<AsyncValue<List<ActivityFeedItem>>>(
        teamActivityProvider,
        (AsyncValue<List<ActivityFeedItem>>? _,
            AsyncValue<List<ActivityFeedItem>> __) {},
      );

      final List<ActivityFeedItem> feed =
          await container.read(teamActivityProvider.future);

      // Desc by createdAt: j-1 8:55 > ap-1 8:30 > dose 8:05 > task 7:00 >
      // shift 6:00 > expense 5:00.
      expect(
        feed.map((ActivityFeedItem i) => i.id).toList(),
        <String>[
          'journal-j-1',
          'appointment-ap-1',
          'dose-m-1-${DateTime(2026, 6, 1, 8, 0).millisecondsSinceEpoch}',
          'task-t-done',
          'shift-1',
          'expense-1',
        ],
      );
      // The unlogged dose + the open task fell away.
      expect(feed.any((ActivityFeedItem i) => i.summary.contains('Metformin')),
          isFalse);
      expect(feed.any((ActivityFeedItem i) => i.id == 'task-t-open'), isFalse);

      await storage.dispose();
    });
  });
}
