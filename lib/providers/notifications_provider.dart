import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/appointment.dart';
import '../models/care_task.dart';
import '../models/medication.dart';

part 'notifications_provider.g.dart';

/// One scheduled-or-immediate notification the app has asked the OS to
/// fire (BUILD_SPEC.md Phase 12.8).
///
/// [id] is a stable 32-bit int the platform plugin uses to cancel the
/// pending notification later; we derive it deterministically from the
/// owning medication / appointment id so a re-schedule (an edit pass)
/// can overwrite the prior reminder without leaking duplicates.
///
/// [deepLink] is the go_router path the notification tap routes to —
/// `/medications/today` for dose reminders, `/appointments/:id` for
/// appointment reminders. The `NotificationsProvider`'s tap-stream
/// surfaces this verbatim and the root app shell pumps it through
/// `context.go` (Phase 12.8 wiring).
@immutable
class ScheduledNotification {
  const ScheduledNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.scheduledFor,
    required this.deepLink,
  });

  final int id;
  final String title;
  final String body;
  final DateTime scheduledFor;
  final String deepLink;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScheduledNotification &&
          other.id == id &&
          other.title == title &&
          other.body == body &&
          other.scheduledFor == scheduledFor &&
          other.deepLink == deepLink);

  @override
  int get hashCode => Object.hash(id, title, body, scheduledFor, deepLink);

  @override
  String toString() =>
      'ScheduledNotification(id: $id, title: "$title", at: $scheduledFor)';
}

/// Platform-permission outcome of a [NotificationsProvider.requestPermission]
/// call (BUILD_SPEC.md Phase 12.8).
///
/// Distinct from the in-app `notificationsEnabled` settings toggle — a
/// caregiver can decline the OS prompt yet still want the tracker UIs
/// active; the app records the OS outcome here so the second add-med
/// tap doesn't re-prompt them.
enum NotificationPermission {
  granted,
  denied,

  /// First launch — the OS has neither granted nor denied; the
  /// scheduling code should request before scheduling.
  notDetermined,
}

/// Local-notifications backend (BUILD_SPEC.md Phase 12.8).
///
/// Two v1 implementations: [NoopNotificationsProvider] (records
/// scheduling calls in-memory, used for every `test/` widget + service
/// test, the integration tour, and as the fallback when the user has
/// declined the OS prompt) and the platform-bound `LocalNotifications
/// Provider` (wraps `flutter_local_notifications`, lives in
/// `local_notifications_provider.dart` so widget tests that import
/// this interface don't transitively pull the plugin).
///
/// The medication + appointment screens never import either concrete
/// class — they go through [notificationsProvider], which picks based
/// on the current [AppSettings.notificationsEnabled] toggle. Tests
/// override the provider directly with a recording fake.
abstract class NotificationsProvider {
  /// Ask the OS for notification permission. Re-asks are idempotent on
  /// both iOS and Android — the second call returns the cached grant
  /// state without re-prompting.
  Future<NotificationPermission> requestPermission();

  /// Current cached grant state without prompting. Used by the
  /// "permission ask on first add" flow to decide whether the
  /// add-med-success snackbar needs to mention "we'll remind you" or
  /// "turn on reminders in Settings".
  Future<NotificationPermission> currentPermission();

  /// Schedule a one-shot notification. Idempotent on
  /// [ScheduledNotification.id] — a re-schedule with the same id
  /// cancels the prior pending entry and replaces it.
  Future<void> schedule(ScheduledNotification notification);

  /// Cancel every pending notification whose id is in [ids]. No-op
  /// for ids that don't have a pending entry.
  Future<void> cancelMany(Iterable<int> ids);

  /// Cancel every pending notification this app scheduled.
  Future<void> cancelAll();

  /// Snapshot of every still-pending scheduled notification. Surface
  /// for tests + the demo tour to assert reminders landed without
  /// touching the platform layer.
  Future<List<ScheduledNotification>> pending();

  /// Stream of deep-link paths the OS hands back when the caregiver
  /// taps a fired notification. The root app shell listens and pumps
  /// each event through `context.go`. Empty in tests unless the test
  /// drives a tap synthetically.
  Stream<String> taps();
}

/// In-memory recording fake (BUILD_SPEC.md Phase 12.8 — the
/// test/integration-tour default).
///
/// Behaves like a real notifications backend for every contract the
/// app cares about (idempotent schedule by id, cancel by id, pending
/// snapshot, tap-stream) but never touches the OS — so widget tests
/// that wire a medication add flow can assert "two reminders were
/// scheduled for tomorrow" without spinning up the platform plugin.
///
/// [seedPermission] lets tests pin the requestPermission outcome — the
/// default ([NotificationPermission.granted]) matches the demo-mode
/// assumption that the caregiver said yes; flip to [denied] to drive
/// the "we'll silently skip the scheduling" path.
class NoopNotificationsProvider implements NotificationsProvider {
  NoopNotificationsProvider({
    NotificationPermission seedPermission = NotificationPermission.granted,
  }) : _permission = seedPermission;

