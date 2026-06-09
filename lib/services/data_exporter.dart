import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// `share_plus` re-exports `XFile` (from `cross_file`) so the file-share
// path doesn't take a direct dependency on `cross_file` — same package the
// library-card text share already uses (no new top-level dependency).
import 'package:share_plus/share_plus.dart' as share_plus;
import 'package:share_plus/share_plus.dart' show XFile;

import '../models/appointment.dart';
import '../models/care_circle_membership.dart';
import '../models/care_event.dart';
import '../models/care_plan_routine.dart';
import '../models/care_shift.dart';
import '../models/care_task.dart';
import '../models/caregiver.dart';
import '../models/document.dart';
import '../models/expense.dart';
import '../models/health_log_entry.dart';
import '../models/journal_entry.dart';
import '../models/medication.dart';
import '../models/patient.dart';
import '../models/settings.dart';
import '../providers/care_circle_provider.dart';
import '../providers/care_events_provider.dart';
import '../providers/care_plan_provider.dart';
import '../providers/care_shifts_provider.dart';
import '../providers/care_tasks_provider.dart';
import '../providers/documents_provider.dart';
import '../providers/expenses_provider.dart';
import '../providers/health_log_provider.dart';
import '../providers/storage_provider.dart';
import '../services/appointment_repository.dart';
import '../services/medication_repository.dart';
import '../services/provider_repository.dart';

part 'data_exporter.g.dart';

/// The export envelope's schema version (Issue #20 — Data Export / Backup).
///
/// Bumped only when the *shape* of the JSON changes in a way a future
/// importer would need to branch on. The freezed models inside each
/// section carry their own forward-compatible `fromJson` (unknown keys are
/// ignored, new optional fields default), so adding a field to a model
/// does NOT require a bump — only restructuring the envelope itself does.
const int dataExportSchemaVersion = 1;

/// Outbound file share-sheet handoff for the JSON backup (Issue #20).
///
/// A sibling of [Sharer] (`lib/providers/share_provider.dart`) — that seam
/// shares plain *text*; this one shares a *file* (bytes + filename) so the
/// OS share sheet offers "Save to Files", "Mail", "Drive", etc. Kept behind
/// an interface for the same reason: the widget test overrides the riverpod
/// provider with [RecordingDataFileSharer] and asserts the bytes + filename
/// the Settings row handed off, without the `share_plus` platform channel
/// firing in the test zone.
abstract class DataFileSharer {
  /// Hand [bytes] to the platform share sheet as a file named [filename]
  /// with MIME type [mimeType]. Completes when the sheet closes.
  Future<void> shareFile(
    Uint8List bytes, {
    required String filename,
    required String mimeType,
  });
}

/// Production `share_plus`-backed [DataFileSharer]. Writes the backup
/// bytes to a real file in the OS temp directory and shares *that path*
/// via `Share.shareXFiles`. Reuses the `share_plus` dependency the
/// library-card text share already pulls in — no new top-level package.
///
/// A path-based [XFile] is used deliberately over `XFile.fromData`: on iOS
/// the share sheet's "Save to Files" / Mail / Drive targets read the file
/// off disk, and the on-disk path is the reliable handoff — the in-memory
/// form forces share_plus to round-trip the bytes through a temp file
/// itself and has been flaky for the JSON backup. The file lands in the
/// temp dir, which the OS reclaims, so there's nothing to clean up.
class RealDataFileSharer implements DataFileSharer {
  const RealDataFileSharer();

  @override
  Future<void> shareFile(
    Uint8List bytes, {
    required String filename,
    required String mimeType,
  }) async {
    final Directory tmp = await getTemporaryDirectory();
    final File out = File('${tmp.path}/$filename');
    await out.writeAsBytes(bytes, flush: true);
    await share_plus.Share.shareXFiles(
      <XFile>[XFile(out.path, mimeType: mimeType, name: filename)],
    );
  }
}

/// Records every [shareFile] call without firing a platform call. Used by
/// the Settings widget test to assert the backup row handed the exporter's
/// bytes + filename to the share seam.
class RecordingDataFileSharer implements DataFileSharer {
  RecordingDataFileSharer();

  final List<({Uint8List bytes, String filename, String mimeType})> shared =
      <({Uint8List bytes, String filename, String mimeType})>[];

