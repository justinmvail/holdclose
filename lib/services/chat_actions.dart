import 'dart:math' as math;

import 'package:flutter/material.dart' show TimeOfDay;
// `Provider` in [models/appointment.dart] (a clinician) collides with
// riverpod's own `Provider`; hide the latter — this file only ever uses
// riverpod provider *instances* + `Ref`, never the `Provider` type.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;

import '../models/appointment.dart';
import '../models/care_plan_routine.dart';
import '../models/care_task.dart';
import '../models/health_log_entry.dart';
import '../models/journal_entry.dart';
import '../models/medication.dart';
import '../providers/care_plan_provider.dart' show carePlanProvider;
import '../providers/care_tasks_provider.dart'
    show careTasksProvider, careTasksRepositoryProvider;
import '../providers/health_log_provider.dart' show healthLogProvider;
import '../providers/patient_timeline_provider.dart'
    show patientDoseEventsProvider, patientTimelineEventsProvider;
import '../providers/storage_provider.dart';
import '../screens/appointment/appointment_list_screen.dart'
    show appointmentListProvider;
import '../screens/medication/dose_log_screen.dart' show dosesTodayProvider;
import '../screens/medication/medication_list_screen.dart'
    show medicationListProvider;
import '../widgets/home/catch_me_up_card.dart' show catchMeUpEventsProvider;
import 'appointment_repository.dart';
import 'medication_repository.dart';
import 'provider_repository.dart';

/// One tool the chat coach can invoke via an `[action:<name> …]` marker.
///
/// Receives the parsed `key="value"` args and performs the write, returning
/// an optional [ChatActionOutcome] (a citation to surface in the message,
/// or null when the model's prose is confirmation enough). Throwing is safe
/// — [ChatService] swallows it and still strips the marker, so a failed tool
/// never derails the reply. Built per-build in [buildChatActions]; tests
/// register scripted executors.
typedef ChatActionExecutor = Future<ChatActionOutcome?> Function(
  Map<String, String> args,
);

/// The result of a successfully-run [ChatActionExecutor].
class ChatActionOutcome {
  const ChatActionOutcome({this.citation});

  /// Optional `<entity>:<id>` citation stamped into the assistant message's
  /// citations (e.g. `journal:…`). Null when the action needs no chip.
  final String? citation;
}

/// Mints `<prefix>-<ms>-<rand>` ids, matching the pattern every app form
/// uses so chat-created rows are indistinguishable from hand-entered ones.
String _mintId(String prefix, DateTime Function() clock) {
  final int ms = clock().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return '$prefix-$ms-$rand';
}

/// Build the production tool registry — the full set of `[action:…]`
/// markers the chat coach may emit, each wired to the repository that
/// performs the write (TASKS.md Phase 11.3, extended).
///
/// Holds [ref] so a Settings override of any backend flows through without
/// rebuilding the chat service. Every executor is defensive: missing/blank
/// required args return null (the marker is still stripped, nothing is
/// written) rather than throwing.
Map<String, ChatActionExecutor> buildChatActions(
  Ref ref, {
  required DateTime Function() clock,
}) {
  return <String, ChatActionExecutor>{
    'log_journal': (Map<String, String> args) =>
        _logJournal(ref, clock, args),
    'add_medication': (Map<String, String> args) =>
        _addMedication(ref, clock, args),
    'update_medication': (Map<String, String> args) =>
        _updateMedication(ref, args),
    'delete_medication': (Map<String, String> args) =>
        _deleteMedication(ref, args),
    'add_appointment': (Map<String, String> args) =>
        _addAppointment(ref, clock, args),
    'update_appointment': (Map<String, String> args) =>
        _updateAppointment(ref, args),
    'cancel_appointment': (Map<String, String> args) =>
        _cancelAppointment(ref, args),
    'add_task': (Map<String, String> args) => _addTask(ref, clock, args),
    'complete_task': (Map<String, String> args) => _completeTask(ref, args),
    'delete_task': (Map<String, String> args) => _deleteTask(ref, args),
    'add_routine': (Map<String, String> args) => _addRoutine(ref, clock, args),
    'add_health_log': (Map<String, String> args) =>
        _addHealthLog(ref, clock, args),
    'log_dose': (Map<String, String> args) => _logDose(ref, clock, args),
    'navigate': (Map<String, String> args) => _navigate(ref, clock, args),
  };
}

