import 'dart:math' as math;

import 'package:flutter/material.dart';
// `Provider` in [models/appointment.dart] collides with riverpod's
// own `Provider` class — `hide` keeps the model name resolvable in
// this file without forcing every callsite to alias.
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/appointment.dart';
import '../../providers/notifications_provider.dart';
import '../../providers/patient_timeline_provider.dart' show invalidatePatientTimeline;
import '../../services/appointment_repository.dart';
import '../../services/notification_scheduler.dart';
import '../../services/provider_repository.dart';
import '../../theme.dart';
import 'appointment_detail_screen.dart';
import 'appointment_list_screen.dart';

part 'appointment_form_screen.g.dart';

/// Mint a new id for the appointment / provider rows the form inserts.
/// Overridable for tests + the demo tour so id sequences are
/// deterministic — same shape as [MedicationFormScreen]'s id factory.
typedef AppointmentIdFactory = String Function();

String _defaultAppointmentIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return '$ms-$rand';
}

/// ID factory the form screen uses. Tests override this with a
/// monotonic counter so the appointment-id and provider-id pair is
/// stable across runs.
@Riverpod(keepAlive: true)
AppointmentIdFactory appointmentFormIdFactory(Ref ref) =>
    _defaultAppointmentIdFactory;

/// Wall clock the form samples when stamping a default `startsAt`. The
/// add path opens with a slot one week out at the next round hour;
/// tests override this for stable assertions.
@Riverpod(keepAlive: true)
DateTime Function() appointmentFormClock(Ref ref) => DateTime.now;

/// Async loader for the edit path — hydrates the form with the
/// appointment + its provider when an id is supplied (TASKS.md Phase
/// 12.7). Returns null for the add path.
@Riverpod(keepAlive: false)
Future<AppointmentDetailData?> appointmentFormHydration(
  Ref ref,
  String? appointmentId,
) async {
  if (appointmentId == null) return null;
  final AppointmentRepository repo =
      ref.watch(appointmentRepositoryBackendProvider);
  final Appointment? appt = await repo.getAppointment(appointmentId);
  if (appt == null) return null;
  final Provider? provider = await repo.getProvider(appt.providerId);
  return AppointmentDetailData(appointment: appt, provider: provider);
}

/// Loader for the provider dropdown — reads through
/// [providerRepositoryProvider] so the inline-add path (which writes
/// through the same repo) can `ref.invalidate(...)` this provider to
/// pick up the new row.
@Riverpod(keepAlive: false)
Future<List<Provider>> appointmentFormProviders(Ref ref) async {
  final ProviderRepository repo = ref.watch(providerRepositoryBackendProvider);
  return repo.listProviders();
}

/// Add/edit appointment form (TASKS.md Phase 12.7) at
/// `/appointments/new` and `/appointments/:id/edit`.
///
/// Covers every persisted [Appointment] field:
///   - Provider — dropdown of existing providers + an inline "Add new
///     provider…" option that opens an in-form sub-section (name,
///     role, phone, address, notes). Submitting the sub-section
///     creates the provider row through [ProviderRepository] and
///     selects it on the parent form so the caregiver never leaves
///     the appointment flow.
///   - Date + time — separate pickers (caregivers reach the date
///     picker more often than the time picker on the actual visit
///     day; splitting them keeps both single-tap).
///   - Duration — minutes, free-text but numeric-only.
///   - Location — free text. Defaults to the selected provider's
///     address when blank so a "same as on file" visit is one tap.
///   - Agenda — repeating list of single-line items the caregiver
///     adds/removes. Empty list is valid (the detail screen handles
///     the empty state).
///   - Status — dropdown of [AppointmentStatus] (defaults to
///     upcoming).
///   - Notes — multi-line optional free text.
///
/// Submit upserts the [Appointment], invalidates
/// [appointmentListProvider] + [appointmentDetailProvider] for the
/// edited row, then pops back. The edit path preserves
/// [Appointment.completedAgendaIndices] across agenda edits where the
/// index still makes sense (any index pointing past the new agenda
/// length is dropped — a removed item can't stay checked).
class AppointmentFormScreen extends ConsumerStatefulWidget {
  const AppointmentFormScreen({
    super.key,
    this.appointmentId,
    this.initialNotes,
  });