  @override
  Future<void> shareFile(
    Uint8List bytes, {
    required String filename,
    required String mimeType,
  }) async {
    shared.add((bytes: bytes, filename: filename, mimeType: mimeType));
  }
}

/// Bundle of every persistence seam the exporter reads (Issue #20).
///
/// Grouped into one record so [DataExporter.gather] takes a single
/// argument the unit test can assemble against in-memory / test-instance
/// repos, and the riverpod provider can assemble against the live ones.
typedef ExportSources = ({
  StorageProvider storage,
  MedicationRepository medications,
  AppointmentRepository appointments,
  ProviderRepository providers,
  HealthLogRepository healthLog,
  CarePlanRepository carePlan,
  DocumentsRepository documents,
  CareCircleRepository careCircle,
  CareEventsRepository careEvents,
  CareTasksRepository careTasks,
  CareShiftsRepository careShifts,
  ExpensesRepository expenses,
});

/// Gathers ALL local data into one machine-readable JSON document and hands
/// it to the OS share sheet (Issue #20 — Data Export / Backup).
///
/// The doctor-visit PDF ([PdfExporter]) is a human-readable *summary*; this
/// is the full, round-trippable backup a caregiver can stash off-device so
/// a lost phone doesn't mean lost data. Every section is the model's own
/// `toJson` shape, wrapped in a versioned envelope:
///
/// ```json
/// { "schemaVersion": 1, "exportedAt": "<iso8601>", "patients": [...], ... }
/// ```
///
/// [gather] is pure + injectable — it takes the repos via [ExportSources]
/// and the timestamp via [clock], so the unit test seeds a couple of repos
/// and asserts the JSON without a widget tree or a real clock. [exportJson]
/// pretty-prints; [exportAndShare] is the one-call path the Settings row
/// uses (gather → encode → share).
class DataExporter {
  const DataExporter({this.clock = DateTime.now});

  /// Wall clock for the `exportedAt` envelope stamp. Injectable so the
  /// unit test pins a fixed instant and asserts the exact string.
  final DateTime Function() clock;

  /// Filename the share sheet suggests. Date-stamped so successive backups
  /// don't clobber each other in the caregiver's Files app.
  static const String filenamePrefix = 'careblazers-backup';

  /// MIME type for the shared file.
  static const String mimeType = 'application/json';