/// Holds the pending navigation route the coach asked to open (null when
/// idle). The chat screen watches it, performs the push, then [clear]s it
/// so a "take me there" fires once — not again every time the thread
/// reloads.
class ChatNavigateRequest extends Notifier<String?> {
  @override
  String? build() => null;

  void request(String route) => state = route;

  void clear() => state = null;
}

/// Transient navigation intent — the in-app route (e.g. `/team/calendar`)
/// a `[action:navigate …]` parked for the chat screen to push.
final chatNavigateRequestProvider =
    NotifierProvider<ChatNavigateRequest, String?>(ChatNavigateRequest.new);

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

String? _clean(String? v) {
  final String s = (v ?? '').trim();
  return s.isEmpty ? null : s;
}

/// Refresh every surface that mirrors the medication list so a chat-added
/// or -edited med shows up live on the med list, Home schedule, and
/// calendar without an app restart.
void _refreshMedications(Ref ref) {
  ref.invalidate(medicationListProvider);
  ref.invalidate(patientDoseEventsProvider);
  ref.invalidate(patientTimelineEventsProvider);
  ref.invalidate(catchMeUpEventsProvider);
}

MedicationRoute _parseRoute(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'topical':
      return MedicationRoute.topical;
    case 'injection':
    case 'injected':
      return MedicationRoute.injection;
    case 'other':
      return MedicationRoute.other;
    case 'oral':
    default:
      return MedicationRoute.oral;
  }
}

/// Find a live medication by name (case-insensitive; exact match first,
/// then a unique substring) so update/delete can resolve the row the model
/// names without knowing its id.
Medication? _resolveMedication(List<Medication> meds, String? name) {
  final String n = (name ?? '').trim().toLowerCase();
  if (n.isEmpty) return null;
  for (final Medication m in meds) {
    if (m.name.toLowerCase() == n) return m;
  }
  final List<Medication> partial = meds
      .where((Medication m) => m.name.toLowerCase().contains(n))
      .toList();
  return partial.length == 1 ? partial.first : null;
}

// ---------------------------------------------------------------------------
// Journal (migrated from the v1 single-action path)
// ---------------------------------------------------------------------------

/// Citation prefix the chat surface renders as an "entry saved" chip.
const String journalCitationPrefix = 'journal:';

/// Resolve the coach's free-text `occurred_at` (e.g. `"just now"`,
/// `"yesterday afternoon"`, `"last night"`) into a wall-clock [DateTime]
/// relative to [now]. Covers the high-frequency phrases the prompt tells
/// the coach to use; anything unrecognised collapses to [now].
DateTime resolveOccurredAt(String? raw, DateTime now) {
  final String text = (raw ?? '').trim().toLowerCase();
  if (text.isEmpty || text.contains('just now') || text == 'now') {
    return now;
  }
  if (text.contains('yesterday')) {
    final DateTime y = now.subtract(const Duration(days: 1));
    return DateTime(y.year, y.month, y.day, 14);
  }
  if (text.contains('last night') || text.contains('overnight')) {
    final DateTime y = now.subtract(const Duration(days: 1));
    return DateTime(y.year, y.month, y.day, 21);
  }
  if (text.contains('this morning') || text.contains('earlier today')) {
    return DateTime(now.year, now.month, now.day, 9);
  }
  if (text.contains('this afternoon')) {
    return DateTime(now.year, now.month, now.day, 15);
  }
  if (text.contains('this evening') || text.contains('tonight')) {
    return DateTime(now.year, now.month, now.day, 19);
  }
  return now;
}

