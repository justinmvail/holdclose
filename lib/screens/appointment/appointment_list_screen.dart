import 'dart:async';

import 'package:flutter/material.dart';
// `Provider` in [models/appointment.dart] collides with riverpod's
// own `Provider` class — `hide` keeps the model name resolvable in
// this file without forcing every callsite to alias.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/appointment.dart';
import '../../models/appointment_draft.dart';
import '../../providers/appointment_scanner_provider.dart';
import '../../services/appointment_repository.dart';
import '../../services/appointment_scanner.dart';
import '../../theme.dart';
import '../../widgets/form/form_error_view.dart';
import '../../widgets/form/format.dart';
import '../../widgets/path_header.dart';
import '../scan_capture.dart';

part 'appointment_list_screen.g.dart';

/// Re-entrancy guard for the "Add appointment" affordances (the list
/// FAB / empty-state CTA + the calendar's add FAB). A fast double-tap
/// used to push `/appointments/new` twice and let the caregiver save two
/// identical rows ("got added twice" alpha bug, 2026-06-07). Each tap
/// calls [shouldOpen]; a second call within [_window] of the first is
/// dropped. Exposed as a single shared instance so the two surfaces
/// debounce against the same clock — tests reset it via [reset].
class AppointmentAddDebounce {
  AppointmentAddDebounce({DateTime Function() clock = DateTime.now})
      : _clock = clock;

  final DateTime Function() _clock;
  static const Duration _window = Duration(milliseconds: 700);
  DateTime? _last;

  /// True if enough time has elapsed since the last accepted open (or
  /// there was none) — and records this open. A rapid second call returns
  /// false so the duplicate navigation never happens.
  bool shouldOpen() {
    final DateTime now = _clock();
    final DateTime? last = _last;
    if (last != null && now.difference(last) < _window) return false;
    _last = now;
    return true;
  }

  /// Clear the debounce so the next [shouldOpen] always passes. Tests
  /// call this between cases that each expect a fresh open.
  void reset() => _last = null;
}

/// Process-wide shared debounce both add affordances consult.
final AppointmentAddDebounce appointmentAddDebounce = AppointmentAddDebounce();

/// One row in the appointment list — an [Appointment] paired with the
/// already-resolved [Provider] so each card can render the provider's
/// name without one query per row (TASKS.md Phase 12.6).
///
/// [provider] is null when the appointment's [Appointment.providerId]
/// points at a row that has since been deleted (a defensive case the FK
/// `ON DELETE CASCADE` already covers — but the screen renders a soft
/// fallback rather than crashing).
@immutable
class AppointmentListItem {
  const AppointmentListItem({required this.appointment, this.provider});

  final Appointment appointment;
  final Provider? provider;
}

/// Bundle of the upcoming + past splits the list screen renders as two
/// labeled sections (TASKS.md Phase 12.6). Computed once per provider
/// run so the screen reads through a single [AsyncValue] rather than
/// stitching two providers together at the widget level.
@immutable
class AppointmentListData {
  const AppointmentListData({required this.upcoming, required this.past});

  final List<AppointmentListItem> upcoming;
  final List<AppointmentListItem> past;

  bool get isEmpty => upcoming.isEmpty && past.isEmpty;
}

/// Async view of every appointment grouped by [AppointmentListData.upcoming]
/// + [AppointmentListData.past], with each row's provider already
/// resolved (TASKS.md Phase 12.6).
///
/// Tests override [appointmentRepositoryBackendProvider] with an
/// in-memory repo so the future resolves synchronously inside the test
/// harness. The form (Phase 12.7) and the detail screen invalidate
/// this provider after a successful insert/edit so the list reflects
/// the change.
@Riverpod(keepAlive: false)
Future<AppointmentListData> appointmentList(Ref ref) async {
  final AppointmentRepository repo =
      ref.watch(appointmentRepositoryBackendProvider);
  final List<Appointment> upcoming = await repo.upcoming();
  final List<Appointment> past = await repo.past();
  final List<Provider> providers = await repo.listProviders();
  final Map<String, Provider> byId = <String, Provider>{
    for (final Provider p in providers) p.id: p,
  };
  AppointmentListItem wrap(Appointment a) =>
      AppointmentListItem(appointment: a, provider: byId[a.providerId]);
  return AppointmentListData(
    upcoming: upcoming.map(wrap).toList(growable: false),
    past: past.map(wrap).toList(growable: false),
  );
}

/// Wall clock the list screen samples when formatting "Today / Tomorrow"
/// card subtitles. Overridable so widget + golden tests stay stable
/// across host time — same pattern [medicationListClockProvider] uses.
@Riverpod(keepAlive: true)
DateTime Function() appointmentListClock(Ref ref) => DateTime.now;