  NotificationPermission _permission;
  final Map<int, ScheduledNotification> _pending =
      <int, ScheduledNotification>{};
  final StreamController<String> _taps = StreamController<String>.broadcast();
  int requestCount = 0;

  /// Test seam: pin the next [requestPermission] outcome without
  /// re-constructing the fake. Useful for "user declined the first
  /// prompt, granted the second" scenarios.
  void setPermission(NotificationPermission next) => _permission = next;

  /// Test seam: synthesize an OS tap so tour assertions can verify the
  /// deep-link plumbing without firing a real notification.
  void simulateTap(String deepLink) => _taps.add(deepLink);

  @override
  Future<NotificationPermission> requestPermission() async {
    requestCount++;
    return _permission;
  }

  @override
  Future<NotificationPermission> currentPermission() async => _permission;

  @override
  Future<void> schedule(ScheduledNotification notification) async {
    _pending[notification.id] = notification;
  }

  @override
  Future<void> cancelMany(Iterable<int> ids) async {
    for (final int id in ids) {
      _pending.remove(id);
    }
  }

  @override
  Future<void> cancelAll() async => _pending.clear();

  @override
  Future<List<ScheduledNotification>> pending() async {
    final List<ScheduledNotification> out = _pending.values.toList()
      ..sort((ScheduledNotification a, ScheduledNotification b) =>
          a.scheduledFor.compareTo(b.scheduledFor));
    return List<ScheduledNotification>.unmodifiable(out);
  }

  @override
  Stream<String> taps() => _taps.stream;

  /// Releases the broadcast tap controller — call from test
  /// tear-downs so the stream doesn't leak across tests.
  void dispose() {
    _taps.close();
  }
}

/// Riverpod-wired singleton (BUILD_SPEC.md Phase 12.8).
///
/// In v1 the default impl is always [NoopNotificationsProvider] — the
/// platform-bound `LocalNotificationsProvider` is wired in `main.dart`
/// via an override so widget tests don't transitively pull
/// `flutter_local_notifications` into their build. The override drops
/// in a real platform-backed instance for production runs.
///
/// `keepAlive: true` so a tab switch (which would otherwise dispose
/// the screen-scoped consumer) doesn't tear the singleton down and
/// wipe the pending-reminders cache.
///
/// Named `notificationsBackend` so the generated provider class is
/// [NotificationsBackendProvider] — keeps the slot open for the
/// abstract [NotificationsProvider] interface, matching the
/// `medicationRepositoryBackend` / `appointmentRepositoryBackend`
/// naming convention.
@Riverpod(keepAlive: true)
NotificationsProvider notificationsBackend(Ref ref) {
  final NoopNotificationsProvider fake = NoopNotificationsProvider();
  ref.onDispose(fake.dispose);
  return fake;
}

/// Natural-language alias matching the
/// `notificationsProvider` name the form + scheduler surfaces reach
/// for. Points at the same generated provider as
/// [notificationsBackendProvider].
final NotificationsBackendProvider notificationsProvider =
    notificationsBackendProvider;

// ─────────────────────────────────────────── Scheduling helpers ──

/// Derive a stable 32-bit notification id from a medication's id +
/// the per-day index of the dose's [TimeOfDay] (BUILD_SPEC.md Phase
/// 12.8).
///
/// `flutter_local_notifications` requires int ids (it stores them in a
/// signed-32 column on the Android side); deriving from the
/// medication id lets a re-schedule overwrite the prior pending entry
/// without us tracking a separate map. The `_doseIndex` slot encodes
/// which time-of-day within a multi-dose schedule this reminder is —
/// the same medication's 8 AM and 8 PM doses land on distinct ids.
int doseNotificationId(String medicationId, int doseIndex) {
  final int base = medicationId.hashCode & 0x00FFFFFF;
  return (base << 4) | (doseIndex & 0xF);
}

/// Derive a stable 32-bit notification id for an appointment reminder
/// (BUILD_SPEC.md Phase 12.8).
///
/// [hoursBefore] distinguishes the 24h vs 1h reminder — same
/// appointment lands on two pending entries.
int appointmentNotificationId(String appointmentId, int hoursBefore) {
  final int base = appointmentId.hashCode & 0x00FFFFFF;
  return (base << 4) | (hoursBefore == 24 ? 0xA : 0xB);
}

/// One (window, entry) pair handed to [doseRemindersForWindows]. The
/// scheduler resolves each medication's entries into this shape so the
/// reminder helper doesn't need to re-query the repository.
@immutable
class WindowedEntry {
  const WindowedEntry({required this.window, required this.entry});
  final DoseWindow window;
  final MedicationWindowEntry entry;
}