Future<ChatActionOutcome?> _logJournal(
  Ref ref,
  DateTime Function() clock,
  Map<String, String> args,
) async {
  final String? situation = _clean(args['situation']);
  if (situation == null) return null;
  final String attempts = _clean(args['attempts']) ?? 'none yet';
  final DateTime occurredAt =
      resolveOccurredAt(args['occurred_at'], clock());
  final entry = JournalEntry.wizard(
    id: _mintId('journal', clock),
    createdAt: clock(),
    occurredAt: occurredAt,
    situationText: situation,
    attemptsText: attempts,
  );
  await ref.read(storageProvider).insertJournalEntry(entry);
  return ChatActionOutcome(citation: '$journalCitationPrefix${entry.id}');
}

// ---------------------------------------------------------------------------
// Medications — add / update / delete
// ---------------------------------------------------------------------------

Future<ChatActionOutcome?> _addMedication(
  Ref ref,
  DateTime Function() clock,
  Map<String, String> args,
) async {
  final String? name = _clean(args['name']);
  final String? dosage = _clean(args['dosage']);
  // Name + dosage are the two things the coach must transcribe; without
  // them there's nothing safe to record.
  if (name == null || dosage == null) return null;
  final MedicationRepository repo = ref.read(medicationRepositoryProvider);
  final med = Medication(
    id: _mintId('med', clock),
    name: name,
    dosage: dosage,
    route: _parseRoute(args['route']),
    prescriber: _clean(args['prescriber']),
    notes: _clean(args['notes']),
  );
  await repo.upsertMedication(med);
  // Optionally schedule it into named dose windows ("morning,evening") so
  // the coach can set the whole schedule in one turn instead of just
  // opening the medication screen.
  final String? windows = _clean(args['windows']);
  if (windows != null) {
    await _attachMedicationWindows(ref, repo, med.id, windows, clock);
  }
  _refreshMedications(ref);
  return null;
}

/// Attach [medicationId] to each named dose window in [windowsCsv] (a
/// comma-separated list like "morning, evening"). Names match the
/// patient's window labels case-insensitively (exact, then substring);
/// unknown names are skipped. Each match becomes an every-day
/// [MedicationWindowEntry] the dose forecast then expands.
Future<void> _attachMedicationWindows(
  Ref ref,
  MedicationRepository repo,
  String medicationId,
  String windowsCsv,
  DateTime Function() clock,
) async {
  final String? patientId = await _patientId(ref);
  if (patientId == null) return;
  final List<DoseWindow> available = await repo.windowsForPatient(patientId);
  if (available.isEmpty) return;
  final DateTime now = clock();
  final Set<String> attached = <String>{};
  for (final String raw in windowsCsv.split(',')) {
    final String req = raw.trim().toLowerCase();
    if (req.isEmpty) continue;
    final DoseWindow? match = _resolveWindow(available, req);
    if (match == null || attached.contains(match.id)) continue;
    attached.add(match.id);
    await repo.upsertEntry(MedicationWindowEntry(
      id: _mintId('entry', clock),
      medicationId: medicationId,
      windowId: match.id,
      daysOfWeek: const <int>{},
      startsOn: DateTime(now.year, now.month, now.day),
    ));
  }
}

/// Best window for a requested label: exact (case-insensitive) match
/// first, then a unique substring match, else null.
DoseWindow? _resolveWindow(List<DoseWindow> windows, String req) {
  for (final DoseWindow w in windows) {
    if (w.label.toLowerCase() == req) return w;
  }
  final List<DoseWindow> partial = windows
      .where((DoseWindow w) => w.label.toLowerCase().contains(req))
      .toList();
  return partial.length == 1 ? partial.first : null;
}

Future<ChatActionOutcome?> _updateMedication(
  Ref ref,
  Map<String, String> args,
) async {
  final MedicationRepository repo = ref.read(medicationRepositoryProvider);
  final List<Medication> meds = await repo.listMedications();
  final Medication? target = _resolveMedication(meds, args['name']);
  if (target == null) return null;
  final Medication updated = target.copyWith(
    name: _clean(args['new_name']) ?? target.name,
    dosage: _clean(args['dosage']) ?? target.dosage,
    route: args['route'] != null ? _parseRoute(args['route']) : target.route,
    prescriber: _clean(args['prescriber']) ?? target.prescriber,
    notes: _clean(args['notes']) ?? target.notes,
  );
  await repo.upsertMedication(updated);
  _refreshMedications(ref);
  return null;
}

