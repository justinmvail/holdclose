import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../db/database.dart';
import '../models/appointment.dart';
import '../models/care_circle_membership.dart';
import '../models/care_event.dart';
import '../models/care_plan_routine.dart';
import '../models/care_shift.dart';
import '../models/care_task.dart';
import '../models/caregiver.dart';
import '../models/chat.dart';
import '../models/document.dart';
import '../models/expense.dart';
import '../models/forum.dart';
import '../models/health_log_entry.dart';
import '../models/journal_entry.dart';
import '../models/medication.dart';
import '../models/patient.dart';
import '../providers/care_circle_provider.dart';
import '../providers/care_events_provider.dart';
import '../providers/care_plan_provider.dart';
import '../providers/care_shifts_provider.dart';
import '../providers/care_tasks_provider.dart';
import '../providers/documents_provider.dart';
import '../providers/expenses_provider.dart';
import '../providers/health_log_provider.dart';
import '../providers/storage_provider.dart';
import '../providers/sync_state_provider.dart';
import 'appointment_repository.dart';
import 'chat_repository.dart';
import 'forum_api_client.dart';
import 'medication_repository.dart';
import 'provider_repository.dart';
import 'sync_sink.dart';

part 'sync_service.g.dart';

/// Sync collection names — the `collection` discriminator on every
/// [SyncDoc] / outbox row (server-authoritative sync). Centralized so the
/// enqueue seam (the medication repository sync sink) and the apply
/// dispatcher agree on one spelling.
class SyncCollections {
  static const String patient = 'patient';
  static const String medication = 'medication';
  static const String doseWindow = 'dose_window';
  static const String medicationWindowEntry = 'medication_window_entry';
  static const String doseLog = 'dose_log';
  // Batch 1 — wired end-to-end (sink + guard + enqueue + apply case).
  static const String journalEntry = 'journal_entries';
  static const String chatConversation = 'chat_conversations';
  static const String chatMessage = 'chat_messages';
  static const String appointment = 'appointments';
  static const String provider = 'providers';
  static const String healthLogEntry = 'health_log_entries';
  // Batch 2 — wired end-to-end (sink + guard + enqueue + apply case).
  static const String carePlanRoutine = 'care_plan_routines';
  static const String careEvent = 'care_events';
  static const String careTask = 'care_tasks';
  static const String careShift = 'care_shifts';
  static const String expense = 'expenses';
  static const String caregiver = 'caregivers';
  static const String careCircleMembership = 'care_circle_memberships';
  static const String emergencyCard = 'emergency_cards';
  static const String powerOfAttorneyDoc = 'power_of_attorney_docs';
  static const String identificationDoc = 'identification_docs';
}

/// How many outbox rows a single `push()` drains per round-trip.
const int _syncPushBatch = 200;

/// Durable repository over the [SyncOutboxTable] (server-authoritative
/// sync). Plain CRUD plus a coalescing [enqueue] that keeps the queue
/// bounded: a newer enqueue for the same (collection, docId) deletes the
/// older pending row first, so a chatty screen leaves one pending row per
/// doc, not a row per keystroke.
class SyncOutbox {
  SyncOutbox(this._db);

  final CareblazersDatabase _db;

  /// Append a pending write, replacing any earlier pending row for the
  /// same (collection, docId) so the latest value wins.
  Future<void> enqueue({
    required String collection,
    required String docId,
    required Map<String, dynamic> payload,
    required int clientUpdatedAt,
    required bool deleted,
  }) async {
    await _db.transaction(() async {
      await (_db.delete(_db.syncOutboxTable)
            ..where((t) =>
                t.collection.equals(collection) & t.docId.equals(docId)))
          .go();
      await _db.into(_db.syncOutboxTable).insert(
            SyncOutboxTableCompanion.insert(
              collection: collection,
              docId: docId,
              payload: jsonEncode(payload),
              clientUpdatedAt: clientUpdatedAt,
              deleted: deleted ? 1 : 0,
            ),
          );
    });
  }

