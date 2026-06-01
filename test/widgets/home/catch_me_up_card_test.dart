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
import 'package:careblazers/providers/llm_provider.dart';
import 'package:careblazers/providers/storage_provider.dart';
import 'package:careblazers/screens/medication/dose_log_screen.dart'
    show dosesTodayProvider;
import 'package:careblazers/services/appointment_repository.dart';
import 'package:careblazers/services/medication_repository.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/home/catch_me_up_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
// `Provider` (the model) collides with riverpod's `Provider`; `hide` keeps
// the model name resolvable in the fixtures.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

/// Fixed "now": 9 AM on Mon Jun 1 2026.
DateTime _fixedNow() => DateTime(2026, 6, 1, 9, 0);

/// A small, deterministic event set the cache key is derived from.
final List<ActivityEvent> _events = <ActivityEvent>[
  ActivityEvent(
    kind: ActivityEventKind.journal,
    summary: 'Sundowning',
    occurredAt: DateTime(2026, 6, 1, 8, 40),
  ),
  ActivityEvent(
    kind: ActivityEventKind.dose,
    summary: 'Gave Donepezil 10 mg',
    occurredAt: DateTime(2026, 6, 1, 7, 30),
  ),
];

/// LLM impl that records how many times the summary stream is requested,
/// so a cache hit can assert "the provider was never invoked". Streams a
/// single fixed accumulation so a regeneration is distinguishable from a
/// cached copy.
class _RecordingLLM implements LLMProvider {
  int summaryCalls = 0;

  static const String generated = 'A freshly generated recap of your day.';

  @override
  Stream<String> generateActivitySummary({
    int lastNHours = 24,
    required List<ActivityEvent> events,
  }) async* {
    summaryCalls++;
    yield generated;
  }

  @override
  Stream<DecoderChunk> generateDecoderScript({
    required Behavior behavior,
    required TriageAnswers triage,
    required PatientContext patient,
    required int attempt,
  }) {
    throw UnimplementedError('not used in these tests');
  }
}