Future<ChatActionOutcome?> _deleteMedication(
  Ref ref,
  Map<String, String> args,
) async {
  final MedicationRepository repo = ref.read(medicationRepositoryProvider);
  final List<Medication> meds = await repo.listMedications();
  final Medication? target = _resolveMedication(meds, args['name']);
  if (target == null) return null;
  await repo.deleteMedication(target.id);
  _refreshMedications(ref);
  return null;
}

// ---------------------------------------------------------------------------
// Appointments — add / update / cancel
// ---------------------------------------------------------------------------

/// Parse a `YYYY-MM-DD HH:MM` (or ISO-8601) string into a local
/// [DateTime]. Tolerates the space separator the prompt uses. Null when
/// it can't be parsed — the caller treats that as "not enough to act".
DateTime? _parseDateTime(String? raw) {
  final String s = (raw ?? '').trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.contains(' ') && !s.contains('T')
      ? s.replaceFirst(' ', 'T')
      : s);
}

void _refreshAppointments(Ref ref) {
  ref.invalidate(appointmentListProvider);
  ref.invalidate(patientTimelineEventsProvider);
  ref.invalidate(catchMeUpEventsProvider);
}

/// Resolve the clinician [name] to a provider id, creating a minimal
/// provider row when none matches so an appointment can always hang off
/// one. Matches case-insensitively (exact, then substring).
Future<String> _resolveProviderId(
  Ref ref,
  String name,
  DateTime Function() clock,
) async {
  final ProviderRepository repo = ref.read(providerRepositoryProvider);
  final List<Provider> existing = await repo.listProviders();
  final String n = name.trim().toLowerCase();
  for (final Provider p in existing) {
    if (p.name.toLowerCase() == n) return p.id;
  }
  for (final Provider p in existing) {
    if (p.name.toLowerCase().contains(n)) return p.id;
  }
  final Provider created = Provider(
    id: _mintId('prov', clock),
    name: name.trim(),
    role: ProviderRole.other,
    phone: '',
    address: '',
  );
  await repo.upsertProvider(created);
  return created.id;
}

/// Find the soonest upcoming appointment whose provider's name matches
/// [providerName] — how update/cancel locate the row the coach names.
Future<Appointment?> _resolveAppointment(
  Ref ref,
  String? providerName,
) async {
  final String n = (providerName ?? '').trim().toLowerCase();
  if (n.isEmpty) return null;
  final AppointmentRepository repo = ref.read(appointmentRepositoryProvider);
  final Set<String> matchIds = (await repo.listProviders())
      .where((Provider p) => p.name.toLowerCase().contains(n))
      .map((Provider p) => p.id)
      .toSet();
  if (matchIds.isEmpty) return null;
  final List<Appointment> appts = (await repo.listAppointments())
      .where((Appointment a) =>
          matchIds.contains(a.providerId) &&
          a.status == AppointmentStatus.upcoming)
      .toList()
    ..sort((Appointment a, Appointment b) => a.startsAt.compareTo(b.startsAt));
  return appts.isEmpty ? null : appts.first;
}

List<String> _parseAgenda(String? raw) =>
    (raw ?? '')
        .split(';')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();

Future<ChatActionOutcome?> _addAppointment(
  Ref ref,
  DateTime Function() clock,
  Map<String, String> args,
) async {
  final String? providerName = _clean(args['provider_name']);
  final DateTime? startsAt = _parseDateTime(args['starts_at']);
  // A visit needs who and when; without them there's nothing to schedule.
  if (providerName == null || startsAt == null) return null;
  final String providerId = await _resolveProviderId(ref, providerName, clock);
  final appt = Appointment(
    id: _mintId('appt', clock),
    providerId: providerId,
    startsAt: startsAt,
    durationMinutes: int.tryParse(args['duration_minutes'] ?? '') ?? 60,
    location: _clean(args['location']) ?? '',
    agenda: _parseAgenda(args['agenda']),
    status: AppointmentStatus.upcoming,
    notes: _clean(args['notes']),
  );
  await ref.read(appointmentRepositoryProvider).upsertAppointment(appt);
  _refreshAppointments(ref);
  return null;
}