  /// Non-null on the edit path; null on the add path.
  final String? appointmentId;

  /// A spoken phrase captured from the Home Add sheet's voice button
  /// (Phase 14.14), pre-filled into the visit-notes textarea on the add
  /// path. Ignored on the edit path — a saved appointment's own notes
  /// hydrate the field instead.
  final String? initialNotes;

  bool get isEdit => appointmentId != null;

  static const Key formKey = Key('appointment-form');
  static const Key providerDropdownKey = Key('appointment-form-provider');
  static const Key addProviderToggleKey =
      Key('appointment-form-add-provider-toggle');
  static const Key newProviderNameFieldKey =
      Key('appointment-form-new-provider-name');
  static const Key newProviderRoleKey =
      Key('appointment-form-new-provider-role');
  static const Key newProviderPhoneFieldKey =
      Key('appointment-form-new-provider-phone');
  static const Key newProviderAddressFieldKey =
      Key('appointment-form-new-provider-address');
  static const Key newProviderNotesFieldKey =
      Key('appointment-form-new-provider-notes');
  static const Key newProviderSaveButtonKey =
      Key('appointment-form-new-provider-save');
  static const Key newProviderCancelButtonKey =
      Key('appointment-form-new-provider-cancel');
  static const Key dateFieldKey = Key('appointment-form-date');
  static const Key timeFieldKey = Key('appointment-form-time');
  static const Key durationFieldKey = Key('appointment-form-duration');
  static const Key locationFieldKey = Key('appointment-form-location');
  static const Key statusDropdownKey = Key('appointment-form-status');
  static const Key notesFieldKey = Key('appointment-form-notes');
  static const Key submitButtonKey = Key('appointment-form-submit');
  static const Key addAgendaButtonKey = Key('appointment-form-add-agenda');

  static Key agendaItemFieldKey(int index) =>
      Key('appointment-form-agenda-item-$index');
  static Key agendaItemRemoveKey(int index) =>
      Key('appointment-form-agenda-remove-$index');

  @override
  ConsumerState<AppointmentFormScreen> createState() =>
      _AppointmentFormScreenState();
}

