import 'package:flutter/material.dart';
// `Provider` in [models/appointment.dart] collides with riverpod's
// own `Provider` class — `hide` keeps the model name resolvable in
// this file without forcing every callsite to alias.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/appointment.dart';
import '../../providers/link_launcher_provider.dart';
import '../../providers/patient_timeline_provider.dart'
    show invalidatePatientTimeline;
import '../../services/appointment_repository.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';
import 'appointment_list_screen.dart';

part 'appointment_detail_screen.g.dart';

/// One appointment + its provider, both already loaded. The detail
/// screen reads through a single [AsyncValue] of this so a missing-row
/// case (deep link to a deleted appointment) is handled at one branch
/// instead of two stacked async builders.
@immutable
class AppointmentDetailData {
  const AppointmentDetailData({required this.appointment, this.provider});

  final Appointment appointment;
  final Provider? provider;
}

/// Async loader for the detail screen — fetches the appointment by id
/// plus its provider in a single pass (TASKS.md Phase 12.6).
///
/// Returns null when no appointment with [appointmentId] exists. The
/// screen renders a "not found" fallback in that case rather than
/// crashing.
@Riverpod(keepAlive: false)
Future<AppointmentDetailData?> appointmentDetail(
  Ref ref,
  String appointmentId,
) async {
  final AppointmentRepository repo =
      ref.watch(appointmentRepositoryBackendProvider);
  final Appointment? appt = await repo.getAppointment(appointmentId);
  if (appt == null) return null;
  final Provider? provider = await repo.getProvider(appt.providerId);
  return AppointmentDetailData(appointment: appt, provider: provider);
}

/// Appointment detail screen at `/appointments/:id` (TASKS.md Phase
/// 12.6).
///
/// Renders the full agenda as a checklist the caregiver crosses items
/// off in the waiting room, a free-text post-visit notes field, plus
/// two outbound actions:
///
///   - Call provider — `tel:` URL via [LinkLauncher].
///   - Get directions — `maps:` URL with the provider's address.
///
/// Every state-mutating action (checkbox toggle, notes save) round-
/// trips through [AppointmentRepository.upsertAppointment] so the
/// crossed-off state survives an app relaunch mid-visit, then
/// invalidates [appointmentDetailProvider] + [appointmentListProvider]
/// so the list-screen agenda count + the detail rebuild reflect the
/// change.
class AppointmentDetailScreen extends ConsumerStatefulWidget {
  const AppointmentDetailScreen({super.key, required this.appointmentId});

  final String appointmentId;

  static const Key scaffoldKey = Key('appointment-detail-scaffold');
  static const Key notFoundKey = Key('appointment-detail-not-found');
  static const Key callButtonKey = Key('appointment-detail-call');
  static const Key directionsButtonKey = Key('appointment-detail-directions');
  static const Key notesFieldKey = Key('appointment-detail-notes');
  static const Key saveNotesButtonKey = Key('appointment-detail-save-notes');
  static const Key agendaListKey = Key('appointment-detail-agenda');
  static const Key emptyAgendaKey = Key('appointment-detail-empty-agenda');
  static const Key deleteButtonKey = Key('appointment-detail-delete');
  static const Key confirmDeleteButtonKey =
      Key('appointment-detail-confirm-delete');

  static Key agendaItemKey(int index) =>
      Key('appointment-detail-agenda-item-$index');

  @override
  ConsumerState<AppointmentDetailScreen> createState() =>
      _AppointmentDetailScreenState();
}