Future<ChatActionOutcome?> _updateAppointment(
  Ref ref,
  Map<String, String> args,
) async {
  final Appointment? target =
      await _resolveAppointment(ref, args['provider_name']);
  if (target == null) return null;
  final Appointment updated = target.copyWith(
    startsAt: _parseDateTime(args['starts_at']) ?? target.startsAt,
    durationMinutes:
        int.tryParse(args['duration_minutes'] ?? '') ?? target.durationMinutes,
    location: _clean(args['location']) ?? target.location,
    notes: _clean(args['notes']) ?? target.notes,
  );
  await ref.read(appointmentRepositoryProvider).upsertAppointment(updated);
  _refreshAppointments(ref);
  return null;
}

Future<ChatActionOutcome?> _cancelAppointment(
  Ref ref,
  Map<String, String> args,
) async {
  final Appointment? target =
      await _resolveAppointment(ref, args['provider_name']);
  if (target == null) return null;
  // Cancel keeps the row (status flips) rather than hard-deleting, so the
  // visit stays in the history the way the app's own cancel flow does.
  await ref
      .read(appointmentRepositoryProvider)
      .upsertAppointment(target.copyWith(status: AppointmentStatus.canceled));
  _refreshAppointments(ref);
  return null;
}

// ---------------------------------------------------------------------------
// Care tasks — add / complete / delete
// ---------------------------------------------------------------------------

Future<String?> _patientId(Ref ref) async =>
    (await ref.read(storageProvider).getPatient())?.id;

CareTask? _resolveTask(List<CareTask> tasks, String? title) {
  final String t = (title ?? '').trim().toLowerCase();
  if (t.isEmpty) return null;
  for (final CareTask task in tasks) {
    if (task.title.toLowerCase() == t) return task;
  }
  final List<CareTask> partial = tasks
      .where((CareTask task) => task.title.toLowerCase().contains(t))
      .toList();
  return partial.length == 1 ? partial.first : null;
}

Future<ChatActionOutcome?> _addTask(
  Ref ref,
  DateTime Function() clock,
  Map<String, String> args,
) async {
  final String? title = _clean(args['title']);
  if (title == null) return null;
  final String? patientId = await _patientId(ref);
  if (patientId == null) return null;
  final task = CareTask(
    id: _mintId('task', clock),
    title: title,
    patientId: patientId,
    body: _clean(args['body']),
    dueAt: _parseDateTime(args['due_at']),
  );
  await ref.read(careTasksProvider.notifier).addTask(task);
  return null;
}

Future<ChatActionOutcome?> _completeTask(
  Ref ref,
  Map<String, String> args,
) async {
  // Scope the by-title lookup to the active loved one (multi-patient, Issue
  // #6) so "complete the pharmacy task" can't match another person's task.
  final String? patientId = await _patientId(ref);
  if (patientId == null) return null;
  final List<CareTask> tasks = await ref
      .read(careTasksRepositoryProvider)
      .listTasksForPatient(patientId);
  final CareTask? target = _resolveTask(tasks, args['title']);
  if (target == null) return null;
  await ref.read(careTasksProvider.notifier).complete(target.id);
  return null;
}

Future<ChatActionOutcome?> _deleteTask(
  Ref ref,
  Map<String, String> args,
) async {
  // Same active-patient scoping as _completeTask — a destructive lookup must
  // never resolve to a different loved one's task (multi-patient, Issue #6).
  final String? patientId = await _patientId(ref);
  if (patientId == null) return null;
  final List<CareTask> tasks = await ref
      .read(careTasksRepositoryProvider)
      .listTasksForPatient(patientId);
  final CareTask? target = _resolveTask(tasks, args['title']);
  if (target == null) return null;
  await ref.read(careTasksProvider.notifier).removeTask(target.id);
  return null;
}

