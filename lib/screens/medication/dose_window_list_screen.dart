import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/medication.dart';
import '../../providers/patient_timeline_provider.dart';
import '../../services/medication_repository.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';
import 'medication_list_screen.dart' show medicationListProvider;

part 'dose_window_list_screen.g.dart';

const String _calendarPatientId = 'demo-patient-mary';

/// Async list of dose windows for the active patient, sorted by
/// anchor time with "As needed" last. Backed by the
/// [MedicationRepository.windowsForPatient] query so a freshly
/// upserted window flows in on invalidate.
@Riverpod(keepAlive: false)
Future<List<DoseWindow>> doseWindowList(Ref ref) async {
  final MedicationRepository repo =
      ref.watch(medicationRepositoryBackendProvider);
  return repo.windowsForPatient(_calendarPatientId);
}

/// Dose-window management screen at `/medications/windows`. Lists
/// every window with its label + anchor time, with an "+ Add window"
/// FAB and per-row tap-to-edit. Reached from the Medications list's
/// "Manage windows" link so caregivers can rename / re-anchor / delete
/// without the form wizard's bottom sheet getting in the way.
class DoseWindowListScreen extends ConsumerWidget {
  const DoseWindowListScreen({super.key});

  static const Key listKey = Key('dose-window-list');
  static const Key fabKey = Key('dose-window-list-fab');
  static const Key emptyStateKey = Key('dose-window-list-empty');
  static Key tileKey(String id) => Key('dose-window-list-tile-$id');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DoseWindow>> async =
        ref.watch(doseWindowListProvider);
    return Scaffold(
      backgroundColor: careblazersColors.background,
      floatingActionButton: FloatingActionButton.extended(
        key: fabKey,
        backgroundColor: careblazersColors.cta,
        foregroundColor: Colors.white,
        onPressed: () => context.push('/medications/windows/new'),
        icon: const Icon(Icons.add),
        label: const Text('Add window'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Medical', route: '/medical'),
                  PathHeaderCrumb(
                      label: 'Medications', route: '/medications'),
                  PathHeaderCrumb(label: 'Windows'),
                ],
                title: 'Dose windows',
                backLabel: 'Back to Medications',
                leadingIcon: Icons.schedule_outlined,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) =>
                    _ErrorView(message: '$e'),
                data: (List<DoseWindow> windows) {
                  if (windows.isEmpty) {
                    return const _Empty();
                  }
                  return ListView.separated(
                    key: listKey,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    itemCount: windows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int i) =>
                        _WindowRow(window: windows[i]),
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

class _WindowRow extends ConsumerWidget {
  const _WindowRow({required this.window});
  final DoseWindow window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: careblazersColors.surfaceWarm,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        key: DoseWindowListScreen.tileKey(window.id),
        onTap: () => context.push('/medications/windows/${window.id}'),
        title: Text(
          window.label,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          window.isAsNeeded
              ? 'As needed'
              : MaterialLocalizations.of(context).formatTimeOfDay(
                  window.anchorTime!,
                  alwaysUse24HourFormat:
                      MediaQuery.alwaysUse24HourFormatOf(context),
                ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: 'Delete window',
              icon: const Icon(Icons.delete_outline),
              color: careblazersColors.primarySoft,
              onPressed: () =>
                  confirmAndDeleteWindow(context, ref, window.id),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Padding(
      key: DoseWindowListScreen.emptyStateKey,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'No windows yet.',
            style: tt.titleMedium?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Windows are the times of day medications are given — "
            "Morning, Bedtime, etc. Tap +Add window to create your first.",
            style: tt.bodyMedium?.copyWith(
              color: careblazersColors.text.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text("Couldn't load windows.\n\n$message"),
      );
}

/// Invalidate every provider that depends on the windows list — the
/// medication list (its window subtitles), the timeline merger (its
/// dose projections), and the window list itself.
void _invalidateWindowSurfaces(WidgetRef ref) {
  ref.invalidate(doseWindowListProvider);
  ref.invalidate(medicationListProvider);
  invalidatePatientTimeline(ref);
}

/// Confirm + delete a single window. Resolves the medications attached
/// to the window BEFORE showing the dialog so the warning can list
/// them by name. Returns true when the deletion ran, false when the
/// caregiver cancelled. Shared by the list-row trash icon and the
/// edit-form's AppBar delete.
Future<bool> confirmAndDeleteWindow(
  BuildContext context,
  WidgetRef ref,
  String windowId,
) async {
  final MedicationRepository repo =
      ref.read(medicationRepositoryBackendProvider);
  final List<MedicationWindowEntry> entries =
      await repo.entriesForWindow(windowId);
  final List<Medication> allMeds = await repo.listMedications();
  final Map<String, Medication> medsById = <String, Medication>{
    for (final Medication m in allMeds) m.id: m,
  };
  final List<Medication> attached = <Medication>[
    for (final MedicationWindowEntry e in entries)
      if (medsById[e.medicationId] != null) medsById[e.medicationId]!,
  ];
  attached.sort((Medication a, Medication b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  if (!context.mounted) return false;
  final bool? confirm = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(attached.isEmpty
          ? 'Delete this window?'
          : 'Delete and unlink ${attached.length} '
              'medication${attached.length == 1 ? '' : 's'}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (attached.isEmpty)
            const Text(
              "No medications are attached to this window. Safe to "
              "delete.",
            )
          else ...<Widget>[
            Text(
              'Deleting this window will unlink it from the '
              'following medication${attached.length == 1 ? '' : 's'}, '
              "so they'll stop appearing on the schedule at this "
              "time. The medications themselves stay.",
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final Medication m in attached)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '• ${m.name}'
                          '${m.dosage.isEmpty ? '' : ' (${m.dosage})'}',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(attached.isEmpty ? 'Delete' : 'Delete + unlink'),
        ),
      ],
    ),
  );
  if (confirm != true) return false;
  await repo.deleteWindow(windowId);
  _invalidateWindowSurfaces(ref);
  return true;
}

/// Dose-window form screen at `/medications/windows/new` and
/// `/medications/windows/:id`. Carries a label field, a time picker
/// (with an "As needed" toggle so the seeded ad-hoc window can be
/// edited), and — in edit mode — a delete affordance that cascades
/// the window's entries.
class DoseWindowFormScreen extends ConsumerStatefulWidget {
  const DoseWindowFormScreen({super.key, this.windowId});

  /// When non-null the form hydrates the existing window.
  final String? windowId;

  bool get isEdit => windowId != null;

  static const Key labelFieldKey = Key('dose-window-form-label');
  static const Key timeFieldKey = Key('dose-window-form-time');
  static const Key asNeededToggleKey = Key('dose-window-form-as-needed');
  static const Key submitButtonKey = Key('dose-window-form-submit');
  static const Key deleteButtonKey = Key('dose-window-form-delete');

  @override
  ConsumerState<DoseWindowFormScreen> createState() =>
      _DoseWindowFormScreenState();
}

class _DoseWindowFormScreenState
    extends ConsumerState<DoseWindowFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _label = TextEditingController();
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  bool _asNeeded = false;
  bool _hydrated = false;
  bool _submitting = false;
  int _sortOrder = 0;

  void _hydrate(DoseWindow w) {
    if (_hydrated) return;
    _hydrated = true;
    _label.text = w.label;
    if (w.anchorTime != null) {
      _time = w.anchorTime!;
      _asNeeded = false;
    } else {
      _asNeeded = true;
    }
    _sortOrder = w.sortOrder;
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final TimeOfDay? next = await showTimePicker(
      context: context,
      initialTime: _time,
    );
    if (next == null) return;
    setState(() => _time = next);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    final MedicationRepository repo =
        ref.read(medicationRepositoryBackendProvider);
    final String id = widget.windowId ??
        'window-${DateTime.now().millisecondsSinceEpoch}';
    final int sortOrder = widget.isEdit
        ? _sortOrder
        : (await repo.windowsForPatient(_calendarPatientId))
            .map((DoseWindow w) => w.sortOrder)
            .fold<int>(-1, (int a, int b) => a > b ? a : b) +
            1;
    final DoseWindow window = DoseWindow(
      id: id,
      patientId: _calendarPatientId,
      label: _label.text.trim(),
      anchorTime: _asNeeded ? null : _time,
      sortOrder: sortOrder,
    );
    try {
      await repo.upsertWindow(window);
      _invalidateWindowSurfaces(ref);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/medications/windows');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save — try again.")),
      );
    }
  }

  Future<void> _delete() async {
    final String? id = widget.windowId;
    if (id == null) return;
    final bool deleted = await confirmAndDeleteWindow(context, ref, id);
    if (!deleted) return;
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medications/windows');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<DoseWindow>> async =
        ref.watch(doseWindowListProvider);
    if (widget.isEdit) {
      async.whenData((List<DoseWindow> ws) {
        final DoseWindow? found = ws
            .where((DoseWindow w) => w.id == widget.windowId)
            .cast<DoseWindow?>()
            .firstWhere((DoseWindow? w) => w != null, orElse: () => null);
        if (found != null) _hydrate(found);
      });
    }
    // Existing window labels (lowercased), excluding the one being
    // edited. Closed over by the label validator so a duplicate name
    // can't be saved.
    final Set<String> otherLabels = <String>{
      for (final DoseWindow w in (async.asData?.value ?? const <DoseWindow>[]))
        if (w.id != widget.windowId) w.label.toLowerCase().trim(),
    };
    final MaterialLocalizations loc = MaterialLocalizations.of(context);
    final TextTheme tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: Text(widget.isEdit ? 'Edit window' : 'Add window'),
        actions: <Widget>[
          if (widget.isEdit)
            IconButton(
              key: DoseWindowFormScreen.deleteButtonKey,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete window',
              onPressed: _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: <Widget>[
              TextFormField(
                key: DoseWindowFormScreen.labelFieldKey,
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  hintText: 'e.g. Morning',
                ),
                validator: (String? v) {
                  final String trimmed = v?.trim() ?? '';
                  if (trimmed.isEmpty) {
                    return 'A label is required.';
                  }
                  if (otherLabels.contains(trimmed.toLowerCase())) {
                    return "Another window already uses that name.";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                key: DoseWindowFormScreen.asNeededToggleKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('As needed (no scheduled time)'),
                value: _asNeeded,
                onChanged: (bool v) => setState(() => _asNeeded = v),
              ),
              if (!_asNeeded) ...<Widget>[
                const SizedBox(height: 8),
                InkWell(
                  key: DoseWindowFormScreen.timeFieldKey,
                  onTap: _pickTime,
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Time'),
                    child: Text(
                      loc.formatTimeOfDay(_time),
                      style: tt.bodyLarge,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                key: DoseWindowFormScreen.submitButtonKey,
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: careblazersColors.cta,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(56),
                ),
                child: Text(_submitting
                    ? 'Saving…'
                    : (widget.isEdit ? 'Save changes' : 'Save window')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