class _AppointmentDetailScreenState
    extends ConsumerState<AppointmentDetailScreen> {
  final TextEditingController _notes = TextEditingController();
  String? _hydratedFor;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  /// Sync the notes controller with the persisted value the first time
  /// the appointment loads (or after a row swap). Subsequent rebuilds
  /// from a checkbox toggle keep whatever the caregiver has typed —
  /// we never clobber an in-flight edit with a stale provider value.
  void _hydrateNotes(Appointment appt) {
    if (_hydratedFor == appt.id) return;
    _notes.text = appt.notes ?? '';
    _hydratedFor = appt.id;
  }

  Future<void> _toggleAgendaItem(Appointment appt, int index) async {
    final Set<int> next = <int>{...appt.completedAgendaIndices};
    if (!next.add(index)) next.remove(index);
    final Appointment edited = appt.copyWith(completedAgendaIndices: next);
    await _persist(edited);
  }

  Future<void> _saveNotes(Appointment appt) async {
    final String trimmed = _notes.text.trim();
    final Appointment edited =
        appt.copyWith(notes: trimmed.isEmpty ? null : trimmed);
    await _persist(edited);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Notes saved.')),
    );
  }

  Future<void> _persist(Appointment edited) async {
    final AppointmentRepository repo =
        ref.read(appointmentRepositoryBackendProvider);
    await repo.upsertAppointment(edited);
    ref.invalidate(appointmentDetailProvider(widget.appointmentId));
    ref.invalidate(appointmentListProvider);
  }

  /// Hard-delete this appointment after a confirm. Unlike the status
  /// dropdown's soft-cancel (which keeps the row with a `canceled`
  /// status), this drops the row entirely via
  /// [AppointmentRepository.deleteAppointment]. Mirrors the medication
  /// form's `_confirmAndDelete`: confirm → repo delete → bust the list +
  /// the Home dashboard timeline → pop back to the list.
  Future<void> _confirmAndDelete(Appointment appt) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete appointment?'),
        content: const Text(
          'This removes the appointment, its agenda, and any post-visit '
          'notes for good. This can\'t be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: AppointmentDetailScreen.confirmDeleteButtonKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final AppointmentRepository repo =
        ref.read(appointmentRepositoryBackendProvider);
    await repo.deleteAppointment(appt.id);
    ref.invalidate(appointmentListProvider);
    // Home dashboard cards (Next Appointment, Recent Activity, Catch Me
    // Up) cache the appointment list at watch time — bust them too so the
    // deleted visit drops off without an app relaunch. Same cascade the
    // form's save path runs.
    invalidatePatientTimeline(ref);
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/appointments');
    }
  }

  Future<void> _callProvider(Provider provider) async {
    final String digits = _digitsOnly(provider.phone);
    if (digits.isEmpty) return;
    final LinkLauncher launcher = ref.read(linkLauncherProvider);
    await launcher.launch(Uri.parse('tel:$digits'));
  }

  Future<void> _openDirections(Provider provider) async {
    if (provider.address.trim().isEmpty) return;
    final LinkLauncher launcher = ref.read(linkLauncherProvider);
    final String encoded = Uri.encodeComponent(provider.address);
    await launcher.launch(Uri.parse('https://maps.apple.com/?q=$encoded'));
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<AppointmentDetailData?> async =
        ref.watch(appointmentDetailProvider(widget.appointmentId));

    return Scaffold(
      key: AppointmentDetailScreen.scaffoldKey,
      backgroundColor: context.cb.background,
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
                  PathHeaderCrumb(
                    label: 'Appointments',
                    route: '/appointments',
                  ),
                  PathHeaderCrumb(label: 'Appointment'),
                ],
                title: 'Appointment',
                backLabel: 'Back to Appointments',
                leadingIcon: Icons.event_note_outlined,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (AppointmentDetailData? data) {
                  if (data == null) return const _NotFoundView();
                  _hydrateNotes(data.appointment);
                  return _DetailBody(
                    data: data,
                    notesController: _notes,
                    onToggleAgenda: (int i) =>
                        _toggleAgendaItem(data.appointment, i),
                    onSaveNotes: () => _saveNotes(data.appointment),
                    onDelete: () => _confirmAndDelete(data.appointment),
                    onCall: () {
                      final Provider? p = data.provider;
                      if (p != null) _callProvider(p);
                    },
                    onDirections: () {
                      final Provider? p = data.provider;
                      if (p != null) _openDirections(p);
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
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.data,
    required this.notesController,
    required this.onToggleAgenda,
    required this.onSaveNotes,
    required this.onDelete,
    required this.onCall,
    required this.onDirections,
  });

  final AppointmentDetailData data;
  final TextEditingController notesController;
  final ValueChanged<int> onToggleAgenda;
  final VoidCallback onSaveNotes;
  final VoidCallback onDelete;
  final VoidCallback onCall;
  final VoidCallback onDirections;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Appointment appt = data.appointment;
    final Provider? provider = data.provider;
    final String providerName = provider?.name ?? 'Unknown provider';
    final bool canCall = provider != null &&
        _digitsOnly(provider.phone).isNotEmpty;
    final bool canDirections =
        provider != null && provider.address.trim().isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: <Widget>[
        Text(
          _formatFullDate(appt.startsAt),
          style: textTheme.headlineLarge?.copyWith(
            color: context.cb.primary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _formatClock(appt.startsAt),
          style: textTheme.titleLarge?.copyWith(
            color: context.cb.primarySoft,
          ),
        ),
        const SizedBox(height: 16),
        _ProviderCard(
          providerName: providerName,
          provider: provider,
          location: appt.location,
          status: appt.status,
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: _OutlineActionButton(
                buttonKey: AppointmentDetailScreen.callButtonKey,
                icon: Icons.phone,
                label: 'Call provider',
                onPressed: canCall ? onCall : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _OutlineActionButton(
                buttonKey: AppointmentDetailScreen.directionsButtonKey,
                icon: Icons.directions,
                label: 'Get directions',
                onPressed: canDirections ? onDirections : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Agenda',
          style: textTheme.titleLarge?.copyWith(
            color: context.cb.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Check items off as you cover them.',
          style: textTheme.bodyMedium?.copyWith(
            color: context.cb.primarySoft,
          ),
        ),
        const SizedBox(height: 8),
        _AgendaList(
          agenda: appt.agenda,
          completed: appt.completedAgendaIndices,
          onToggle: onToggleAgenda,
        ),
        const SizedBox(height: 24),
        Text(
          'Post-visit notes',
          style: textTheme.titleLarge?.copyWith(
            color: context.cb.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'What did the provider say? Anything to follow up on?',
          style: textTheme.bodyMedium?.copyWith(
            color: context.cb.primarySoft,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: AppointmentDetailScreen.notesFieldKey,
          controller: notesController,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: 'e.g. Trazodone trial — pharmacy will call.',
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Semantics(
            button: true,
            label: 'Save post-visit notes.',
            child: ElevatedButton(
              key: AppointmentDetailScreen.saveNotesButtonKey,
              onPressed: onSaveNotes,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.cb.cta,
                foregroundColor: Colors.white,
                minimumSize: const Size(140, 48),
              ),
              child: Text(
                'Save notes',
                style: textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Hard delete — distinct from the status dropdown's soft-cancel.
        // Low-emphasis text button at the bottom so it sits well clear of
        // the primary "Save notes" CTA and can't be fat-fingered.
        Semantics(
          button: true,
          label: 'Delete this appointment.',
          child: TextButton.icon(
            key: AppointmentDetailScreen.deleteButtonKey,
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete appointment'),
            style: TextButton.styleFrom(
              foregroundColor: context.cb.text.withValues(alpha: 0.65),
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.providerName,
    required this.provider,
    required this.location,
    required this.status,
  });

  final String providerName;
  final Provider? provider;
  final String location;
  final AppointmentStatus status;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: context.cb.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  providerName,
                  style: textTheme.titleLarge?.copyWith(
                    color: context.cb.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _StatusChip(status: status),
            ],
          ),
          if (provider != null && provider!.phone.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              provider!.phone,
              style: textTheme.bodyMedium?.copyWith(
                color: context.cb.text,
              ),
            ),
          ],
          if (location.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              location,
              style: textTheme.bodyMedium?.copyWith(
                color: context.cb.primarySoft,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AgendaList extends StatelessWidget {
  const _AgendaList({
    required this.agenda,
    required this.completed,
    required this.onToggle,
  });

  final List<String> agenda;
  final Set<int> completed;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    if (agenda.isEmpty) {
      return Padding(
        key: AppointmentDetailScreen.emptyAgendaKey,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No agenda items yet. Add things to ask while you wait.',
          style: textTheme.bodyMedium?.copyWith(
            color: context.cb.primarySoft,
          ),
        ),
      );
    }
    return Column(
      key: AppointmentDetailScreen.agendaListKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < agenda.length; i++)
          _AgendaTile(
            tileKey: AppointmentDetailScreen.agendaItemKey(i),
            label: agenda[i],
            checked: completed.contains(i),
            onChanged: () => onToggle(i),
          ),
      ],
    );
  }
}

class _AgendaTile extends StatelessWidget {
  const _AgendaTile({
    required this.tileKey,
    required this.label,
    required this.checked,
    required this.onChanged,
  });

  final Key tileKey;
  final String label;
  final bool checked;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Semantics(
        checked: checked,
        label: '$label. ${checked ? 'Checked off.' : 'Not yet covered.'} '
            'Double-tap to toggle.',
        child: InkWell(
          key: tileKey,
          borderRadius: BorderRadius.circular(12),
          onTap: onChanged,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    checked
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    color: checked
                        ? context.cb.success
                        : context.cb.primarySoft,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: textTheme.bodyLarge?.copyWith(
                      color: context.cb.text,
                      decoration: checked
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      decorationColor: context.cb.primarySoft,
                    ),
                  ),
                ),
              ],
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

class _OutlineActionButton extends StatelessWidget {
  const _OutlineActionButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: label,
      child: OutlinedButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(
          label,
          style: textTheme.labelLarge?.copyWith(
            color: context.cb.primary,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: context.cb.primary,
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(
            color: context.cb.primary.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

class _NotFoundView extends StatelessWidget {
  const _NotFoundView();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: AppointmentDetailScreen.notFoundKey,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.event_busy,
              size: 48,
              color: context.cb.primarySoft,
            ),
            const SizedBox(height: 16),
            Text(
              'This appointment is no longer on file.',
              style: textTheme.headlineMedium?.copyWith(
                color: context.cb.primary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          "We couldn't load this appointment.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

const List<String> _weekdays = <String>[
  'Monday', 'Tuesday', 'Wednesday', 'Thursday',
  'Friday', 'Saturday', 'Sunday',
];

const List<String> _months = <String>[
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _formatFullDate(DateTime t) =>
    '${_weekdays[t.weekday - 1]}, ${_months[t.month - 1]} ${t.day}';

String _formatClock(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
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

String _digitsOnly(String phone) =>
    phone.replaceAll(RegExp(r'[^0-9+]'), '');