// ---------------------------------------------------------------------------
// Care routines — add a scheduled routine the Careblazer describes
// ---------------------------------------------------------------------------

/// Map the coach's free-text frequency word to a [FrequencyKind]. Mirrors
/// the routine form's daily / weekly / asNeeded choices; anything
/// unrecognised falls back to daily (the form's own default).
FrequencyKind _parseFrequency(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'weekly':
      return FrequencyKind.weekly;
    case 'asneeded':
    case 'as needed':
    case 'as_needed':
      return FrequencyKind.asNeeded;
    case 'daily':
    default:
      return FrequencyKind.daily;
  }
}

/// Parse a `HH:MM` (24-hour) wall-clock string into a [TimeOfDay]. Null
/// when it can't be read — the caller treats that as "not enough to act"
/// so the coach never schedules a routine at a guessed time.
TimeOfDay? _parseTimeOfDay(String? raw) {
  final String s = (raw ?? '').trim();
  if (s.isEmpty) return null;
  final RegExpMatch? m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
  if (m == null) return null;
  final int? hour = int.tryParse(m.group(1)!);
  final int? minute = int.tryParse(m.group(2)!);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return TimeOfDay(hour: hour, minute: minute);
}

/// Parse a comma-separated day list ("Mon, Wed, Fri" or "1,3,5") into the
/// `DateTime.weekday` set (Monday = 1 … Sunday = 7) the routine model uses.
Set<int> _parseDaysOfWeek(String? raw) {
  const Map<String, int> names = <String, int>{
    'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6, 'sun': 7,
  };
  final Set<int> out = <int>{};
  for (final String token in (raw ?? '').split(',')) {
    final String t = token.trim().toLowerCase();
    if (t.isEmpty) continue;
    final int? numeric = int.tryParse(t);
    if (numeric != null && numeric >= 1 && numeric <= 7) {
      out.add(numeric);
      continue;
    }
    if (t.length >= 3) {
      final int? day = names[t.substring(0, 3)];
      if (day != null) out.add(day);
    }
  }
  return out;
}

void _refreshRoutines(Ref ref) {
  ref.invalidate(patientTimelineEventsProvider);
  ref.invalidate(catchMeUpEventsProvider);
}

Future<ChatActionOutcome?> _addRoutine(
  Ref ref,
  DateTime Function() clock,
  Map<String, String> args,
) async {
  final String? title = _clean(args['name']) ?? _clean(args['title']);
  final TimeOfDay? time = _parseTimeOfDay(args['time']);
  // A routine needs a name and a wall-clock anchor; without them there's
  // nothing safe to put on the schedule.
  if (title == null || time == null) return null;
  final String? patientId = await _patientId(ref);
  if (patientId == null) return null;

  final FrequencyKind frequency = _parseFrequency(args['frequency']);
  // Weekly routines carry the chosen days; daily / asNeeded leave the set
  // empty, matching how the routine form persists them.
  final Set<int> days = frequency == FrequencyKind.weekly
      ? _parseDaysOfWeek(args['days'])
      : const <int>{};
  final DateTime now = clock();
  final routine = CarePlanRoutine(
    id: _mintId('routine', clock),
    patientId: patientId,
    title: title,
    body: _clean(args['body']) ?? '',
    scheduledTime: time,
    frequencyKind: frequency,
    daysOfWeek: days,
    startsOn: DateTime(now.year, now.month, now.day),
  );
  await ref.read(carePlanProvider.notifier).upsert(routine);
  _refreshRoutines(ref);
  return null;
}

// ---------------------------------------------------------------------------
// Health log — record a vitals / symptom / note entry the Careblazer states
// ---------------------------------------------------------------------------