  /// Build the full export map. PURE — no I/O beyond the repository reads it
  /// is handed, no clock beyond [clock]. Reads are issued concurrently per
  /// top-level section; within the medication section the per-medication
  /// entry/log reads are batched after the medication list resolves.
  Future<Map<String, dynamic>> gather(ExportSources sources) async {
    final DateTime exportedAt = clock();

    // Kick off the independent top-level reads together.
    final Future<Patient?> patientFuture = sources.storage.getPatient();
    final Future<List<JournalEntry>> journalFuture =
        sources.storage.listAllJournalEntries();
    // Defended at the source: a malformed settings blob (a legacy / corrupt
    // payload) must degrade to defaults, not abort the whole backup. The
    // `.catchError` is attached at creation so the eager future never escapes
    // as an unhandled async error before the awaited `try` below runs.
    final Future<AppSettings> settingsFuture = sources.storage
        .getSettings()
        .catchError((Object _) => AppSettings.defaults());
    final Future<List<Appointment>> appointmentsFuture =
        sources.appointments.listAppointments();
    final Future<List<Provider>> providersFuture =
        sources.appointments.listProviders();
    final Future<List<HealthLogEntry>> healthLogFuture =
        sources.healthLog.listAll();
    final Future<List<CarePlanRoutine>> carePlanFuture =
        sources.carePlan.listAll();
    final Future<List<EmergencyCard>> emergencyCardsFuture =
        sources.documents.listEmergencyCards();
    final Future<List<PowerOfAttorneyDoc>> poaFuture =
        sources.documents.listPoa();
    final Future<List<IdentificationDoc>> idsFuture =
        sources.documents.listIds();
    final Future<List<Caregiver>> caregiversFuture =
        sources.careCircle.listCaregivers();
    final Future<List<CareCircleMembership>> membershipsFuture =
        sources.careCircle.listMemberships();
    final Future<List<CareEvent>> careEventsFuture =
        sources.careEvents.listEvents();
    final Future<List<CareTask>> careTasksFuture =
        sources.careTasks.listTasks();
    final Future<List<CareShift>> careShiftsFuture =
        sources.careShifts.listShifts();
    final Future<List<Expense>> expensesFuture =
        sources.expenses.listExpenses();

    final Patient? patient = await patientFuture;
    final List<Patient> patients =
        patient == null ? const <Patient>[] : <Patient>[patient];

    // The medication trio (windows / window entries / dose logs) is read
    // through the patient + medication keys the repository exposes:
    //   - windows: per distinct patient id
    //   - entries: unioned across every medication
    //   - logs:    unioned across every medication
    final List<Medication> medications =
        await sources.medications.listMedications();
    final List<DoseWindow> windows = <DoseWindow>[];
    for (final Patient p in patients) {
      windows.addAll(await sources.medications.windowsForPatient(p.id));
    }
    final List<MedicationWindowEntry> windowEntries = <MedicationWindowEntry>[];
    final List<DoseLog> doseLogs = <DoseLog>[];
    for (final Medication m in medications) {
      windowEntries
          .addAll(await sources.medications.entriesForMedication(m.id));
      doseLogs.addAll(await sources.medications.logsFor(m.id));
    }

    return <String, dynamic>{
      'schemaVersion': dataExportSchemaVersion,
      'exportedAt': exportedAt.toIso8601String(),
      'patients': _toJsonList<Patient>(patients, (Patient p) => p.toJson()),
      'journalEntries': _toJsonList<JournalEntry>(
          await journalFuture, (JournalEntry e) => e.toJson()),
      'medications':
          _toJsonList<Medication>(medications, (Medication m) => m.toJson()),
      'doseWindows':
          _toJsonList<DoseWindow>(windows, (DoseWindow w) => w.toJson()),
      'medicationWindowEntries': _toJsonList<MedicationWindowEntry>(
          windowEntries, (MedicationWindowEntry e) => e.toJson()),
      'doseLogs': _toJsonList<DoseLog>(doseLogs, (DoseLog l) => l.toJson()),
      'providers': _toJsonList<Provider>(
          await providersFuture, (Provider p) => p.toJson()),
      'appointments': _toJsonList<Appointment>(
          await appointmentsFuture, (Appointment a) => a.toJson()),
      'healthLogEntries': _toJsonList<HealthLogEntry>(
          await healthLogFuture, (HealthLogEntry e) => e.toJson()),
      'carePlanRoutines': _toJsonList<CarePlanRoutine>(
          await carePlanFuture, (CarePlanRoutine r) => r.toJson()),
      'emergencyCards': _toJsonList<EmergencyCard>(
          await emergencyCardsFuture, (EmergencyCard c) => c.toJson()),
      'powerOfAttorneyDocs': _toJsonList<PowerOfAttorneyDoc>(
          await poaFuture, (PowerOfAttorneyDoc d) => d.toJson()),
      'identificationDocs': _toJsonList<IdentificationDoc>(
          await idsFuture, (IdentificationDoc d) => d.toJson()),
      'caregivers': _toJsonList<Caregiver>(
          await caregiversFuture, (Caregiver c) => c.toJson()),
      'careCircleMemberships': _toJsonList<CareCircleMembership>(
          await membershipsFuture, (CareCircleMembership m) => m.toJson()),
      'careEvents': _toJsonList<CareEvent>(
          await careEventsFuture, (CareEvent e) => e.toJson()),
      'careTasks': _toJsonList<CareTask>(
          await careTasksFuture, (CareTask t) => t.toJson()),
      'careShifts': _toJsonList<CareShift>(
          await careShiftsFuture, (CareShift s) => s.toJson()),
      'expenses':
          _toJsonList<Expense>(await expensesFuture, (Expense e) => e.toJson()),
      'settings': (await settingsFuture).toJson(),
    };
  }

  /// [gather] the export and pretty-print it to a UTF-8 JSON byte buffer
  /// (two-space indent so the file is human-skimmable when opened).
  Future<Uint8List> exportJson(ExportSources sources) async {
    final Map<String, dynamic> doc = await gather(sources);
    final String pretty = const JsonEncoder.withIndent('  ').convert(doc);
    return Uint8List.fromList(utf8.encode(pretty));
  }

  /// Full path: gather → encode → hand to [sharer]. The Settings "Back up
  /// my data" row calls this. Returns the suggested filename so the caller
  /// can surface it (e.g. in a confirmation snackbar) if it wants.
  Future<String> exportAndShare(
    ExportSources sources,
    DataFileSharer sharer,
  ) async {
    final Uint8List bytes = await exportJson(sources);
    final String filename = _filename(clock());
    await sharer.shareFile(bytes, filename: filename, mimeType: mimeType);
    return filename;
  }

