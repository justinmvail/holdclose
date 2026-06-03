import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/appointment.dart';
import '../models/medication.dart';
import '../models/settings.dart';
import '../providers/notifications_provider.dart';
import '../providers/settings_provider.dart';
import 'appointment_repository.dart';
import 'medication_repository.dart';

part 'notification_scheduler.g.dart';

/// Bridges the medication + appointment repositories to the
/// [NotificationsProvider] (BUILD_SPEC.md Phase 12.8).
///
/// One entry per surface — the medication form's submit path calls
/// [rescheduleForMedication]; the appointment form calls
/// [rescheduleForAppointment]; deletions route through the matching
/// `cancelFor*` helpers. Each schedule pass cancels every prior
/// reminder for the same id first so an edit lands a clean slate
/// rather than two overlapping reminders.
///
/// Honors the [AppSettings] gates:
///   - [AppSettings.notificationsEnabled] OFF → cancel only, never schedule
///
/// The "first add prompts for permission" flow is intentionally kept
/// out of this service — the form screens own the UI choice. This
/// service only schedules; the screens decide whether to ask first.
class NotificationScheduler {
  NotificationScheduler({
    required this.notifications,
    required this.medicationRepository,
    required this.appointmentRepository,
    required this.settings,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NotificationsProvider notifications;
  final MedicationRepository medicationRepository;
  final AppointmentRepository appointmentRepository;
  final AppSettings settings;
  final DateTime Function() _clock;

  bool get _medsEnabled => settings.notificationsEnabled;

  bool get _apptsEnabled => settings.notificationsEnabled;

  /// Cancel-and-(re)schedule every reminder for [medicationId]. Reads
  /// the current [DoseSchedule] rows through
  /// [MedicationRepository.schedulesFor] so the caller doesn't have
  /// to pass them in. No-op when the master/per-feature gates are off
  /// — but still cancels prior reminders so a freshly-disabled
  /// medication stops firing.
  Future<List<ScheduledNotification>> rescheduleForMedication(
      String medicationId) async {
    await _cancelMedicationReminders(medicationId);
    if (!_medsEnabled) return const <ScheduledNotification>[];
    final Medication? med =
        await medicationRepository.getMedication(medicationId);
    if (med == null) return const <ScheduledNotification>[];
    // After the v14 windows pivot, dose scheduling lives on
    // (DoseWindow + MedicationWindowEntry) pairs rather than on
    // per-medication DoseSchedule rows. Walk every entry attached to
    // this medication, fold in its window's anchor time, and forward
    // synthetic schedules to [doseReminders] so the notification
    // shapes stay identical.
    final List<MedicationWindowEntry> entries =
        await medicationRepository.entriesForMedication(medicationId);
    final List<WindowedEntry> windowed = <WindowedEntry>[];
    for (final MedicationWindowEntry entry in entries) {
      final DoseWindow? window =
          await medicationRepository.getWindow(entry.windowId);
      if (window == null || window.isAsNeeded) continue;
      windowed.add(WindowedEntry(window: window, entry: entry));
    }
    final List<ScheduledNotification> targets = doseRemindersForWindows(
      medication: med,
      windowed: windowed,
      now: _clock(),
    );
    for (final ScheduledNotification n in targets) {
      await notifications.schedule(n);
    }
    return targets;
  }

  /// Cancel every dose reminder for [medicationId] without
  /// rescheduling. Used by the medication-delete path + the "trackers
  /// off" master toggle.
  Future<void> cancelForMedication(String medicationId) =>
      _cancelMedicationReminders(medicationId);

  /// Cancel-and-(re)schedule the 24h + 1h reminders for
  /// [appointmentId]. Loads the appointment + provider through the
  /// repository so callers don't have to pass them in. No-op when the
  /// gates are off — still cancels prior reminders for the same
  /// reason as the medication path.
  Future<List<ScheduledNotification>> rescheduleForAppointment(
      String appointmentId) async {
    await _cancelAppointmentReminders(appointmentId);
    if (!_apptsEnabled) return const <ScheduledNotification>[];
    final Appointment? appt =
        await appointmentRepository.getAppointment(appointmentId);
    if (appt == null) return const <ScheduledNotification>[];
    final Provider? provider =
        await appointmentRepository.getProvider(appt.providerId);
    final List<ScheduledNotification> targets = appointmentReminders(
      appointment: appt,
      provider: provider,
      now: _clock(),
    );
    for (final ScheduledNotification n in targets) {
      await notifications.schedule(n);
    }
    return targets;
  }

  /// Cancel every reminder for [appointmentId] without rescheduling.
  Future<void> cancelForAppointment(String appointmentId) =>
      _cancelAppointmentReminders(appointmentId);

  /// Cancel-every-reminder-the-app-scheduled hammer (BUILD_SPEC.md
  /// Phase 12.8). The Settings → master "Use trackers" off toggle
  /// calls this so the caregiver flipping to lean-app mode mid-day
  /// doesn't keep getting pings.
  Future<void> cancelAll() => notifications.cancelAll();

  Future<void> _cancelMedicationReminders(String medicationId) async {
    final List<int> ids = <int>[
      for (int i = 0; i < 8; i++) doseNotificationId(medicationId, i),
    ];
    await notifications.cancelMany(ids);
  }

  Future<void> _cancelAppointmentReminders(String appointmentId) async {
    await notifications.cancelMany(<int>[
      appointmentNotificationId(appointmentId, 24),
      appointmentNotificationId(appointmentId, 1),
    ]);
  }
}

/// Riverpod-wired singleton (BUILD_SPEC.md Phase 12.8).
///
/// The medication + appointment form submit paths reach for this
/// provider after a successful upsert. Tests override the underlying
/// providers (notifications + the two repositories) with in-memory
/// fakes so the service runs against the same recording shape the
/// integration tour uses.
@Riverpod(keepAlive: true)
NotificationScheduler notificationScheduler(Ref ref) {
  return NotificationScheduler(
    notifications: ref.watch(notificationsProvider),
    medicationRepository: ref.watch(medicationRepositoryBackendProvider),
    appointmentRepository: ref.watch(appointmentRepositoryBackendProvider),
    settings: ref.watch(settingsProvider),
  );
}