/// Map the coach's free-text kind word to a [HealthLogKind]; defaults to
/// [HealthLogKind.note] (the most permissive bucket) for anything unknown.
HealthLogKind _parseHealthLogKind(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'vitals':
    case 'vital':
      return HealthLogKind.vitals;
    case 'symptom':
      return HealthLogKind.symptom;
    case 'note':
    default:
      return HealthLogKind.note;
  }
}

void _refreshHealthLog(Ref ref) {
  ref.invalidate(patientTimelineEventsProvider);
  ref.invalidate(catchMeUpEventsProvider);
}

Future<ChatActionOutcome?> _addHealthLog(
  Ref ref,
  DateTime Function() clock,
  Map<String, String> args,
) async {
  // The caregiver's words for the reading / observation. Accept either
  // `value` or `note` so the coach can phrase it naturally.
  final String? text = _clean(args['value']) ?? _clean(args['note']);
  // A weight reading is structured (fb_1781115352788931) — parse it to a
  // number so it doesn't get dumped into the notes; garbage / non-positive
  // values fall back to null rather than persisting nonsense.
  final double? parsedWeight = double.tryParse(_clean(args['weight_lbs']) ?? '');
  final double? weightLbs =
      (parsedWeight != null && parsedWeight > 0) ? parsedWeight : null;
  if (text == null && weightLbs == null) return null;
  final String? patientId = await _patientId(ref);
  if (patientId == null) return null;
  // recorded_at reuses the journal's tolerant relative-time parsing so the
  // coach can say "this morning" the same way it logs a journal entry.
  final DateTime recordedAt =
      resolveOccurredAt(args['recorded_at'], clock());
  final entry = HealthLogEntry(
    id: _mintId('health', clock),
    patientId: patientId,
    recordedAt: recordedAt,
    // A structured weight is a vitals measurement whatever the coach called
    // the entry; otherwise honour the stated kind.
    kind: weightLbs != null
        ? HealthLogKind.vitals
        : _parseHealthLogKind(args['kind']),
    weightLbs: weightLbs,
    notes: text,
  );
  await ref.read(healthLogProvider.notifier).add(entry);
  _refreshHealthLog(ref);
  return null;
}

// ---------------------------------------------------------------------------
// Dose log — record a medication dose the Careblazer says was taken/skipped
// ---------------------------------------------------------------------------

/// Map the coach's free-text outcome word to a [DoseStatus]. "Taken" is the
/// default — the common case is the Careblazer confirming a dose was given.
DoseStatus _parseDoseStatus(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'skipped':
    case 'skip':
      return DoseStatus.skipped;
    case 'missed':
      return DoseStatus.missed;
    case 'late':
      return DoseStatus.late;
    case 'taken':
    case 'took':
    default:
      return DoseStatus.taken;
  }
}

Future<ChatActionOutcome?> _logDose(
  Ref ref,
  DateTime Function() clock,
  Map<String, String> args,
) async {
  final MedicationRepository repo = ref.read(medicationRepositoryProvider);
  final List<Medication> meds = await repo.listMedications();
  final Medication? med = _resolveMedication(meds, args['name']);
  // Without a medication on file we can't key the dose to anything.
  if (med == null) return null;
  final DoseStatus status = _parseDoseStatus(args['outcome']);
  // The dose's wall-clock — an explicit "YYYY-MM-DD HH:MM", else the
  // tolerant relative parser ("just now", "this morning"), else now.
  final DateTime when =
      _parseDateTime(args['time']) ?? resolveOccurredAt(args['time'], clock());
  // Only a recorded-as-given dose carries a takenAt stamp; skipped / missed
  // leave it null, matching the dose-log screen's own status handling.
  final DateTime? takenAt =
      (status == DoseStatus.taken || status == DoseStatus.late) ? when : null;
  final log = DoseLog(
    id: _mintId('dose', clock),
    medicationId: med.id,
    scheduledFor: when,
    takenAt: takenAt,
    status: status,
    notes: _clean(args['notes']),
  );
  await repo.upsertDoseLog(log);
  ref.invalidate(dosesTodayProvider);
  ref.invalidate(patientDoseEventsProvider);
  ref.invalidate(patientTimelineEventsProvider);
  ref.invalidate(catchMeUpEventsProvider);
  return null;
}