/// Compute [ScheduledNotification]s for a single [Medication]'s
/// (window, entry) pairs (BUILD_SPEC.md Phase 12.8, v14 windows pivot).
///
/// Walks each entry, anchors it on the window's [DoseWindow.anchorTime],
/// and emits one ScheduledNotification per pair at the next future
/// occurrence relative to [now]. As-needed windows (anchorTime == null)
/// are skipped. Weekly entries walk forward until the next valid
/// weekday lands in the future; out-of-window entries (paused, endsOn
/// already past) yield nothing.
///
/// The deep link is `/medications/today` so the tap drops the caregiver
/// into the dose-log screen ready to check the dose off.
List<ScheduledNotification> doseRemindersForWindows({
  required Medication medication,
  required List<WindowedEntry> windowed,
  required DateTime now,
}) {
  final List<ScheduledNotification> out = <ScheduledNotification>[];
  for (int i = 0; i < windowed.length; i++) {
    final WindowedEntry pair = windowed[i];
    final TimeOfDay? anchor = pair.window.anchorTime;
    if (anchor == null) continue; // as-needed
    final DateTime? endsOn = pair.entry.endsOn;
    final DateTime? next = _nextWindowedOccurrence(
      window: pair.window,
      entry: pair.entry,
      tod: anchor,
      now: now,
    );
    if (next == null) continue;
    if (endsOn != null && next.isAfter(endsOn)) continue;
    out.add(ScheduledNotification(
      id: doseNotificationId(medication.id, i),
      title: 'Time for ${medication.name}',
      body: '${medication.dosage} — tap to mark it taken.',
      scheduledFor: next,
      deepLink: '/medications/today',
    ));
  }
  return out;
}

/// Compute the 24h-before + 1h-before reminders for one [Appointment]
/// (BUILD_SPEC.md Phase 12.8).
///
/// Returns an empty list when both windows have already slipped past
/// — the form's edit path uses this so a caregiver dragging a visit
/// in the past doesn't accidentally land a "1 hour from now" reminder.
/// The deep link is `/appointments/:id` so the tap drops the
/// caregiver into the detail screen.
List<ScheduledNotification> appointmentReminders({
  required Appointment appointment,
  required Provider? provider,
  required DateTime now,
}) {
  if (appointment.status != AppointmentStatus.upcoming) return const <ScheduledNotification>[];
  final String who = provider?.name ?? 'your provider';
  final List<ScheduledNotification> out = <ScheduledNotification>[];
  final DateTime dayBefore =
      appointment.startsAt.subtract(const Duration(hours: 24));
  if (dayBefore.isAfter(now)) {
    out.add(ScheduledNotification(
      id: appointmentNotificationId(appointment.id, 24),
      title: 'Appointment tomorrow',
      body: 'Visit with $who is 24 hours out. Tap to review the agenda.',
      scheduledFor: dayBefore,
      deepLink: '/appointments/${appointment.id}',
    ));
  }
  final DateTime hourBefore =
      appointment.startsAt.subtract(const Duration(hours: 1));
  if (hourBefore.isAfter(now)) {
    out.add(ScheduledNotification(
      id: appointmentNotificationId(appointment.id, 1),
      title: 'Appointment in one hour',
      body: 'Visit with $who starts soon. Tap for directions + agenda.',
      scheduledFor: hourBefore,
      deepLink: '/appointments/${appointment.id}',
    ));
  }
  return out;
}

/// Derive a stable 32-bit notification id for a task's due-date reminder.
/// The `0xC` nibble keeps it clear of the dose (`0x0-0x7`) and appointment
/// (`0xA`/`0xB`) id spaces.
int taskNotificationId(String taskId) {
  final int base = taskId.hashCode & 0x00FFFFFF;
  return (base << 4) | 0xC;
}

/// One reminder at a follow-up task's [CareTask.dueAt] (the follow-up
/// tracker's reminders). Empty when the task has no due time, is already
/// completed, or the due time has passed — so clearing the date or marking
/// it done schedules nothing. Deep-links to the task board.
List<ScheduledNotification> taskReminders({
  required CareTask task,
  required DateTime now,
}) {
  final DateTime? due = task.dueAt;
  if (due == null || task.completedAt != null) {
    return const <ScheduledNotification>[];
  }
  if (!due.isAfter(now)) return const <ScheduledNotification>[];
  return <ScheduledNotification>[
    ScheduledNotification(
      id: taskNotificationId(task.id),
      title: 'Follow-up due',
      body: task.title,
      scheduledFor: due,
      deepLink: '/team/tasks',
    ),
  ];
}

DateTime? _nextWindowedOccurrence({
  required DoseWindow window,
  required MedicationWindowEntry entry,
  required TimeOfDay tod,
  required DateTime now,
}) {
  final DateTime startBase =
      entry.startsOn.isAfter(now) ? entry.startsOn : now;
  DateTime day = DateTime(startBase.year, startBase.month, startBase.day);
  for (int probe = 0; probe < 14; probe++) {
    if (entry.daysOfWeek.isNotEmpty &&
        !entry.daysOfWeek.contains(day.weekday)) {
      day = DateTime(day.year, day.month, day.day + 1);
      continue;
    }
    final DateTime candidate =
        DateTime(day.year, day.month, day.day, tod.hour, tod.minute);
    if (candidate.isAfter(now)) return candidate;
    day = DateTime(day.year, day.month, day.day + 1);
  }
  return null;
}
