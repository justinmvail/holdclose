import 'dart:async';
import 'dart:convert';

import 'package:careblazers/db/database.dart';
import 'package:careblazers/models/appointment.dart';
import 'package:careblazers/models/behavior.dart';
import 'package:careblazers/models/decoder_result.dart';
import 'package:careblazers/models/journal_entry.dart';
import 'package:careblazers/models/medication.dart';
import 'package:careblazers/models/triage.dart';
import 'package:careblazers/providers/home_clock_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart'
    show dosesTodayProvider;
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/recent_activity_card.dart';
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

RecentActivityItem _item({
  required String id,
  required RecentActivityOrigin origin,
  required DateTime createdAt,
  String summary = 'summary',
  String route = '/',
}) =>
    RecentActivityItem(
      id: id,
      origin: origin,
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

Future<void> _pumpCard(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GoRouter router = GoRouter(
    initialLocation: '/',
    navigatorKey: rootKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) => const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: RecentActivityCard(),
          ),
        ),
      ),
      GoRoute(
        path: '/journal/:id',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            Scaffold(body: Text('JOURNAL ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/medications/today',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Text('DOSE LOG')),
      ),
      GoRoute(
        path: '/appointments/:id',
        parentNavigatorKey: rootKey,
        builder: (BuildContext context, GoRouterState state) =>
            Scaffold(body: Text('APPT ${state.pathParameters['id']}')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        homeClockProvider.overrideWithValue(_fixedNow),
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
  // ---- mergeRecentActivity — the ordering invariant ----------------------

  group('mergeRecentActivity (Phase 14.11)', () {
    test('sorts by createdAt desc and keeps the top 3', () {
      final List<RecentActivityItem> items = <RecentActivityItem>[
        _item(
          id: 'j1',
          origin: RecentActivityOrigin.journal,
          createdAt: DateTime(2026, 6, 1, 8, 40),
        ),
        _item(
          id: 'd1',
          origin: RecentActivityOrigin.dose,
          createdAt: DateTime(2026, 6, 1, 8, 0),
        ),
        _item(
          id: 'a1',
          origin: RecentActivityOrigin.appointment,
          createdAt: DateTime(2026, 6, 1, 7, 0),
        ),
        _item(
          id: 'j2',
          origin: RecentActivityOrigin.journal,
          createdAt: DateTime(2026, 6, 1, 8, 55),
        ),
        _item(
          id: 'd2',
          origin: RecentActivityOrigin.dose,
          createdAt: DateTime(2026, 6, 1, 6, 0),
        ),
      ];

      final List<RecentActivityItem> top = mergeRecentActivity(items);

      expect(top.map((RecentActivityItem i) => i.id).toList(),
          <String>['j2', 'j1', 'd1']);
      expect(top.length, recentActivityLimit);
    });

    test('an out-of-order insertion across sources still surfaces top 3',
        () {
      // The newest event (a dose at 8:55) is inserted LAST and from a
      // different source than the rows around it — the merge must still
      // float it to the top and drop the two oldest.
      final List<RecentActivityItem> scrambled = <RecentActivityItem>[
        _item(
          id: 'appt-old',
          origin: RecentActivityOrigin.appointment,
          createdAt: DateTime(2026, 6, 1, 6, 0),
        ),
        _item(
          id: 'journal-mid',
          origin: RecentActivityOrigin.journal,
          createdAt: DateTime(2026, 6, 1, 8, 30),
        ),
        _item(
          id: 'dose-older',
          origin: RecentActivityOrigin.dose,
          createdAt: DateTime(2026, 6, 1, 7, 15),
        ),
        // Inserted out of order, newest of all, from yet another source.
        _item(
          id: 'dose-newest',
          origin: RecentActivityOrigin.dose,
          createdAt: DateTime(2026, 6, 1, 8, 55),
        ),
      ];

      final List<RecentActivityItem> top = mergeRecentActivity(scrambled);

      expect(top.map((RecentActivityItem i) => i.id).toList(),
          <String>['dose-newest', 'journal-mid', 'dose-older']);
      // The oldest event ('appt-old') fell off the bottom.
      expect(top.any((RecentActivityItem i) => i.id == 'appt-old'), isFalse);
    });

    test('result order is independent of input order', () {
      final List<RecentActivityItem> ascending = <RecentActivityItem>[
        _item(
          id: 'a',
          origin: RecentActivityOrigin.journal,
          createdAt: DateTime(2026, 6, 1, 1),
        ),
        _item(
          id: 'b',
          origin: RecentActivityOrigin.dose,
          createdAt: DateTime(2026, 6, 1, 2),
        ),
        _item(
          id: 'c',
          origin: RecentActivityOrigin.appointment,
          createdAt: DateTime(2026, 6, 1, 3),
        ),
      ];
      final List<RecentActivityItem> descending =
          ascending.reversed.toList();

      expect(
        mergeRecentActivity(ascending).map((RecentActivityItem i) => i.id),
        mergeRecentActivity(descending).map((RecentActivityItem i) => i.id),
      );
    });

    test('fewer than the limit returns everything sorted', () {
      final List<RecentActivityItem> items = <RecentActivityItem>[
        _item(
          id: 'x',
          origin: RecentActivityOrigin.journal,
          createdAt: DateTime(2026, 6, 1, 1),
        ),
        _item(
          id: 'y',
          origin: RecentActivityOrigin.dose,
          createdAt: DateTime(2026, 6, 1, 2),
        ),
      ];
      expect(mergeRecentActivity(items).map((RecentActivityItem i) => i.id),
          <String>['y', 'x']);
    });

    test('empty in, empty out', () {
      expect(mergeRecentActivity(const <RecentActivityItem>[]), isEmpty);
    });
  });

  // ---- source → item mapping ---------------------------------------------

  group('source mapping (Phase 14.11)', () {
    test('journal decoder entry maps to behavior label + journal route', () {
      final JournalEntry entry = _decoderEntry(
        id: 'je-1',
        createdAt: DateTime(2026, 6, 1, 8),
        behavior: const Behavior(id: 'sundowning', label: 'Sundowning', glyph: '🌅'),
      );
      final RecentActivityItem item = journalActivityItem(entry);
      expect(item.origin, RecentActivityOrigin.journal);
      expect(item.summary, 'Sundowning');
      expect(item.route, '/journal/je-1');
      expect(item.id, 'journal-je-1');
      expect(item.createdAt, entry.createdAt);
    });

    test('wizard entry uses the caregiver situation text', () {
      final JournalEntry entry = JournalEntry.wizard(
        id: 'wz-1',
        createdAt: DateTime(2026, 6, 1, 8),
        situationText: 'She kept asking for her mother',
      );
      expect(recentActivityJournalSummary(entry),
          'She kept asking for her mother');
    });

    test('wizard entry with blank situation falls back to "Journal note"',
        () {
      final JournalEntry entry = JournalEntry.wizard(
        id: 'wz-2',
        createdAt: DateTime(2026, 6, 1, 8),
        situationText: '   ',
      );
      expect(recentActivityJournalSummary(entry), 'Journal note');
    });

    test('dose maps to verb + name + dosage, taken time, dose-log route',
        () {
      final ScheduledDose dose = _dose(
        medId: 'm-1',
        name: 'Donepezil',
        scheduledFor: DateTime(2026, 6, 1, 8, 0),
        status: DoseStatus.taken,
        takenAt: DateTime(2026, 6, 1, 8, 5),
      );
      final RecentActivityItem item = doseActivityItem(dose);
      expect(item.origin, RecentActivityOrigin.dose);
      expect(item.summary, 'Gave Donepezil 10 mg');
      expect(item.route, '/medications/today');
      expect(item.createdAt, DateTime(2026, 6, 1, 8, 5));
    });

    test('skipped / missed doses read their own verb', () {
      expect(
        recentActivityDoseSummary(_dose(
          medId: 'm',
          name: 'Aricept',
          scheduledFor: DateTime(2026, 6, 1, 8),
          status: DoseStatus.skipped,
        )),
        'Skipped Aricept 10 mg',
      );
      expect(
        recentActivityDoseSummary(_dose(
          medId: 'm',
          name: 'Aricept',
          scheduledFor: DateTime(2026, 6, 1, 8),
          status: DoseStatus.missed,
        )),
        'Missed Aricept 10 mg',
      );
    });

    test('dose with no takenAt falls back to the scheduled time', () {
      final ScheduledDose dose = _dose(
        medId: 'm-2',
        name: 'Metformin',
        scheduledFor: DateTime(2026, 6, 1, 7, 30),
        status: DoseStatus.skipped,
      );
      expect(doseActivityItem(dose).createdAt, DateTime(2026, 6, 1, 7, 30));
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
      final RecentActivityItem item =
          appointmentActivityItem(appt, provider);
      expect(item.origin, RecentActivityOrigin.appointment);
      expect(item.summary, 'Appointment with Dr. Ortega');
      expect(item.route, '/appointments/ap-1');
      expect(item.createdAt, appt.startsAt);
    });

    test('appointment with a missing provider reads the soft fallback', () {
      expect(recentActivityAppointmentSummary(null),
          'Appointment with your provider');
    });
  });

  // ---- origin color mapping ----------------------------------------------

  group('recentActivityOriginColor (Phase 14.11)', () {
    test('each origin maps to its documented hue', () {
      expect(recentActivityOriginColor(RecentActivityOrigin.journal),
          RecentActivityCard.journalColor);
      expect(recentActivityOriginColor(RecentActivityOrigin.dose),
          RecentActivityCard.doseColor);
      expect(recentActivityOriginColor(RecentActivityOrigin.appointment),
          RecentActivityCard.appointmentColor);
      expect(recentActivityOriginColor(RecentActivityOrigin.team),
          careblazersColors.primary);
    });
  });

  // ---- formatRelativeTime ------------------------------------------------

  group('formatRelativeTime (Phase 14.11)', () {
    final DateTime now = DateTime(2026, 6, 1, 12, 0);

    test('under a minute reads "just now"', () {
      expect(formatRelativeTime(now.subtract(const Duration(seconds: 30)), now),
          'just now');
      expect(formatRelativeTime(now.add(const Duration(seconds: 30)), now),
          'just now');
    });

    test('minutes / hours / days / weeks in the past', () {
      expect(formatRelativeTime(now.subtract(const Duration(minutes: 20)), now),
          '20 min ago');
      expect(formatRelativeTime(now.subtract(const Duration(hours: 1)), now),
          '1 hr ago');
      expect(formatRelativeTime(now.subtract(const Duration(hours: 5)), now),
          '5 hrs ago');
      expect(formatRelativeTime(now.subtract(const Duration(days: 1)), now),
          '1 day ago');
      expect(formatRelativeTime(now.subtract(const Duration(days: 3)), now),
          '3 days ago');
      expect(formatRelativeTime(now.subtract(const Duration(days: 14)), now),
          '2 wks ago');
    });

    test('a future timestamp reads "in <n>"', () {
      expect(formatRelativeTime(now.add(const Duration(days: 2)), now),
          'in 2 days');
      expect(formatRelativeTime(now.add(const Duration(minutes: 45)), now),
          'in 45 min');
    });
  });

  // ---- widget behaviour ---------------------------------------------------

  group('RecentActivityCard — render states', () {
    testWidgets('empty — renders "No recent activity yet."',
        (WidgetTester tester) async {
      await _pumpCard(
        tester,
        overrides: <Override>[
          recentActivityProvider.overrideWith(
            (ref) async => const <RecentActivityItem>[],
          ),
        ],
      );

      expect(find.text('Recent Activity'), findsOneWidget);
      expect(find.byKey(RecentActivityCard.emptyKey), findsOneWidget);
      expect(find.text('No recent activity yet.'), findsOneWidget);
      expect(find.byKey(RecentActivityCard.listKey), findsNothing);
    });

    testWidgets('populated — renders a row per item with its origin dot',
        (WidgetTester tester) async {
      final List<RecentActivityItem> items = <RecentActivityItem>[
        _item(
          id: 'journal-1',
          origin: RecentActivityOrigin.journal,
          createdAt: _fixedNow().subtract(const Duration(minutes: 20)),
          summary: 'Sundowning',
          route: '/journal/1',
        ),
        _item(
          id: 'dose-1',
          origin: RecentActivityOrigin.dose,
          createdAt: _fixedNow().subtract(const Duration(hours: 2)),
          summary: 'Gave Donepezil 10 mg',
          route: '/medications/today',
        ),
        _item(
          id: 'appointment-1',
          origin: RecentActivityOrigin.appointment,
          createdAt: _fixedNow().subtract(const Duration(days: 1)),
          summary: 'Appointment with Dr. Ortega',
          route: '/appointments/7',
        ),
      ];

      await _pumpCard(
        tester,
        overrides: <Override>[
          recentActivityProvider.overrideWith((ref) async => items),
        ],
      );

      expect(find.byKey(RecentActivityCard.listKey), findsOneWidget);
      expect(find.text('Sundowning'), findsOneWidget);
      expect(find.text('Gave Donepezil 10 mg'), findsOneWidget);
      expect(find.text('Appointment with Dr. Ortega'), findsOneWidget);
      expect(find.text('20 min ago'), findsOneWidget);
      expect(find.text('2 hrs ago'), findsOneWidget);
      expect(find.text('1 day ago'), findsOneWidget);

      Color dotColor(String id) {
        final Container dot = tester
            .widget<Container>(find.byKey(RecentActivityCard.dotKey(id)));
        return (dot.decoration! as BoxDecoration).color!;
      }

      expect(dotColor('journal-1'), RecentActivityCard.journalColor);
      expect(dotColor('dose-1'), RecentActivityCard.doseColor);
      expect(dotColor('appointment-1'), RecentActivityCard.appointmentColor);
    });

    testWidgets('tapping a journal row pushes its source detail',
        (WidgetTester tester) async {
      await _pumpCard(
        tester,
        overrides: <Override>[
          recentActivityProvider.overrideWith(
            (ref) async => <RecentActivityItem>[
              _item(
                id: 'journal-42',
                origin: RecentActivityOrigin.journal,
                createdAt: _fixedNow(),
                summary: 'A moment',
                route: '/journal/42',
              ),
            ],
          ),
        ],
      );

      expect(find.text('JOURNAL 42'), findsNothing);
      await tester.tap(find.byKey(RecentActivityCard.rowKey('journal-42')));
      await tester.pumpAndSettle();
      expect(find.text('JOURNAL 42'), findsOneWidget);
    });

    testWidgets('tapping an appointment row pushes /appointments/:id',
        (WidgetTester tester) async {
      await _pumpCard(
        tester,
        overrides: <Override>[
          recentActivityProvider.overrideWith(
            (ref) async => <RecentActivityItem>[
              _item(
                id: 'appointment-9',
                origin: RecentActivityOrigin.appointment,
                createdAt: _fixedNow(),
                summary: 'Appointment with Dr. Ortega',
                route: '/appointments/9',
              ),
            ],
          ),
        ],
      );

      await tester.tap(find.byKey(RecentActivityCard.rowKey('appointment-9')));
      await tester.pumpAndSettle();
      expect(find.text('APPT 9'), findsOneWidget);
    });

    testWidgets('loading — shows the skeleton while the feed is unresolved',
        (WidgetTester tester) async {
      final Completer<List<RecentActivityItem>> pending =
          Completer<List<RecentActivityItem>>();
      addTearDown(() {
        if (!pending.isCompleted) {
          pending.complete(const <RecentActivityItem>[]);
        }
      });

      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            homeClockProvider.overrideWithValue(_fixedNow),
            recentActivityProvider.overrideWith((ref) => pending.future),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: RecentActivityCard(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(RecentActivityCard.skeletonKey), findsOneWidget);
      expect(find.byKey(RecentActivityCard.emptyKey), findsNothing);
      expect(find.byKey(RecentActivityCard.listKey), findsNothing);
    });

    testWidgets('error — shows a single muted line, no rows',
        (WidgetTester tester) async {
      await _pumpCard(
        tester,
        overrides: <Override>[
          recentActivityProvider.overrideWith(
            (ref) async => throw StateError('boom'),
          ),
        ],
      );

      expect(find.byKey(RecentActivityCard.listKey), findsNothing);
      expect(
        find.text("We couldn't load your recent activity."),
        findsOneWidget,
      );
    });
  });

  // ---- recentActivity provider — live aggregation wiring ------------------

  group('recentActivityProvider — aggregation (Phase 14.11)', () {
    Future<void> seedProvider(CareblazersDatabase db, Provider p) async {
      await db.into(db.providersTable).insertOnConflictUpdate(
            ProvidersTableCompanion.insert(
              id: p.id,
              name: p.name,
              payload: jsonEncode(p.toJson()),
            ),
          );
    }

    testWidgets('merges journal + dose + appointment into the top 3',
        (WidgetTester tester) async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      // Two journal entries; the newer should rank above the older.
      await storage.insertJournalEntry(_decoderEntry(
        id: 'j-old',
        createdAt: DateTime(2026, 6, 1, 6, 0),
        behavior:
            const Behavior(id: 'upset', label: 'Upset / crying', glyph: '💔'),
      ));
      await storage.insertJournalEntry(_decoderEntry(
        id: 'j-new',
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
        ],
      );
      addTearDown(container.dispose);

      // Keep the (autoDispose) provider + its stream-backed journal
      // dependency mounted while we await — a bare `read(.future)` would
      // let them dispose before the first stream value lands and hang.
      container.listen<AsyncValue<List<RecentActivityItem>>>(
        recentActivityProvider,
        (AsyncValue<List<RecentActivityItem>>? _,
            AsyncValue<List<RecentActivityItem>> __) {},
      );

      final List<RecentActivityItem> feed =
          await container.read(recentActivityProvider.future);

      // Top 3 by createdAt desc: j-new (8:55) > ap-1 (8:30) > dose (8:05).
      // The 6:00 journal entry and the unlogged 20:00 dose fall away.
      expect(
        feed.map((RecentActivityItem i) => i.id).toList(),
        <String>['journal-j-new', 'appointment-ap-1', 'dose-m-1-'
            '${DateTime(2026, 6, 1, 8, 0).millisecondsSinceEpoch}'],
      );
      expect(feed.first.summary, 'Wandering');
      expect(
        feed.any((RecentActivityItem i) => i.summary.contains('Metformin')),
        isFalse,
      );

      await storage.dispose();
    });
  });
}