class _AppointmentFormScreenState
    extends ConsumerState<AppointmentFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _duration = TextEditingController(text: '30');
  final TextEditingController _location = TextEditingController();
  final TextEditingController _notes = TextEditingController();

  // Inline "add new provider" sub-form state.
  bool _addingProvider = false;
  final TextEditingController _newProviderName = TextEditingController();
  final TextEditingController _newProviderPhone = TextEditingController();
  final TextEditingController _newProviderAddress = TextEditingController();
  final TextEditingController _newProviderNotes = TextEditingController();
  ProviderRole _newProviderRole = ProviderRole.doctor;
  String? _newProviderError;

  String? _selectedProviderId;
  late DateTime _startsAt;
  AppointmentStatus _status = AppointmentStatus.upcoming;
  List<TextEditingController> _agenda = <TextEditingController>[];
  // Tracks the per-index "this position was already covered" state
  // from the loaded appointment so an edit preserves crossed-off
  // items the caregiver hasn't touched.
  Set<int> _completedAgendaIndices = <int>{};

  bool _hydrated = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Default the "starts at" slot to one week out at the next round
    // hour — same shape iCal nudges new events to.
    final DateTime now = ref.read(appointmentFormClockProvider)();
    final DateTime nextHour = DateTime(now.year, now.month, now.day, now.hour)
        .add(const Duration(hours: 1));
    _startsAt = nextHour.add(const Duration(days: 7));

    // Voice intake (Phase 14.14): seed the notes textarea on the add
    // path. The edit path lets _hydrateFromAppointment overwrite this
    // with the saved appointment's own notes.
    if (!widget.isEdit) {
      final String seed = widget.initialNotes?.trim() ?? '';
      if (seed.isNotEmpty) _notes.text = seed;
    }
  }

  @override
  void dispose() {
    _duration.dispose();
    _location.dispose();
    _notes.dispose();
    _newProviderName.dispose();
    _newProviderPhone.dispose();
    _newProviderAddress.dispose();
    _newProviderNotes.dispose();
    for (final TextEditingController c in _agenda) {
      c.dispose();
    }
    super.dispose();
  }

  void _hydrateFromAppointment(AppointmentDetailData? data) {
    if (_hydrated) return;
    _hydrated = true;
    if (data == null) return;
    final Appointment a = data.appointment;
    _selectedProviderId = a.providerId;
    _startsAt = a.startsAt;
    _duration.text = a.durationMinutes.toString();
    _location.text = a.location;
    _notes.text = a.notes ?? '';
    _status = a.status;
    _agenda = <TextEditingController>[
      for (final String item in a.agenda) TextEditingController(text: item),
    ];
    _completedAgendaIndices = <int>{...a.completedAgendaIndices};
  }

  Future<void> _pickDate() async {
    final DateTime now = ref.read(appointmentFormClockProvider)();
    final DateTime first = DateTime(now.year - 1);
    final DateTime last = DateTime(now.year + 5);
    final DateTime initial = _startsAt.isBefore(first) ? now : _startsAt;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startsAt = DateTime(picked.year, picked.month, picked.day,
          _startsAt.hour, _startsAt.minute);
    });
  }

  Future<void> _pickTime() async {
    final TimeOfDay initial =
        TimeOfDay(hour: _startsAt.hour, minute: _startsAt.minute);
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startsAt = DateTime(_startsAt.year, _startsAt.month, _startsAt.day,
          picked.hour, picked.minute);
    });
  }

  void _addAgendaItem() {
    setState(() {
      _agenda = <TextEditingController>[..._agenda, TextEditingController()];
    });
  }

  void _removeAgendaItem(int index) {
    setState(() {
      final TextEditingController removed = _agenda[index];
      final List<TextEditingController> next = <TextEditingController>[
        ..._agenda,
      ]..removeAt(index);
      _agenda = next;
      removed.dispose();
      // Shift the completed-indices set down across the gap so the
      // remaining check-state still lines up with the new positions.
      final Set<int> shifted = <int>{};
      for (final int i in _completedAgendaIndices) {
        if (i == index) continue;
        shifted.add(i > index ? i - 1 : i);
      }
      _completedAgendaIndices = shifted;
    });
  }

  void _startInlineProvider() {
    setState(() {
      _addingProvider = true;
      _newProviderError = null;
      _newProviderName.clear();
      _newProviderPhone.clear();
      _newProviderAddress.clear();
      _newProviderNotes.clear();
      _newProviderRole = ProviderRole.doctor;
    });
  }

  void _cancelInlineProvider() {
    setState(() {
      _addingProvider = false;
      _newProviderError = null;
    });
  }

  Future<void> _saveInlineProvider() async {
    final String name = _newProviderName.text.trim();
    if (name.isEmpty) {
      setState(() => _newProviderError = 'Provider name is required.');
      return;
    }
    final AppointmentIdFactory mint =
        ref.read(appointmentFormIdFactoryProvider);
    final String newId = 'prov-${mint()}';
    final String notes = _newProviderNotes.text.trim();
    final String address = _newProviderAddress.text.trim();
    final Provider provider = Provider(
      id: newId,
      name: name,
      role: _newProviderRole,
      phone: _newProviderPhone.text.trim(),
      address: address,
      notes: notes.isEmpty ? null : notes,
    );
    final ProviderRepository repo =
        ref.read(providerRepositoryBackendProvider);
    await repo.upsertProvider(provider);
    // Refresh the dropdown so the new row is selectable; bust the
    // list so a re-render after submit sees the new provider's name.
    ref.invalidate(appointmentFormProvidersProvider);
    ref.invalidate(appointmentListProvider);

    if (!mounted) return;
    setState(() {
      _addingProvider = false;
      _newProviderError = null;
      _selectedProviderId = newId;
      // Pre-fill the appointment's location with the new provider's
      // address — the caregiver almost always wants this for an
      // in-office visit.
      if (_location.text.trim().isEmpty && address.isNotEmpty) {
        _location.text = address;
      }
    });
  }

  void _onProviderSelected(String? id, List<Provider> providers) {
    setState(() => _selectedProviderId = id);
    if (id != null && _location.text.trim().isEmpty) {
      for (final Provider p in providers) {
        if (p.id == id) {
          if (p.address.isNotEmpty) _location.text = p.address;
          break;
        }
      }
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) return;
    if (_selectedProviderId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Pick a provider or add a new one first.')),
      );
      return;
    }
    setState(() => _submitting = true);

    final AppointmentRepository repo =
        ref.read(appointmentRepositoryBackendProvider);
    final AppointmentIdFactory mint =
        ref.read(appointmentFormIdFactoryProvider);

    final String id = widget.appointmentId ?? 'appt-${mint()}';
    final List<String> agenda = <String>[
      for (final TextEditingController c in _agenda)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    final Set<int> completed = <int>{
      for (final int i in _completedAgendaIndices)
        if (i < agenda.length) i,
    };
    final int durationMinutes =
        int.tryParse(_duration.text.trim()) ?? 30;
    final String notes = _notes.text.trim();

    final Appointment appt = Appointment(
      id: id,
      providerId: _selectedProviderId!,
      startsAt: _startsAt,
      durationMinutes: durationMinutes,
      location: _location.text.trim(),
      agenda: agenda,
      completedAgendaIndices: completed,
      status: _status,
      notes: notes.isEmpty ? null : notes,
    );

    // BUILD_SPEC.md Phase 12.8 — capture the notifications + scheduler
    // refs BEFORE any await so a widget-unmount mid-submit doesn't
    // trigger "ref read after dispose" assertions. The scheduler is
    // keepAlive: true so the container holds the instance.
    final NotificationsProvider notifications =
        ref.read(notificationsProvider);
    final NotificationScheduler scheduler =
        ref.read(notificationSchedulerProvider);

    await repo.upsertAppointment(appt);
    ref.invalidate(appointmentListProvider);
    if (widget.appointmentId != null) {
      ref.invalidate(appointmentDetailProvider(widget.appointmentId!));
    }
    // Home dashboard cards (Next Appointment, Recent Activity, Catch
    // Me Up) cache the appointment list at watch time and don't see
    // the new row otherwise — see [invalidatePatientTimeline]'s doc
    // for why a `ref.watch` cascade doesn't cover them.
    invalidatePatientTimeline(ref);

    // Permission ask on first appointment add (idempotent across
    // re-runs) + schedule 24h + 1h reminders.
    final NotificationPermission current =
        await notifications.currentPermission();
    if (current == NotificationPermission.notDetermined) {
      await notifications.requestPermission();
    }
    await scheduler.rescheduleForAppointment(id);

    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/appointments');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<AppointmentDetailData?> hydration = ref.watch(
      appointmentFormHydrationProvider(widget.appointmentId),
    );
    final AsyncValue<List<Provider>> providersAsync =
        ref.watch(appointmentFormProvidersProvider);
    final ThemeData theme = Theme.of(context);
    final TextTheme textTheme = theme.textTheme;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: Text(widget.isEdit ? 'Edit appointment' : 'Add appointment'),
      ),
      body: SafeArea(
        child: hydration.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (AppointmentDetailData? data) {
            _hydrateFromAppointment(data);
            return Form(
              key: _formKey,
              child: ListView(
                key: AppointmentFormScreen.formKey,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: <Widget>[
                  _LabelledField(
                    label: 'Provider',
                    child: providersAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: LinearProgressIndicator(),
                      ),
                      error: (Object e, StackTrace _) => Text(
                        "We couldn't load your providers.",
                        style: textTheme.bodyMedium?.copyWith(
                          color: careblazersColors.text,
                        ),
                      ),
                      data: (List<Provider> providers) => _ProviderPicker(
                        providers: providers,
                        selectedId: _selectedProviderId,
                        onChanged: (String? id) =>
                            _onProviderSelected(id, providers),
                        onAddTapped: _startInlineProvider,
                      ),
                    ),
                  ),
                  if (_addingProvider) ...<Widget>[
                    const SizedBox(height: 12),
                    _buildNewProviderForm(textTheme),
                  ],
                  const SizedBox(height: 16),
                  _LabelledField(
                    label: 'Date',
                    child: _PickerField(
                      fieldKey: AppointmentFormScreen.dateFieldKey,
                      icon: Icons.calendar_today,
                      label: _formatDate(_startsAt),
                      onTap: _pickDate,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _LabelledField(
                    label: 'Time',
                    child: _PickerField(
                      fieldKey: AppointmentFormScreen.timeFieldKey,
                      icon: Icons.access_time,
                      label: _formatTime(_startsAt),
                      onTap: _pickTime,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _LabelledField(
                    label: 'Duration (minutes)',
                    child: TextFormField(
                      key: AppointmentFormScreen.durationFieldKey,
                      controller: _duration,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      decoration:
                          const InputDecoration(hintText: 'e.g. 30'),
                      validator: (String? v) {
                        final String trimmed = (v ?? '').trim();
                        if (trimmed.isEmpty) return 'Duration is required.';
                        final int? parsed = int.tryParse(trimmed);
                        if (parsed == null || parsed <= 0) {
                          return 'Use a positive whole number of minutes.';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  _LabelledField(
                    label: 'Location',
                    child: TextFormField(
                      key: AppointmentFormScreen.locationFieldKey,
                      controller: _location,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText:
                            'e.g. Marin General — Neurology, Suite 200',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _LabelledField(
                    label: 'Status',
                    child: DropdownButtonFormField<AppointmentStatus>(
                      key: AppointmentFormScreen.statusDropdownKey,
                      initialValue: _status,
                      isExpanded: true,
                      items: const <DropdownMenuItem<AppointmentStatus>>[
                        DropdownMenuItem<AppointmentStatus>(
                          value: AppointmentStatus.upcoming,
                          child: Text('Upcoming'),
                        ),
                        DropdownMenuItem<AppointmentStatus>(
                          value: AppointmentStatus.completed,
                          child: Text('Completed'),
                        ),
                        DropdownMenuItem<AppointmentStatus>(
                          value: AppointmentStatus.canceled,
                          child: Text('Canceled'),
                        ),
                      ],
                      onChanged: (AppointmentStatus? next) {
                        if (next == null) return;
                        setState(() => _status = next);
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Agenda',
                    style: textTheme.titleLarge?.copyWith(
                      color: careblazersColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Add bullets you want to cover. You'll check them off "
                    'in the waiting room.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: careblazersColors.primarySoft,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildAgendaEditor(textTheme),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: AppointmentFormScreen.addAgendaButtonKey,
                      onPressed: _addAgendaItem,
                      icon: const Icon(Icons.add),
                      label: const Text('Add agenda item'),
                      style: TextButton.styleFrom(
                        foregroundColor: careblazersColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _LabelledField(
                    label: 'Notes (optional)',
                    child: TextFormField(
                      key: AppointmentFormScreen.notesFieldKey,
                      controller: _notes,
                      maxLines: 4,
                      minLines: 2,
                      decoration: const InputDecoration(
                        hintText:
                            'e.g. Bring journal, ask about evening agitation.',
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    button: true,
                    label: widget.isEdit
                        ? 'Save changes to this appointment.'
                        : 'Save this appointment.',
                    child: ElevatedButton(
                      key: AppointmentFormScreen.submitButtonKey,
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: careblazersColors.cta,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        _submitting
                            ? 'Saving…'
                            : (widget.isEdit
                                ? 'Save changes'
                                : 'Save appointment'),
                        style: textTheme.labelLarge
                            ?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildAgendaEditor(TextTheme textTheme) {
    if (_agenda.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No agenda items yet.',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primarySoft,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < _agenda.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: AppointmentFormScreen.agendaItemFieldKey(i),
                    controller: _agenda[i],
                    decoration: InputDecoration(
                      hintText: 'Agenda item ${i + 1}',
                    ),
                  ),
                ),
                IconButton(
                  key: AppointmentFormScreen.agendaItemRemoveKey(i),
                  icon: const Icon(Icons.close),
                  color: careblazersColors.primarySoft,
                  tooltip: 'Remove item',
                  onPressed: () => _removeAgendaItem(i),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildNewProviderForm(TextTheme textTheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'New provider',
            style: textTheme.titleMedium?.copyWith(
              color: careblazersColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          _LabelledField(
            label: 'Name',
            child: TextField(
              key: AppointmentFormScreen.newProviderNameFieldKey,
              controller: _newProviderName,
              decoration: const InputDecoration(hintText: 'e.g. Dr. Ortega'),
            ),
          ),
          const SizedBox(height: 12),
          _LabelledField(
            label: 'Role',
            child: DropdownButtonFormField<ProviderRole>(
              key: AppointmentFormScreen.newProviderRoleKey,
              initialValue: _newProviderRole,
              isExpanded: true,
              items: const <DropdownMenuItem<ProviderRole>>[
                DropdownMenuItem<ProviderRole>(
                  value: ProviderRole.doctor,
                  child: Text('Doctor'),
                ),
                DropdownMenuItem<ProviderRole>(
                  value: ProviderRole.neurologist,
                  child: Text('Neurologist'),
                ),
                DropdownMenuItem<ProviderRole>(
                  value: ProviderRole.socialWorker,
                  child: Text('Social worker'),
                ),
                DropdownMenuItem<ProviderRole>(
                  value: ProviderRole.other,
                  child: Text('Other'),
                ),
              ],
              onChanged: (ProviderRole? next) {
                if (next == null) return;
                setState(() => _newProviderRole = next);
              },
            ),
          ),
          const SizedBox(height: 12),
          _LabelledField(
            label: 'Phone',
            child: TextField(
              key: AppointmentFormScreen.newProviderPhoneFieldKey,
              controller: _newProviderPhone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                hintText: 'e.g. (415) 555-0188',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _LabelledField(
            label: 'Address',
            child: TextField(
              key: AppointmentFormScreen.newProviderAddressFieldKey,
              controller: _newProviderAddress,
              decoration: const InputDecoration(
                hintText: 'e.g. 250 Bon Air Rd, Greenbrae CA',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _LabelledField(
            label: 'Notes (optional)',
            child: TextField(
              key: AppointmentFormScreen.newProviderNotesFieldKey,
              controller: _newProviderNotes,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                hintText:
                    'e.g. Use the side entrance, free parking after 4pm.',
              ),
            ),
          ),
          if (_newProviderError != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _newProviderError!,
              style: textTheme.bodyMedium?.copyWith(
                color: careblazersColors.cta,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  key: AppointmentFormScreen.newProviderCancelButtonKey,
                  onPressed: _cancelInlineProvider,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: careblazersColors.primary,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  key: AppointmentFormScreen.newProviderSaveButtonKey,
                  onPressed: _saveInlineProvider,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: careblazersColors.cta,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Save provider'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProviderPicker extends StatelessWidget {
  const _ProviderPicker({
    required this.providers,
    required this.selectedId,
    required this.onChanged,
    required this.onAddTapped,
  });

  final List<Provider> providers;
  final String? selectedId;
  final ValueChanged<String?> onChanged;
  final VoidCallback onAddTapped;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    if (providers.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No providers on file yet. Add the first one below.',
              style: textTheme.bodyMedium?.copyWith(
                color: careblazersColors.primarySoft,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: AppointmentFormScreen.addProviderToggleKey,
              onPressed: onAddTapped,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add a provider'),
              style: TextButton.styleFrom(
                foregroundColor: careblazersColors.primary,
              ),
            ),
          ),
        ],
      );
    }
    final String? safeSelected =
        providers.any((Provider p) => p.id == selectedId) ? selectedId : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DropdownButtonFormField<String>(
          key: AppointmentFormScreen.providerDropdownKey,
          initialValue: safeSelected,
          isExpanded: true,
          decoration: const InputDecoration(
            hintText: 'Pick a provider',
          ),
          items: <DropdownMenuItem<String>>[
            for (final Provider p in providers)
              DropdownMenuItem<String>(
                value: p.id,
                child: Text(p.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: AppointmentFormScreen.addProviderToggleKey,
            onPressed: onAddTapped,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Add a new provider'),
            style: TextButton.styleFrom(
              foregroundColor: careblazersColors.primary,
            ),
          ),
        ),
      ],
    );
  }
}

class _LabelledField extends StatelessWidget {
  const _LabelledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.fieldKey,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Key fieldKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: fieldKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: careblazersColors.primarySoft),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, color: careblazersColors.primarySoft, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                ),
              ),
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
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime t) =>
    '${_months[t.month - 1]} ${t.day}, ${t.year}';

String _formatTime(DateTime t) {
  final int rawHour = t.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String suffix = t.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}