ProviderContainer _container(_RecordingLLM llm) {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      homeClockProvider.overrideWithValue(_fixedNow),
      catchMeUpEventsProvider.overrideWith((Ref ref) async => _events),
      llmProvider.overrideWithValue(llm),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The exact prefs key the notifier will compute for [_events] at the
/// fixed clock.
String get _key => catchMeUpCacheKey(_fixedNow(), catchMeUpEventsHash(_events));

String _cachePayload(String summary, DateTime generatedAt) => json.encode(
      <String, String>{
        'summary': summary,
        'generatedAt': generatedAt.toIso8601String(),
      },
    );

void main() {
  group('CatchMeUp — generation + caching (Phase 14.12)', () {
    test('with no cache, generates a summary and writes it to prefs',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _RecordingLLM llm = _RecordingLLM();
      final ProviderContainer container = _container(llm);

      final String summary = await container.read(catchMeUpProvider.future);

      expect(summary, _RecordingLLM.generated);
      expect(llm.summaryCalls, 1);

      // The result was persisted under the day+hash key for next open.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      expect(raw, isNotNull);
      final Map<String, dynamic> stored =
          json.decode(raw!) as Map<String, dynamic>;
      expect(stored['summary'], _RecordingLLM.generated);
    });

    test('cache hit returns the stored copy without invoking the provider',
        () async {
      const String cached = 'A previously cached recap.';
      SharedPreferences.setMockInitialValues(<String, Object>{
        // Fresh stamp — 5 minutes old, inside the 30-minute TTL.
        _key: _cachePayload(
          cached,
          _fixedNow().subtract(const Duration(minutes: 5)),
        ),
      });
      final _RecordingLLM llm = _RecordingLLM();
      final ProviderContainer container = _container(llm);

      final String summary = await container.read(catchMeUpProvider.future);

      expect(summary, cached);
      expect(llm.summaryCalls, 0, reason: 'cache hit must not call the LLM');
    });

    test('expired cache regenerates a fresh summary', () async {
      const String stale = 'A stale recap from an hour ago.';
      SharedPreferences.setMockInitialValues(<String, Object>{
        // 31 minutes old — just past the 30-minute TTL.
        _key: _cachePayload(
          stale,
          _fixedNow().subtract(const Duration(minutes: 31)),
        ),
      });
      final _RecordingLLM llm = _RecordingLLM();
      final ProviderContainer container = _container(llm);

      final String summary = await container.read(catchMeUpProvider.future);

      expect(summary, _RecordingLLM.generated);
      expect(llm.summaryCalls, 1, reason: 'expired cache must regenerate');

      // And the fresh copy overwrote the stale entry.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> stored =
          json.decode(prefs.getString(_key)!) as Map<String, dynamic>;
      expect(stored['summary'], _RecordingLLM.generated);
    });

    test('regenerate() bypasses a fresh cache and re-streams', () async {
      const String cached = 'A fresh cached recap.';
      SharedPreferences.setMockInitialValues(<String, Object>{
        _key: _cachePayload(cached, _fixedNow()),
      });
      final _RecordingLLM llm = _RecordingLLM();
      final ProviderContainer container = _container(llm);

      // First read hits the fresh cache — no generation.
      expect(await container.read(catchMeUpProvider.future), cached);
      expect(llm.summaryCalls, 0);

      await container.read(catchMeUpProvider.notifier).regenerate();

      expect(container.read(catchMeUpProvider).value, _RecordingLLM.generated);
      expect(llm.summaryCalls, 1, reason: 'refresh must force a generation');
    });

    test('an empty event set yields an empty recap and skips the provider',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _RecordingLLM llm = _RecordingLLM();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          homeClockProvider.overrideWithValue(_fixedNow),
          catchMeUpEventsProvider
              .overrideWith((Ref ref) async => const <ActivityEvent>[]),
          llmProvider.overrideWithValue(llm),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(catchMeUpProvider.future), '');
      expect(llm.summaryCalls, 0);
    });
  });

  group('CatchMeUpCard — render states (Phase 14.12)', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      required List<Override> overrides,
    }) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            homeClockProvider.overrideWithValue(_fixedNow),
            ...overrides,
          ],
          child: MaterialApp(
            theme: careblazersLightTheme,
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: CatchMeUpCard(),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows a skeleton while the recap streams, then the paragraph',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _RecordingLLM llm = _RecordingLLM();
      await pumpCard(tester, overrides: <Override>[
        catchMeUpEventsProvider.overrideWith((Ref ref) async => _events),
        llmProvider.overrideWithValue(llm),
      ]);

      // First frame (pumpWidget settles one frame): the async recap is
      // still resolving, so the skeleton is shown.
      expect(find.byKey(CatchMeUpCard.skeletonKey), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(CatchMeUpCard.skeletonKey), findsNothing);
      expect(find.byKey(CatchMeUpCard.summaryKey), findsOneWidget);
      expect(find.text(_RecordingLLM.generated), findsOneWidget);
    });

    testWidgets('tapping refresh re-streams the recap',
        (WidgetTester tester) async {
      // Seed a fresh cache so the first resolve is a cache hit (no LLM
      // call), then the refresh tap forces a generation.
      SharedPreferences.setMockInitialValues(<String, Object>{
        _key: _cachePayload('Cached copy.', _fixedNow()),
      });
      final _RecordingLLM llm = _RecordingLLM();
      await pumpCard(tester, overrides: <Override>[
        catchMeUpEventsProvider.overrideWith((Ref ref) async => _events),
        llmProvider.overrideWithValue(llm),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Cached copy.'), findsOneWidget);
      expect(llm.summaryCalls, 0);

      await tester.tap(find.byKey(CatchMeUpCard.refreshKey));
      await tester.pumpAndSettle();

      expect(find.text(_RecordingLLM.generated), findsOneWidget);
      expect(llm.summaryCalls, 1);
    });

    testWidgets('collapses to nothing when there is nothing to recap',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await pumpCard(tester, overrides: <Override>[
        catchMeUpEventsProvider
            .overrideWith((Ref ref) async => const <ActivityEvent>[]),
        llmProvider.overrideWithValue(_RecordingLLM()),
      ]);
      await tester.pumpAndSettle();

      expect(find.byKey(CatchMeUpCard.cardKey), findsNothing);
      expect(find.byKey(CatchMeUpCard.summaryKey), findsNothing);
    });

    testWidgets('a resolution failure shows a muted line, not a red box',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await pumpCard(tester, overrides: <Override>[
        catchMeUpEventsProvider.overrideWith(
          (Ref ref) async => throw StateError('boom'),
        ),
        llmProvider.overrideWithValue(_RecordingLLM()),
      ]);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.text("We couldn't put together your recap just now."),
        findsOneWidget,
      );
    });
  });

  group('catchMeUpCacheKey — shape (Phase 14.12)', () {
    test('is home.catch_me_up.<yyyyMMdd>.<hash>', () {
      final String key =
          catchMeUpCacheKey(DateTime(2026, 6, 1, 9), catchMeUpEventsHash(_events));
      expect(key, startsWith('home.catch_me_up.20260601.'));
    });

    test('the event hash is stable across calls (cache survives reopen)', () {
      expect(catchMeUpEventsHash(_events), catchMeUpEventsHash(_events));
    });

    test('a changed event set busts the hash', () {
      final List<ActivityEvent> other = <ActivityEvent>[
        ..._events,
        ActivityEvent(
          kind: ActivityEventKind.appointment,
          summary: 'Appointment with Dr. Ortega',
          occurredAt: DateTime(2026, 6, 1, 8),
        ),
      ];
      expect(catchMeUpEventsHash(_events), isNot(catchMeUpEventsHash(other)));
    });
  });

  group('catchMeUpEventsProvider — aggregation (Phase 14.12)', () {
    Future<void> seedProvider(CareblazersDatabase db, Provider p) async {
      await db.into(db.providersTable).insertOnConflictUpdate(
            ProvidersTableCompanion.insert(
              id: p.id,
              name: p.name,
              payload: jsonEncode(p.toJson()),
            ),
          );
    }

    testWidgets(
        'pulls the last 24h across journal + dose + appointment, '
        'dropping older and unlogged events', (WidgetTester tester) async {
      final InMemoryStorageProvider storage = InMemoryStorageProvider();
      // Decoder auto-log inside the window → behavior label.
      await storage.insertJournalEntry(_decoderEntry(
        id: 'j-decoder',
        createdAt: DateTime(2026, 6, 1, 8, 40),
        behavior:
            const Behavior(id: 'wandering', label: 'Wandering', glyph: '🚶'),
      ));
      // Wizard entry inside the window → caregiver's own situation text.
      await storage.insertJournalEntry(JournalEntry.wizard(
        id: 'j-wizard',
        createdAt: DateTime(2026, 6, 1, 7, 0),
        situationText: 'She kept asking to go home',
      ));
      // Older than 24h → must be filtered out.
      await storage.insertJournalEntry(_decoderEntry(
        id: 'j-stale',
        createdAt: DateTime(2026, 5, 30, 8, 0),
        behavior:
            const Behavior(id: 'upset', label: 'Upset / crying', glyph: '💔'),
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
        startsAt: DateTime(2026, 6, 1, 12, 0),
        durationMinutes: 30,
        location: 'Clinic',
        agenda: const <String>[],
        status: AppointmentStatus.upcoming,
      ));

      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          homeClockProvider.overrideWithValue(_fixedNow),
          storageBackendProvider.overrideWithValue(storage),
          appointmentRepositoryBackendProvider.overrideWithValue(apptRepo),
          dosesTodayProvider.overrideWith(
            (ref) async => <ScheduledDose>[
              _dose(
                medId: 'm-taken',
                name: 'Donepezil',
                scheduledFor: DateTime(2026, 6, 1, 8, 0),
                status: DoseStatus.taken,
                takenAt: DateTime(2026, 6, 1, 8, 5),
              ),
              _dose(
                medId: 'm-skipped',
                name: 'Memantine',
                scheduledFor: DateTime(2026, 6, 1, 8, 30),
                status: DoseStatus.skipped,
                takenAt: DateTime(2026, 6, 1, 8, 30),
              ),
              _dose(
                medId: 'm-missed',
                name: 'Aspirin',
                scheduledFor: DateTime(2026, 6, 1, 7, 30),
                status: DoseStatus.missed,
              ),
              // Unlogged upcoming dose — not yet "activity".
              _dose(
                medId: 'm-pending',
                name: 'Metformin',
                scheduledFor: DateTime(2026, 6, 1, 20, 0),
              ),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);

      // Keep the autoDispose provider + its stream-backed journal
      // dependency mounted while we await the first value.
      container.listen<AsyncValue<List<ActivityEvent>>>(
        catchMeUpEventsProvider,
        (AsyncValue<List<ActivityEvent>>? _,
            AsyncValue<List<ActivityEvent>> __) {},
      );

      final List<ActivityEvent> events =
          await container.read(catchMeUpEventsProvider.future);

      final List<String> summaries =
          events.map((ActivityEvent e) => e.summary).toList();

      // Journal: decoder label + wizard situation text; stale dropped.
      expect(summaries, contains('Wandering'));
      expect(summaries, contains('She kept asking to go home'));
      expect(summaries, isNot(contains('Upset / crying')));
      // Dose verbs across all three logged statuses; unlogged dropped.
      expect(summaries, contains('Gave Donepezil 10 mg'));
      expect(summaries, contains('Skipped Memantine 10 mg'));
      expect(summaries, contains('Missed Aspirin 10 mg'));
      expect(
        summaries.any((String s) => s.contains('Metformin')),
        isFalse,
      );
      // Appointment with the resolved provider name.
      expect(summaries, contains('Appointment with Dr. Ortega'));

      // Sorted ascending by occurredAt so the cache hash is stable.
      for (int i = 1; i < events.length; i++) {
        expect(
          events[i].occurredAt.isBefore(events[i - 1].occurredAt),
          isFalse,
        );
      }

      await storage.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// Fixture builders
// ---------------------------------------------------------------------------

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