  /// Restore a previously-exported [doc] into [sources] (Issue #20).
  ///
  /// The inverse of [gather]: parse each section back through its model's
  /// `fromJson` and upsert it. Upserts are idempotent (insert-or-replace by
  /// id), so importing into a non-empty store merges by id rather than
  /// duplicating — and re-importing the same file twice is a no-op.
  ///
  /// **Order matters for FK integrity** (see `lib/db/tables.dart`): parents
  /// are written before the rows that reference them — medications +
  /// windows before window entries + dose logs, providers before
  /// appointments, caregivers before memberships.
  ///
  /// Unknown future sections are ignored (a forward-compatible read);
  /// missing sections are treated as empty. Returns the number of records
  /// written across every section so a caller can confirm the restore.
  Future<int> importInto(ExportSources sources, Map<String, dynamic> doc) async {
    int written = 0;

    // ── singletons + journal ───────────────────────────────────────────
    for (final Patient p in _decodeList(doc, 'patients', Patient.fromJson)) {
      await sources.storage.upsertPatient(p);
      written++;
    }
    final Object? settingsJson = doc['settings'];
    if (settingsJson is Map<String, dynamic>) {
      await sources.storage.updateSettings(AppSettings.fromJson(settingsJson));
      written++;
    }
    for (final JournalEntry e
        in _decodeList(doc, 'journalEntries', JournalEntry.fromJson)) {
      await sources.storage.insertJournalEntry(e);
      written++;
    }

    // ── medications (parents) → windows → entries → logs ───────────────
    for (final Medication m
        in _decodeList(doc, 'medications', Medication.fromJson)) {
      await sources.medications.upsertMedication(m);
      written++;
    }
    for (final DoseWindow w
        in _decodeList(doc, 'doseWindows', DoseWindow.fromJson)) {
      await sources.medications.upsertWindow(w);
      written++;
    }
    for (final MedicationWindowEntry e in _decodeList(
        doc, 'medicationWindowEntries', MedicationWindowEntry.fromJson)) {
      await sources.medications.upsertEntry(e);
      written++;
    }
    for (final DoseLog l in _decodeList(doc, 'doseLogs', DoseLog.fromJson)) {
      await sources.medications.upsertDoseLog(l);
      written++;
    }

    // ── providers (parents) → appointments ─────────────────────────────
    for (final Provider p
        in _decodeList(doc, 'providers', Provider.fromJson)) {
      await sources.providers.upsertProvider(p);
      written++;
    }
    for (final Appointment a
        in _decodeList(doc, 'appointments', Appointment.fromJson)) {
      await sources.appointments.upsertAppointment(a);
      written++;
    }

    // ── standalone tables ──────────────────────────────────────────────
    for (final HealthLogEntry e
        in _decodeList(doc, 'healthLogEntries', HealthLogEntry.fromJson)) {
      await sources.healthLog.upsert(e);
      written++;
    }
    for (final CarePlanRoutine r
        in _decodeList(doc, 'carePlanRoutines', CarePlanRoutine.fromJson)) {
      await sources.carePlan.upsert(r);
      written++;
    }
    for (final EmergencyCard c
        in _decodeList(doc, 'emergencyCards', EmergencyCard.fromJson)) {
      await sources.documents.upsertEmergencyCard(c);
      written++;
    }
    for (final PowerOfAttorneyDoc d in _decodeList(
        doc, 'powerOfAttorneyDocs', PowerOfAttorneyDoc.fromJson)) {
      await sources.documents.upsertPoa(d);
      written++;
    }
    for (final IdentificationDoc d
        in _decodeList(doc, 'identificationDocs', IdentificationDoc.fromJson)) {
      await sources.documents.upsertId(d);
      written++;
    }

    // ── caregivers (parents) → memberships ─────────────────────────────
    for (final Caregiver c
        in _decodeList(doc, 'caregivers', Caregiver.fromJson)) {
      await sources.careCircle.upsertCaregiver(c);
      written++;
    }
    for (final CareCircleMembership m in _decodeList(
        doc, 'careCircleMemberships', CareCircleMembership.fromJson)) {
      await sources.careCircle.upsertMembership(m);
      written++;
    }

    // ── Care Team tables ───────────────────────────────────────────────
    for (final CareEvent e
        in _decodeList(doc, 'careEvents', CareEvent.fromJson)) {
      await sources.careEvents.upsertEvent(e);
      written++;
    }
    for (final CareTask t in _decodeList(doc, 'careTasks', CareTask.fromJson)) {
      await sources.careTasks.upsertTask(t);
      written++;
    }
    for (final CareShift s
        in _decodeList(doc, 'careShifts', CareShift.fromJson)) {
      await sources.careShifts.upsertShift(s);
      written++;
    }
    for (final Expense e in _decodeList(doc, 'expenses', Expense.fromJson)) {
      await sources.expenses.upsertExpense(e);
      written++;
    }

    return written;
  }