  /// True when there's an unpushed local write queued for this
  /// (collection, docId). The sync apply path consults this so a pulled
  /// (possibly older) copy never clobbers a local change that hasn't reached
  /// the server yet — the next push sends our value and the server resolves
  /// last-write-wins.
  Future<bool> hasPending(String collection, String docId) async {
    final SyncOutboxTableData? row = await (_db.select(_db.syncOutboxTable)
          ..where((t) =>
              t.collection.equals(collection) & t.docId.equals(docId))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// The oldest [limit] pending rows, ascending by seq.
  Future<List<SyncOutboxTableData>> listPending({int limit = _syncPushBatch}) {
    return (_db.select(_db.syncOutboxTable)
          ..orderBy(<OrderClauseGenerator<$SyncOutboxTableTable>>[
            (t) => OrderingTerm(expression: t.seq, mode: OrderingMode.asc),
          ])
          ..limit(limit))
        .get();
  }

  /// Delete the rows with these exact seqs (the batch the server accepted).
  Future<void> deleteSeqs(List<int> seqs) async {
    if (seqs.isEmpty) return;
    await (_db.delete(_db.syncOutboxTable)..where((t) => t.seq.isIn(seqs)))
        .go();
  }
}

/// Server-authoritative sync engine (server-authoritative sync).
///
/// **Fail-safe + additive.** Every method is a no-op when there's no
/// active circle, and every network call is wrapped so a failure queues
/// or no-ops — it never throws to the UI or to bootstrap. The app behaves
/// exactly as it does today (fully local) until an install joins/creates
/// a circle.
///
/// Drains a durable outbox to the backend ([push]), pulls + applies
/// remote changes via a per-collection apply dispatcher ([pull]), and
/// guards against an echo loop: applying a pulled doc writes straight to
/// the local repo/storage, never back through [enqueueUpsert].
class SyncController {
  SyncController({
    required SyncOutbox outbox,
    required ForumApiClient client,
    required SyncStateStore stateStore,
    required StorageProvider storage,
    required MedicationRepository medications,
    required ChatRepository chat,
    required AppointmentRepository appointments,
    required ProviderRepository providers,
    required HealthLogRepository healthLog,
    required CarePlanRepository carePlan,
    required CareEventsRepository careEvents,
    required CareTasksRepository careTasks,
    required CareShiftsRepository careShifts,
    required ExpensesRepository expenses,
    required CareCircleRepository careCircle,
    required DocumentsRepository documents,
    DateTime Function()? clock,
  })  : _outbox = outbox,
        _client = client,
        _stateStore = stateStore,
        _storage = storage,
        _medications = medications,
        _chat = chat,
        _appointments = appointments,
        _providers = providers,
        _healthLog = healthLog,
        _carePlan = carePlan,
        _careEvents = careEvents,
        _careTasks = careTasks,
        _careShifts = careShifts,
        _expenses = expenses,
        _careCircle = careCircle,
        _documents = documents,
        _clock = clock ?? DateTime.now;

  final SyncOutbox _outbox;
  final ForumApiClient _client;
  final SyncStateStore _stateStore;
  final StorageProvider _storage;
  final MedicationRepository _medications;
  final ChatRepository _chat;
  final AppointmentRepository _appointments;
  final ProviderRepository _providers;
  final HealthLogRepository _healthLog;
  final CarePlanRepository _carePlan;
  final CareEventsRepository _careEvents;
  final CareTasksRepository _careTasks;
  final CareShiftsRepository _careShifts;
  final ExpensesRepository _expenses;
  final CareCircleRepository _careCircle;
  final DocumentsRepository _documents;
  final DateTime Function() _clock;

  Future<void>? _inFlight;
  Timer? _debounce;
  Timer? _interval;

  /// How long after a local write we wait (debounced) before firing a
  /// sync, so a burst of writes coalesces into one round-trip.
  static const Duration _writeDebounce = Duration(seconds: 2);

  /// How often a foregrounded app polls for remote changes.
  static const Duration _pollInterval = Duration(seconds: 30);

  /// Enqueue a local upsert for [collection]/[id] with the model's
  /// [json]. **No-op when no circle is active** — the write already
  /// landed locally; there's just nothing to sync to.
  Future<void> enqueueUpsert(
    String collection,
    String id,
    Map<String, dynamic> json,
  ) async {
    if (await _circleId() == null) return;
    await _outbox.enqueue(
      collection: collection,
      docId: id,
      payload: json,
      clientUpdatedAt: _clock().millisecondsSinceEpoch,
      deleted: false,
    );
  }

  /// Enqueue a tombstone delete for [collection]/[id]. No-op without an
  /// active circle.
  Future<void> enqueueDelete(String collection, String id) async {
    if (await _circleId() == null) return;
    await _outbox.enqueue(
      collection: collection,
      docId: id,
      payload: const <String, dynamic>{},
      clientUpdatedAt: _clock().millisecondsSinceEpoch,
      deleted: true,
    );
  }

  /// Force-enqueue EVERY local row across every collection (and push the
  /// patient), then sync. Recovers data that was written to the local DB
  /// while no circle was bound — e.g. the demo seed, which runs before sync
  /// bootstraps the circle, so its writes never hit the outbox. One-shot,
  /// idempotent at the server (LWW by id). No circle → no-op.
  Future<void> resyncAllLocal() async {
    final String? circleId = await _circleId();
    if (circleId == null) return;

    Future<void> enq(String c, String id, Map<String, dynamic> j) =>
        enqueueUpsert(c, id, j);

    for (final JournalEntry e in await _storage.listAllJournalEntries()) {
      await enq(SyncCollections.journalEntry, e.id, e.toJson());
    }

    final List<Medication> meds = await _medications.listMedications();
    for (final Medication m in meds) {
      await enq(SyncCollections.medication, m.id, m.toJson());
    }
    final Patient? patient = await _storage.getPatient();
    if (patient != null) {
      for (final DoseWindow w
          in await _medications.windowsForPatient(patient.id)) {
        await enq(SyncCollections.doseWindow, w.id, w.toJson());
        for (final MedicationWindowEntry me
            in await _medications.entriesForWindow(w.id)) {
          await enq(SyncCollections.medicationWindowEntry, me.id, me.toJson());
        }
      }
    }
    for (final Medication m in meds) {
      for (final DoseLog l in await _medications.logsFor(m.id)) {
        await enq(SyncCollections.doseLog, l.id, l.toJson());
      }
    }

    for (final Appointment a in await _appointments.listAppointments()) {
      await enq(SyncCollections.appointment, a.id, a.toJson());
    }
    for (final Provider p in await _providers.listProviders()) {
      await enq(SyncCollections.provider, p.id, p.toJson());
    }
    for (final HealthLogEntry h in await _healthLog.listAll()) {
      await enq(SyncCollections.healthLogEntry, h.id, h.toJson());
    }
    for (final CarePlanRoutine r in await _carePlan.listAll()) {
      await enq(SyncCollections.carePlanRoutine, r.id, r.toJson());
    }
    for (final CareEvent ev in await _careEvents.listEvents()) {
      await enq(SyncCollections.careEvent, ev.id, ev.toJson());
    }
    for (final CareTask t in await _careTasks.listTasks()) {
      await enq(SyncCollections.careTask, t.id, t.toJson());
    }
    for (final CareShift s in await _careShifts.listShifts()) {
      await enq(SyncCollections.careShift, s.id, s.toJson());
    }
    for (final Expense x in await _expenses.listExpenses()) {
      await enq(SyncCollections.expense, x.id, x.toJson());
    }
    for (final Caregiver cg in await _careCircle.listCaregivers()) {
      await enq(SyncCollections.caregiver, cg.id, cg.toJson());
    }
    for (final CareCircleMembership mem in await _careCircle.listMemberships()) {
      await enq(SyncCollections.careCircleMembership, mem.id, mem.toJson());
    }
    for (final EmergencyCard c in await _documents.listEmergencyCards()) {
      await enq(SyncCollections.emergencyCard, c.id, c.toJson());
    }
    for (final PowerOfAttorneyDoc d in await _documents.listPoa()) {
      await enq(SyncCollections.powerOfAttorneyDoc, d.id, d.toJson());
    }
    for (final IdentificationDoc d in await _documents.listIds()) {
      await enq(SyncCollections.identificationDoc, d.id, d.toJson());
    }
    for (final Conversation conv in await _chat.listConversations()) {
      await enq(SyncCollections.chatConversation, conv.id, conv.toJson());
      for (final Message msg in await _chat.loadMessages(conv.id)) {
        await enq(SyncCollections.chatMessage, msg.id, msg.toJson());
      }
    }

    // The patient is pushed via the dedicated `patient` field, not the outbox.
    if (patient != null) {
      try {
        await _client.syncPush(
          circleId,
          patient: SyncPatientWrite(
            payload: patient.toJson(),
            clientUpdatedAt: _clock().millisecondsSinceEpoch,
            deleted: false,
          ),
          docs: const <SyncDocWrite>[],
        );
      } catch (_) {
        // Best-effort; the docs still drain below.
      }
    }

    // Drain the ENTIRE outbox in this run — push() only sends one batch
    // (_syncPushBatch) at a time, and a one-shot resync can't rely on the 30s
    // interval (the app may background right after launch). Loop until empty
    // (capped well above any real dataset), then pull once.
    for (int i = 0; i < 100; i++) {
      await push();
      if ((await _outbox.listPending(limit: 1)).isEmpty) break;
    }
    await pull();
  }

  /// Drain the outbox to the backend. No circle → return. Network failure
  /// → swallow, leaving the batch queued for the next attempt.
  Future<void> push() async {
    final String? circleId = await _circleId();
    if (circleId == null) return;
    try {
      final List<SyncOutboxTableData> pending =
          await _outbox.listPending(limit: _syncPushBatch);
      if (pending.isEmpty) return;
      final List<SyncDocWrite> docs = pending
          .map((SyncOutboxTableData r) => SyncDocWrite(
                id: r.docId,
                collection: r.collection,
                payload:
                    jsonDecode(r.payload) as Map<String, dynamic>,
                clientUpdatedAt: r.clientUpdatedAt,
                deleted: r.deleted != 0,
              ))
          .toList(growable: false);
      await _client.syncPush(circleId, docs: docs);
      // The server applies LWW; whether each doc was accepted or rejected
      // as stale, it has now seen our value, so drop the whole batch from
      // the outbox. (A rejected-as-stale doc means the server already holds
      // a newer value we'll get on the next pull.)
      await _outbox.deleteSeqs(
        pending.map((SyncOutboxTableData r) => r.seq).toList(growable: false),
      );
    } catch (_) {
      // Offline / backend unreachable / token error — leave queued.
    }
  }

  /// Pull remote changes since the stored cursor and apply them locally.
  /// No circle → return. Network failure → swallow.
  Future<void> pull() async {
    final String? circleId = await _circleId();
    if (circleId == null) return;
    try {
      final int since = await _stateStore.getCursor(circleId);
      final SyncPullResult result =
          await _client.syncPull(circleId, since: since);
      if (result.patient != null) {
        await _applyPatient(result.patient!);
      }
      for (final SyncDoc doc in result.docs) {
        await _applyDoc(doc);
      }
      await _stateStore.setCursor(circleId, result.cursor);
    } catch (_) {
      // Offline / backend unreachable — try again next tick.
    }
  }

  /// push() then pull(). Serialized so overlapping triggers (start +
  /// resume + interval + post-write debounce) don't stampede the backend.
  Future<void> syncNow() {
    final Future<void>? running = _inFlight;
    if (running != null) return running;
    final Future<void> run = () async {
      try {
        await push();
        await pull();
      } finally {
        _inFlight = null;
      }
    }();
    _inFlight = run;
    return run;
  }

  Future<String?> _circleId() => _stateStore.getCircleId();

  // ─────────────────────────────────────────── Bootstrap ──

  /// Resolve the active circle on launch (server-authoritative sync).
  /// Entirely best-effort + fail-safe — every branch swallows errors so a
  /// backend that's unreachable (or absent) leaves the app local-only,
  /// exactly as it behaves today.
  ///
  /// 1. If a circle id is already stored, nothing to do.
  /// 2. Else if the backend lists ≥1 circle, adopt the first (a returning
  ///    install whose circle id was never persisted, or a fresh device
  ///    that already belongs to circles).
  /// 3. Else if there's a local patient but no circle, create a circle
  ///    that owns them — this retries the onboarding circle-creation that
  ///    may have failed offline.
  Future<void> bootstrapCircle() async {
    try {
      if (await _stateStore.getCircleId() != null) return;

      // (2) Adopt an existing circle if the backend knows of any.
      try {
        final List<CircleDto> circles = await _client.listCircles();
        if (circles.isNotEmpty) {
          final CircleDto first = circles.first;
          await _stateStore.setCircleId(first.id);
          if (first.patient != null) {
            await _applyPatient(first.patient!);
          }
          await _stateStore.setCursor(
            first.id,
            first.patient?.rev ?? 0,
          );
          return;
        }
      } catch (_) {
        // Backend unreachable/unconfigured — fall through to local-only.
        // Don't attempt circle creation when we couldn't even list, to
        // avoid spuriously minting a duplicate circle on a flaky network.
        return;
      }

      // (3) Local patient but no circle anywhere → create one for them.
      await ensureCircleForActivePatient();
    } catch (_) {
      // Never let bootstrap throw — local-only is the safe default.
    }
  }

  /// Create a backend circle owning the active local patient when there's
  /// a patient on file but no circle id yet (server-authoritative sync).
  /// Best-effort: a failure leaves the app local-only and the next
  /// bootstrap retries. No-op when there's no patient or a circle already
  /// exists.
  Future<void> ensureCircleForActivePatient() async {
    try {
      if (await _stateStore.getCircleId() != null) return;
      final Patient? patient = await _storage.getPatient();
      if (patient == null) return;
      final CircleDto circle = await _client.createCircle(
        "${patient.name}'s circle",
        patient: SyncPatientWrite(
          payload: patient.toJson(),
          clientUpdatedAt: _clock().millisecondsSinceEpoch,
        ),
      );
      await _stateStore.setCircleId(circle.id);
      await _stateStore.setCursor(circle.id, circle.patient?.rev ?? 0);
    } catch (_) {
      // Offline / no backend — stay local-only; retried next bootstrap.
    }
  }

  /// Adopt the circle a joiner just joined (server-authoritative sync):
  /// write its shared loved one locally + make them active, bind the
  /// circle id + cursor, then pull the rest of the shared data. Called
  /// from the QR/username join paths after `joinCircle` succeeds.
  /// Best-effort; a failure leaves the join's local state intact.
  Future<void> adoptJoinedCircle(CircleDto circle) async {
    try {
      await _stateStore.setCircleId(circle.id);
      int cursor = 0;
      final SyncPatient? p = circle.patient;
      if (p != null && !p.deleted && p.payload.isNotEmpty) {
        final Patient parsed = Patient.fromJson(
          jsonDecode(p.payload) as Map<String, dynamic>,
        );
        await _storage.upsertPatient(parsed);
        await _storage.setActivePatientId(parsed.id);
        cursor = p.rev;
      }
      await _stateStore.setCursor(circle.id, cursor);
      await pull();
    } catch (_) {
      // Local patient (if any) already saved by the join path — safe.
    }
  }

  // ─────────────────────────────────────────── Scheduling ──

  /// Start the foreground poll timer (~every 30s). Idempotent — calling
  /// it twice doesn't double up. Each tick fire-and-forgets a [syncNow];
  /// the no-circle guard makes it free when local-only.
  void startInterval() {
    _interval?.cancel();
    _interval = Timer.periodic(_pollInterval, (_) {
      unawaited(syncNow());
    });
  }

  /// Debounced post-write sync. A burst of local writes collapses to one
  /// round-trip [_writeDebounce] after the last one.
  void scheduleSyncAfterWrite() {
    _debounce?.cancel();
    _debounce = Timer(_writeDebounce, () {
      unawaited(syncNow());
    });
  }

  /// Called on `AppLifecycleState.resumed` — push anything queued while
  /// backgrounded + pull fresh changes.
  void onAppResumed() {
    unawaited(syncNow());
  }

  /// Cancel timers. Wired to the provider's `ref.onDispose`.
  void dispose() {
    _debounce?.cancel();
    _interval?.cancel();
  }

  // ─────────────────────────────────────────── Apply dispatcher ──

  /// Route a pulled [SyncDoc] to the matching local repo write
  /// (server-authoritative sync). Honors tombstones (`deleted: true` →
  /// local delete). Unknown collections are ignored (forward-compat).
  ///
  /// These writes go STRAIGHT to the local repo — never through
  /// [enqueueUpsert] — so applying a pulled doc can't re-enqueue it and
  /// bounce back to the server (the echo-loop guard).
  Future<void> _applyDoc(SyncDoc doc) async {
    // Local-first conflict guard: if there's an UNPUSHED local write for this
    // doc still in the outbox, that local change is authoritative until it
    // reaches the server — don't let a pulled (older) copy clobber it. The
    // next push sends our value and the server resolves last-write-wins. This
    // closes the window where a pull lands between a local edit and its push.
    if (await _outbox.hasPending(doc.collection, doc.id)) return;
    final Map<String, dynamic> payload = doc.payload.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(doc.payload) as Map<String, dynamic>;
    // Medication-family writes run inside applyingRemote so the repo's
    // sync sink is suppressed — applying a pulled doc must not re-enqueue
    // it (the echo-loop guard). The patient write bypasses the repo
    // entirely, so it needs no guard.
    switch (doc.collection) {
      case SyncCollections.patient:
        if (doc.deleted) return; // patient tombstones handled via _applyPatient
        await _storage.upsertPatient(Patient.fromJson(payload));
      case SyncCollections.medication:
        await _medications.applyingRemote(() async {
          if (doc.deleted) {
            await _medications.deleteMedication(doc.id);
          } else {
            await _medications.upsertMedication(Medication.fromJson(payload));
          }
        });
      case SyncCollections.doseWindow:
        await _medications.applyingRemote(() async {
          if (doc.deleted) {
            await _medications.deleteWindow(doc.id);
          } else {
            await _medications.upsertWindow(DoseWindow.fromJson(payload));
          }
        });
      case SyncCollections.medicationWindowEntry:
        await _medications.applyingRemote(() async {
          if (doc.deleted) {
            await _medications.deleteEntry(doc.id);
          } else {
            await _medications
                .upsertEntry(MedicationWindowEntry.fromJson(payload));
          }
        });
      case SyncCollections.doseLog:
        await _medications.applyingRemote(() async {
          if (doc.deleted) {
            await _medications.deleteDoseLog(doc.id);
          } else {
            await _medications.upsertDoseLog(DoseLog.fromJson(payload));
          }
        });
      case SyncCollections.journalEntry:
        await _storage.applyingRemote(() async {
          if (doc.deleted) {
            await _storage.deleteJournalEntry(doc.id);
          } else {
            // insertJournalEntry is insert-or-replace (upsert by id) in
            // both storage impls, so it doubles as the remote-apply path.
            await _storage.insertJournalEntry(JournalEntry.fromJson(payload));
          }
        });
      case SyncCollections.chatConversation:
        await _chat.applyingRemote(() async {
          if (doc.deleted) {
            await _chat.deleteConversation(doc.id);
          } else {
            final Conversation convo = Conversation.fromJson(payload);
            // createConversation is insert-or-replace by id, so re-running
            // it applies a remote conversation upsert. Preserve the remote
            // updatedAt by writing the parsed model's timestamp.
            await _chat.applyConversation(convo);
          }
        });
      case SyncCollections.chatMessage:
        await _chat.applyingRemote(() async {
          if (doc.deleted) {
            await _chat.deleteMessage(doc.id);
          } else {
            await _chat.appendMessage(Message.fromJson(payload));
          }
        });
      case SyncCollections.appointment:
        await _appointments.applyingRemote(() async {
          if (doc.deleted) {
            await _appointments.deleteAppointment(doc.id);
          } else {
            await _appointments
                .upsertAppointment(Appointment.fromJson(payload));
          }
        });
      case SyncCollections.provider:
        await _providers.applyingRemote(() async {
          if (doc.deleted) {
            await _providers.deleteProvider(doc.id);
          } else {
            await _providers.upsertProvider(Provider.fromJson(payload));
          }
        });
      case SyncCollections.healthLogEntry:
        await _healthLog.applyingRemote(() async {
          if (doc.deleted) {
            await _healthLog.delete(doc.id);
          } else {
            await _healthLog.upsert(HealthLogEntry.fromJson(payload));
          }
        });
      case SyncCollections.carePlanRoutine:
        await _carePlan.applyingRemote(() async {
          if (doc.deleted) {
            await _carePlan.delete(doc.id);
          } else {
            await _carePlan.upsert(CarePlanRoutine.fromJson(payload));
          }
        });
      case SyncCollections.careEvent:
        await _careEvents.applyingRemote(() async {
          if (doc.deleted) {
            await _careEvents.deleteEvent(doc.id);
          } else {
            await _careEvents.upsertEvent(CareEvent.fromJson(payload));
          }
        });
      case SyncCollections.careTask:
        await _careTasks.applyingRemote(() async {
          if (doc.deleted) {
            await _careTasks.deleteTask(doc.id);
          } else {
            await _careTasks.upsertTask(CareTask.fromJson(payload));
          }
        });
      case SyncCollections.careShift:
        await _careShifts.applyingRemote(() async {
          if (doc.deleted) {
            await _careShifts.deleteShift(doc.id);
          } else {
            await _careShifts.upsertShift(CareShift.fromJson(payload));
          }
        });
      case SyncCollections.expense:
        await _expenses.applyingRemote(() async {
          if (doc.deleted) {
            await _expenses.deleteExpense(doc.id);
          } else {
            await _expenses.upsertExpense(Expense.fromJson(payload));
          }
        });
      case SyncCollections.caregiver:
        await _careCircle.applyingRemote(() async {
          if (doc.deleted) {
            await _careCircle.deleteCaregiver(doc.id);
          } else {
            await _careCircle.upsertCaregiver(Caregiver.fromJson(payload));
          }
        });
      case SyncCollections.careCircleMembership:
        await _careCircle.applyingRemote(() async {
          if (doc.deleted) {
            await _careCircle.deleteMembership(doc.id);
          } else {
            await _careCircle
                .upsertMembership(CareCircleMembership.fromJson(payload));
          }
        });
      case SyncCollections.emergencyCard:
        if (doc.deleted) {
          await _documents
              .applyingRemote(() => _documents.deleteEmergencyCard(doc.id));
        } else {
          final EmergencyCard card = EmergencyCard.fromJson(payload);
          await _documents
              .applyingRemote(() => _documents.upsertEmergencyCard(card));
          // Best-effort: pull the scan blob down for THIS device if the
          // row carries a key but the local file is missing (the doc came
          // from another phone). Failures leave the path null — sync isn't
          // blocked.
          await _documents.hydrateEmergencyCardBlobs(card);
        }
      case SyncCollections.powerOfAttorneyDoc:
        if (doc.deleted) {
          await _documents.applyingRemote(() => _documents.deletePoa(doc.id));
        } else {
          final PowerOfAttorneyDoc poa = PowerOfAttorneyDoc.fromJson(payload);
          await _documents.applyingRemote(() => _documents.upsertPoa(poa));
          await _documents.hydratePoaBlobs(poa);
        }
      case SyncCollections.identificationDoc:
        if (doc.deleted) {
          await _documents.applyingRemote(() => _documents.deleteId(doc.id));
        } else {
          final IdentificationDoc id = IdentificationDoc.fromJson(payload);
          await _documents.applyingRemote(() => _documents.upsertId(id));
          await _documents.hydrateIdBlobs(id);
        }
      default:
        // Unknown collection — a newer client emitted something this build
        // doesn't model yet. Ignore for forward-compatibility.
        return;
    }
  }

  Future<void> _applyPatient(SyncPatient patient) async {
    if (patient.deleted) return; // v1 never deletes the loved one
    if (patient.payload.isEmpty) return;
    final Map<String, dynamic> json =
        jsonDecode(patient.payload) as Map<String, dynamic>;
    final Patient parsed = Patient.fromJson(json);
    await _storage.upsertPatient(parsed);
  }
}

/// Riverpod-wired [SyncController] (server-authoritative sync).
/// `keepAlive: true` so the bootstrap, the lifecycle observer, the
/// interval timer, and the medication sync sink all share one instance.
@Riverpod(keepAlive: true)
SyncController syncController(Ref ref) {
  final CareblazersDatabase db = CareblazersDatabase.open();
  ref.onDispose(db.close);
  final MedicationRepository medications =
      ref.watch(medicationRepositoryProvider);
  final StorageProvider storage = ref.watch(storageProvider);
  final ChatRepository chat = ref.watch(chatRepositoryProvider);
  final AppointmentRepository appointments =
      ref.watch(appointmentRepositoryProvider);
  final ProviderRepository providers = ref.watch(providerRepositoryProvider);
  final HealthLogRepository healthLog =
      ref.watch(healthLogRepositoryProvider);
  final CarePlanRepository carePlan = ref.watch(carePlanRepositoryProvider);
  final CareEventsRepository careEvents =
      ref.watch(careEventsRepositoryProvider);
  final CareTasksRepository careTasks =
      ref.watch(careTasksRepositoryProvider);
  final CareShiftsRepository careShifts =
      ref.watch(careShiftsRepositoryProvider);
  final ExpensesRepository expenses = ref.watch(expensesRepositoryProvider);
  final CareCircleRepository careCircle =
      ref.watch(careCircleRepositoryProvider);
  final DocumentsRepository documents =
      ref.watch(documentsRepositoryProvider);
  final SyncController controller = SyncController(
    outbox: SyncOutbox(db),
    client: ref.watch(forumApiClientProvider),
    stateStore: ref.watch(syncStateStoreProvider),
    storage: storage,
    medications: medications,
    chat: chat,
    appointments: appointments,
    providers: providers,
    healthLog: healthLog,
    carePlan: carePlan,
    careEvents: careEvents,
    careTasks: careTasks,
    careShifts: careShifts,
    expenses: expenses,
    careCircle: careCircle,
    documents: documents,
  );

  // Register the enqueue seam on the SAME (keepAlive) repository instances
  // the UI writes through, so a form/chat/dose-log write routes into the
  // outbox. Enqueue is itself a no-op when there's no active circle, and
  // the apply dispatcher suppresses these sinks while applying pulled docs
  // (the echo-loop guard) — so they're safe to leave wired even
  // local-only. Fire-and-forget the debounced sync after a local write so
  // the other phone sees it promptly.
  //
  // One shared sink wiring for every repo: a repo registers by being added
  // to this list — that's all the next agent needs to wire a new table
  // (after the SyncCollections name + the _applyDoc case).
  SyncSink makeSink() => SyncSink(
        onUpsert: (String collection, String id, Map<String, dynamic> json) {
          controller.enqueueUpsert(collection, id, json).then(
                (_) => controller.scheduleSyncAfterWrite(),
                onError: (_) {},
              );
        },
        onDelete: (String collection, String id) {
          controller.enqueueDelete(collection, id).then(
                (_) => controller.scheduleSyncAfterWrite(),
                onError: (_) {},
              );
        },
      );

  // Hosts wired through the SyncSinkHost mixin (and StorageProvider, which
  // exposes the same `syncSink`/`applyingRemote` surface via the mixin).
  final List<SyncSinkHost> hosts = <SyncSinkHost>[
    medications,
    chat,
    appointments,
    providers,
    healthLog,
    carePlan,
    careEvents,
    careTasks,
    careShifts,
    expenses,
    careCircle,
    documents,
  ];
  for (final SyncSinkHost host in hosts) {
    host.syncSink = makeSink();
  }
  // Storage isn't a SyncSinkHost from the controller's vantage (it's the
  // abstract StorageProvider) but its impls mix it in, so it carries the
  // same settable `syncSink`.
  storage.syncSink = makeSink();

  ref.onDispose(() {
    for (final SyncSinkHost host in hosts) {
      host.syncSink = const SyncSink();
    }
    storage.syncSink = const SyncSink();
    controller.dispose();
  });
  return controller;
}