/// Appointment list screen at `/appointments` (TASKS.md Phase 12.6).
///
/// Two states:
///   - Empty: a soft headline + a single salmon "Add an appointment" CTA.
///   - Populated: an "Upcoming" section (chronological) followed by a
///     "Past" section (most-recent first). Each card shows the
///     date+time, provider name, location, and agenda item count.
///
/// The screen never reaches into the database directly — it reads
/// through [appointmentListProvider] and the form (Phase 12.7) writes
/// through [appointmentRepositoryProvider], same indirection the other
/// repository-backed surfaces use.
class AppointmentListScreen extends ConsumerWidget {
  const AppointmentListScreen({super.key});

  static const Key listKey = Key('appointment-list-list');
  static const Key emptyStateKey = Key('appointment-list-empty');
  static const Key emptyCtaKey = Key('appointment-list-empty-cta');
  static const Key fabKey = Key('appointment-list-fab');
  static const Key scanButtonKey = Key('appointment-list-scan');
  static const Key upcomingSectionKey = Key('appointment-list-upcoming');
  static const Key pastSectionKey = Key('appointment-list-past');

  /// Stable per-card key derived from the appointment id. Tests tap by
  /// id rather than by visible date so a copy edit doesn't break them.
  static Key cardKey(String appointmentId) =>
      Key('appointment-list-card-$appointmentId');

  /// Stable per-card key for the agenda-count chip — tests assert the
  /// count without scoping through the card.
  static Key agendaCountKey(String appointmentId) =>
      Key('appointment-list-agenda-$appointmentId');