  /// `careblazers-backup-YYYY-MM-DD.json` from [at]'s calendar date.
  String _filename(DateTime at) {
    final String y = at.year.toString().padLeft(4, '0');
    final String m = at.month.toString().padLeft(2, '0');
    final String d = at.day.toString().padLeft(2, '0');
    return '$filenamePrefix-$y-$m-$d.json';
  }
}

/// Map [items] through [toJson], yielding a `List<Map<String, dynamic>>`
/// the JSON encoder serialises directly. Centralised so each section line
/// in [DataExporter.gather] stays a single expression.
///
/// Resilient by design (Issue #20 hardening): a single row whose [toJson]
/// throws — a legacy/corrupt blob, an enum that no longer decodes — is
/// *skipped* rather than aborting the entire backup. The goal is that the
/// caregiver always gets a file with everything that *could* be exported,
/// not an all-or-nothing failure on one bad record.
List<Map<String, dynamic>> _toJsonList<T>(
  List<T> items,
  Map<String, dynamic> Function(T) toJson,
) {
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (final T item in items) {
    try {
      out.add(toJson(item));
    } catch (_) {
      // Skip the unserialisable row; the rest of the section still exports.
    }
  }
  return out;
}

/// Decode the `List<Map>` section at [key] in [doc] back through [fromJson].
/// A missing or non-list section yields an empty list so [DataExporter
/// .importInto] tolerates a partial / older export. Each element is asserted
/// to be a JSON object before decode.
List<T> _decodeList<T>(
  Map<String, dynamic> doc,
  String key,
  T Function(Map<String, dynamic>) fromJson,
) {
  final Object? raw = doc[key];
  if (raw is! List) return <T>[];
  return <T>[
    for (final Object? item in raw)
      if (item is Map<String, dynamic>) fromJson(item),
  ];
}

/// Riverpod-wired exporter (Issue #20). The Settings "Back up my data" row
/// reads `ref.watch(dataExporterProvider)` and calls [DataExporter
/// .exportAndShare]. Stateless, so kept alive to avoid per-watch
/// construction — same pattern [pdfExporterProvider] uses.
@Riverpod(keepAlive: true)
DataExporter dataExporter(Ref ref) => const DataExporter();

/// Riverpod-wired file sharer (Issue #20). Widgets read
/// `ref.watch(dataFileSharerProvider)`; production gets the real
/// `share_plus` impl, and the Settings widget test overrides it with
/// [RecordingDataFileSharer] — same seam shape as [sharerProvider].
@Riverpod(keepAlive: true)
DataFileSharer dataFileSharer(Ref ref) => const RealDataFileSharer();

/// Assemble the live [ExportSources] from the repository providers (Issue
/// #20). Kept as a provider so the Settings row gathers through one watch;
/// the unit test bypasses this and builds [ExportSources] against
/// test-instance repos directly.
@riverpod
ExportSources exportSources(Ref ref) => (
      storage: ref.watch(storageProvider),
      medications: ref.watch(medicationRepositoryProvider),
      appointments: ref.watch(appointmentRepositoryProvider),
      providers: ref.watch(providerRepositoryProvider),
      healthLog: ref.watch(healthLogRepositoryProvider),
      carePlan: ref.watch(carePlanRepositoryProvider),
      documents: ref.watch(documentsRepositoryProvider),
      careCircle: ref.watch(careCircleRepositoryProvider),
      careEvents: ref.watch(careEventsRepositoryProvider),
      careTasks: ref.watch(careTasksRepositoryProvider),
      careShifts: ref.watch(careShiftsRepositoryProvider),
      expenses: ref.watch(expensesRepositoryProvider),
    );