// ---------------------------------------------------------------------------
// Navigation — take the Careblazer to a screen on request
// ---------------------------------------------------------------------------

/// Map a friendly [target] keyword (plus an optional [providerName] for a
/// specific visit) to an in-app route. Returns null for an unknown target.
Future<String?> routeForNavTarget(
  Ref ref,
  String? target,
  String? providerName,
) async {
  switch ((target ?? '').trim().toLowerCase()) {
    case 'home':
    case 'dashboard':
      return '/';
    case 'medical':
      return '/medical';
    case 'medications':
    case 'medication':
    case 'meds':
      return '/medications';
    case 'team':
    case 'care team':
      return '/team';
    case 'calendar':
    case 'appointments':
    case 'schedule':
      return '/team/calendar';
    case 'appointment':
      // Deep-link to the named visit when we can resolve it, else the
      // calendar so the coach's "take me there" never dead-ends.
      final Appointment? appt = await _resolveAppointment(ref, providerName);
      return appt != null ? '/appointments/${appt.id}' : '/team/calendar';
    case 'tasks':
    case 'task board':
      return '/team/tasks';
    case 'journal':
      return '/journal';
    case 'community':
      return '/community';
    case 'emergency card':
    case 'emergency':
      return '/medical/cards/emergency';
    default:
      return null;
  }
}

Future<ChatActionOutcome?> _navigate(
  Ref ref,
  DateTime Function() clock,
  Map<String, String> args,
) async {
  String? route =
      await routeForNavTarget(ref, args['target'], args['provider_name']);
  if (route == null) return null;
  // A date on the calendar/schedule opens it on that day instead of today.
  if (route == '/team/calendar') {
    final DateTime? date = parseCalendarDate(args['date'], clock());
    if (date != null) route = '/team/calendar?date=${_isoDate(date)}';
  }
  ref.read(chatNavigateRequestProvider.notifier).request(route);
  return null;
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Resolve a date the coach passed for a calendar jump. Tolerant on
/// purpose so it works whether the model emits an ISO date, "June 18th",
/// or "6/18": ISO is parsed directly; a bare "Month Day" or "M/D" is
/// resolved against [now]'s year (the app clock is the source of truth for
/// "today", so a model that doesn't know the year still lands right).
DateTime? parseCalendarDate(String? raw, DateTime now) {
  final String s = (raw ?? '').trim();
  if (s.isEmpty) return null;
  final DateTime? iso = DateTime.tryParse(
      s.contains(' ') && !s.contains('T') ? s.replaceFirst(' ', 'T') : s);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);

  // "June 18", "Jun 18th", "18 June" — month name + day, year from now.
  final String cleaned =
      s.toLowerCase().replaceAll(RegExp(r'(st|nd|rd|th)\b'), '');
  const Map<String, int> months = <String, int>{
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };
  for (final RegExpMatch m
      in RegExp(r'([a-z]+)\s+(\d{1,2})|(\d{1,2})\s+([a-z]+)')
          .allMatches(cleaned)) {
    final String? name = m.group(1) ?? m.group(4);
    final String? dayStr = m.group(2) ?? m.group(3);
    final int? mon = name != null && name.length >= 3
        ? months[name.substring(0, 3)]
        : null;
    final int? day = int.tryParse(dayStr ?? '');
    if (mon != null && day != null && day >= 1 && day <= 31) {
      return DateTime(now.year, mon, day);
    }
  }

  // "6/18" or "6-18" — numeric month/day, year from now.
  final RegExpMatch? md = RegExp(r'^(\d{1,2})[/-](\d{1,2})$').firstMatch(s);
  if (md != null) {
    final int? mon = int.tryParse(md.group(1)!);
    final int? day = int.tryParse(md.group(2)!);
    if (mon != null &&
        day != null &&
        mon >= 1 &&
        mon <= 12 &&
        day >= 1 &&
        day <= 31) {
      return DateTime(now.year, mon, day);
    }
  }
  return null;
}