  /// Push the add form, guarding against a fast double-tap pushing it
  /// twice. A double-tap on the FAB / empty-state CTA used to push
  /// `/appointments/new` twice — the caregiver then saved both stacked
  /// forms and landed two identical appointment rows (alpha bug: "got
  /// added twice", 2026-06-07).
  ///
  /// `ModalRoute.isCurrent` alone doesn't catch a same-frame double-tap
  /// (it only flips after the route transition starts a frame later), so
  /// we pair it with a short time-based debounce that drops a second tap
  /// landing within [_addDebounce] of the first. The debounce is shared
  /// with the calendar's add affordance via [appointmentAddDebounce].
  static void _openAddForm(BuildContext context) {
    if (!appointmentAddDebounce.shouldOpen()) return;
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      context.push('/appointments/new');
    }
  }

  /// Scan an appointment card → pre-fill the add form with the AI's read.
  /// A cancelled pick does nothing; an unreadable card still opens the form
  /// (blank) with a hint, so nothing is ever saved without the caregiver.
  static Future<void> _scanAppointment(
      BuildContext context, WidgetRef ref) async {
    final AppointmentScanner scanner = ref.read(appointmentScannerProvider);
    final AppointmentDraft? draft = await captureScanDraft<AppointmentDraft>(
      context,
      ref,
      extract: (String path) => scanner.extractFromImage(imagePath: path),
      emptyDraft: const AppointmentDraft(),
    );
    if (draft == null || !context.mounted) return; // cancelled
    if (draft.isEmpty) showScanCouldNotReadHint(context);
    unawaited(context.push('/appointments/new', extra: draft));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<AppointmentListData> async =
        ref.watch(appointmentListProvider);
    final DateTime now = ref.watch(appointmentListClockProvider)();

    return Scaffold(
      backgroundColor: context.cb.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: PathHeader(
                breadcrumbs: const <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Appointments'),
                ],
                title: 'Appointments',
                backLabel: 'Back to Care',
                leadingIcon: Icons.event_outlined,
                // Scan an appointment card → pre-fill the add form.
                trailing: IconButton(
                  key: AppointmentListScreen.scanButtonKey,
                  tooltip: 'Scan an appointment card',
                  iconSize: 24,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 24, height: 24),
                  visualDensity: VisualDensity.compact,
                  color: context.cb.primary,
                  icon: const Icon(Icons.document_scanner_outlined),
                  onPressed: () => _scanAppointment(context, ref),
                ),
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => FormErrorView(
                    message: "We couldn't load the appointment list.\n$e"),
                data: (AppointmentListData data) {
                  if (data.isEmpty) return const _EmptyState();
                  return _PopulatedList(data: data, now: now);
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: async.maybeWhen(
        data: (AppointmentListData data) {
          if (data.isEmpty) return null;
          return _AddAppointmentFab(
            onPressed: () => _openAddForm(context),
          );
        },
        orElse: () => null,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: AppointmentListScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.event_outlined,
            size: 56,
            color: context.cb.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'No appointments yet.',
            style: textTheme.headlineMedium?.copyWith(
              color: context.cb.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Add the next visit so you can prep the agenda ahead of time '
            'and check items off in the waiting room.',
            style: textTheme.bodyLarge?.copyWith(
              color: context.cb.text,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label:
                'Add an appointment. Open the add-appointment form.',
            child: ElevatedButton.icon(
              key: AppointmentListScreen.emptyCtaKey,
              onPressed: () => AppointmentListScreen._openAddForm(context),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                'Add an appointment',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: context.cb.cta,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PopulatedList extends StatelessWidget {
  const _PopulatedList({required this.data, required this.now});

  final AppointmentListData data;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    // Flatten the two sections into one item list so the (unbounded)
    // history builds its rows lazily. Render order is unchanged: the
    // Upcoming header + its cards, then the Past header + its cards.
    final List<_ListRow> rows = <_ListRow>[
      if (data.upcoming.isNotEmpty) ...<_ListRow>[
        const _HeaderRow(
          headerKey: AppointmentListScreen.upcomingSectionKey,
          label: 'Upcoming',
        ),
        for (final AppointmentListItem item in data.upcoming) _CardRow(item),
      ],
      if (data.past.isNotEmpty) ...<_ListRow>[
        const _HeaderRow(
          headerKey: AppointmentListScreen.pastSectionKey,
          label: 'Past',
        ),
        for (final AppointmentListItem item in data.past) _CardRow(item),
      ],
    ];
    return ListView.builder(
      key: AppointmentListScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: rows.length,
      itemBuilder: (BuildContext context, int i) {
        switch (rows[i]) {
          case _HeaderRow(
              headerKey: final Key headerKey,
              label: final String label,
            ):
            return _SectionHeader(key: headerKey, label: label);
          case _CardRow(item: final AppointmentListItem item):
            return _AppointmentCard(item: item, now: now);
        }
      },
    );
  }
}

/// One row in the flattened list — a section header or an appointment
/// card — so a single lazy ListView scrolls both sections.
sealed class _ListRow {
  const _ListRow();
}

class _HeaderRow extends _ListRow {
  const _HeaderRow({required this.headerKey, required this.label});

  /// Stable key forwarded onto the rendered header (tests target
  /// [AppointmentListScreen.upcomingSectionKey] / `pastSectionKey`).
  final Key headerKey;
  final String label;
}

class _CardRow extends _ListRow {
  const _CardRow(this.item);
  final AppointmentListItem item;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        label,
        style: textTheme.titleLarge?.copyWith(
          color: context.cb.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AppointmentCard extends StatelessWidget {
  const _AppointmentCard({required this.item, required this.now});

  final AppointmentListItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Appointment appt = item.appointment;
    final String providerName = item.provider?.name ?? 'Unknown provider';
    final String when = _formatWhen(appt.startsAt, now);
    final int agendaCount = appt.agenda.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: '$providerName, $when. ${_statusLabel(appt.status)}. '
            '${_agendaCountLabel(agendaCount)}. Double-tap to open.',
        child: Material(
          color: context.cb.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: AppointmentListScreen.cardKey(appt.id),
            borderRadius: BorderRadius.circular(16),
            onTap: () => context.push('/appointments/${appt.id}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          when,
                          style: textTheme.titleLarge?.copyWith(
                            color: context.cb.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusChip(status: appt.status),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    providerName,
                    style: textTheme.bodyLarge?.copyWith(
                      color: context.cb.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (appt.location.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      appt.location,
                      style: textTheme.bodyMedium?.copyWith(
                        color: context.cb.primarySoft,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Padding(
                    key: AppointmentListScreen.agendaCountKey(appt.id),
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _agendaCountLabel(agendaCount),
                      style: textTheme.bodyMedium?.copyWith(
                        color: context.cb.primarySoft,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final AppointmentStatus status;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color fg = _statusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _statusLabel(status),
        style: textTheme.bodyMedium?.copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AddAppointmentFab extends StatelessWidget {
  const _AddAppointmentFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add an appointment. Open the add-appointment form.',
      child: FloatingActionButton.extended(
        key: AppointmentListScreen.fabKey,
        heroTag: 'appointments-add-fab',
        onPressed: onPressed,
        backgroundColor: context.cb.cta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Add appointment',
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

/// "Today, 2:30 PM" / "Tomorrow, 2:30 PM" / "Jun 15, 2:30 PM" — uses
/// "Today" / "Tomorrow" for the two nearest days and falls back to a
/// month-day stamp otherwise. The full year is omitted: 12.6's scope is
/// the v1 calendar window and the year is implied by context.
String _formatWhen(DateTime at, DateTime now) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime tomorrow = today.add(const Duration(days: 1));
  final DateTime atDay = DateTime(at.year, at.month, at.day);
  final String clock = formatClock12h(at);
  if (atDay == today) return 'Today, $clock';
  if (atDay == tomorrow) return 'Tomorrow, $clock';
  final String month = monthAbbreviations[at.month - 1];
  return '$month ${at.day}, $clock';
}

String _agendaCountLabel(int n) {
  if (n == 0) return 'No agenda items yet';
  if (n == 1) return '1 agenda item';
  return '$n agenda items';
}

String _statusLabel(AppointmentStatus status) {
  switch (status) {
    case AppointmentStatus.upcoming:
      return 'Upcoming';
    case AppointmentStatus.completed:
      return 'Completed';
    case AppointmentStatus.canceled:
      return 'Canceled';
  }
}

Color _statusColor(BuildContext context, AppointmentStatus status) {
  switch (status) {
    case AppointmentStatus.upcoming:
      return context.cb.cta;
    case AppointmentStatus.completed:
      return context.cb.success;
    case AppointmentStatus.canceled:
      return context.cb.primarySoft;
  }
}
