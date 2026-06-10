import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_plan_routine.dart';
import '../../models/care_task.dart';
import '../../models/medication.dart' show FrequencyKind;
import '../../providers/active_patient_provider.dart';
import '../../providers/care_plan_provider.dart';
import '../../providers/care_tasks_provider.dart';
import '../../providers/patient_timeline_provider.dart'
    show invalidatePatientTimeline;
import '../../theme.dart';
import '../../widgets/form_validation.dart';
import '../../widgets/path_header.dart';

/// Add / edit form for a single [CarePlanRoutine] (Medical → Routines,
/// BUILD_SPEC.md §5.13 v2). Lean by design — title, body, scheduled
/// time, frequency. Days-of-week appear when frequency is "weekly".
class CarePlanRoutineForm extends ConsumerStatefulWidget {
  const CarePlanRoutineForm({super.key, this.routineId});

  /// When non-null, the form hydrates the existing routine for edit.
  final String? routineId;

  bool get isEdit => routineId != null;

  static const Key titleFieldKey = Key('routine-form-title');
  static const Key bodyFieldKey = Key('routine-form-body');
  static const Key timeFieldKey = Key('routine-form-time');
  static const Key frequencyDropdownKey = Key('routine-form-frequency');
  static const Key submitButtonKey = Key('routine-form-submit');
  static const Key deleteButtonKey = Key('routine-form-delete');
  static const Key subtaskFieldKey = Key('routine-form-subtask-input');
  static const Key subtaskAddKey = Key('routine-form-subtask-add');

  /// Per-row remove button for an existing child task (by index). Keeps the
  /// historical "subtask" key name so tests keep resolving — under the
  /// unified model these rows are real child [CareTask]s, not strings.
  static Key subtaskRemoveKey(int index) =>
      Key('routine-form-subtask-remove-$index');

  @override
  ConsumerState<CarePlanRoutineForm> createState() =>
      _CarePlanRoutineFormState();
}

class _CarePlanRoutineFormState extends ConsumerState<CarePlanRoutineForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();
  final TextEditingController _subtaskInput = TextEditingController();
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  FrequencyKind _frequency = FrequencyKind.daily;
  Set<int> _daysOfWeek = const <int>{1, 2, 3, 4, 5, 6, 7};

  /// The in-progress list of child-task titles this routine bundles
  /// (unified task/routine model). Kept as titles for simplicity; on save
  /// they're reconciled into real child [CareTask] rows linked by
  /// `routineId`. Hydrated on the edit path from the existing child tasks.
  List<String> _taskTitles = <String>[];
  bool _hydrated = false;
  bool _tasksHydrated = false;
  bool _submitting = false;

  /// The patientId + startsOn captured off the routine being edited, so a
  /// save preserves the row's original loved one + start date rather than
  /// re-homing it to the active patient / re-anchoring it to "now". Null on
  /// the add path (the new routine resolves the active patient instead).
  String? _editPatientId;
  DateTime? _editStartsOn;

  void _hydrate(CarePlanRoutine routine) {
    if (_hydrated) return;
    _hydrated = true;
    _title.text = routine.title;
    _body.text = routine.body;
    _time = routine.scheduledTime;
    _frequency = routine.frequencyKind;
    _daysOfWeek = routine.daysOfWeek.isEmpty
        ? const <int>{1, 2, 3, 4, 5, 6, 7}
        : routine.daysOfWeek;
    _editPatientId = routine.patientId;
    _editStartsOn = routine.startsOn;
    // Child tasks load asynchronously from the tasks repo; kick that off
    // once the routine itself has hydrated.
    _hydrateChildTasks();
  }

  /// Load the existing child [CareTask]s for the edited routine and seed
  /// [_taskTitles] from their titles, ordered. Runs once (guarded by
  /// [_tasksHydrated]); a no-op on the add path.
  Future<void> _hydrateChildTasks() async {
    if (_tasksHydrated) return;
    final String? routineId = widget.routineId;
    if (routineId == null) return;
    _tasksHydrated = true;
    final CareTasksRepository repo =
        ref.read(careTasksRepositoryProvider);
    final List<CareTask> all = await repo.listTasks();
    final List<CareTask> children = all
        .where((CareTask t) => t.routineId == routineId)
        .toList();
    if (!mounted) return;
    setState(() {
      _taskTitles = <String>[for (final CareTask t in children) t.title];
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _subtaskInput.dispose();
    super.dispose();
  }

  void _addSubtask() {
    final String text = _subtaskInput.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _taskTitles = <String>[..._taskTitles, text];
      _subtaskInput.clear();
    });
  }

  void _removeSubtask(int index) {
    setState(() {
      _taskTitles = <String>[
        for (int i = 0; i < _taskTitles.length; i++)
          if (i != index) _taskTitles[i],
      ];
    });
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
    // Validate on press + scroll to the first invalid field.
    if (!validateAndScrollToFirstError(_formKey)) return;
    setState(() => _submitting = true);

    final String id = widget.routineId ??
        'routine-${DateTime.now().millisecondsSinceEpoch}-'
            '${math.Random().nextInt(1 << 32)}';
    // A new routine is filed under the active loved one's id (was a
    // hard-coded 'demo-patient-mary') so it follows whichever person is
    // selected (multi-patient, Issue #6). On the edit path keep the routine's
    // own patientId + startsOn so a save never re-homes or re-anchors it.
    // With one patient on file [activePatientIdProvider] resolves to that
    // sole id, identical to the old const.
    final String patientId =
        _editPatientId ?? await ref.read(activePatientIdProvider.future);
    final CarePlanRoutine routine = CarePlanRoutine(
      id: id,
      patientId: patientId,
      title: _title.text.trim(),
      body: _body.text.trim(),
      scheduledTime: _time,
      frequencyKind: _frequency,
      daysOfWeek: _frequency == FrequencyKind.weekly
          ? _daysOfWeek
          : const <int>{},
      startsOn: _editStartsOn ?? DateTime.now(),
      // The string checklist is retired under the unified task/routine
      // model — child tasks (linked by routineId) replace it. Kept as an
      // empty list for back-compat hydration of older rows.
      subtasks: const <String>[],
    );
    try {
      await ref.read(carePlanProvider.notifier).upsert(routine);
      await _reconcileChildTasks(routine.id, patientId);
      invalidatePatientTimeline(ref);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/medical/routines');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save — try again.")),
      );
    }
  }

  /// Reconcile this routine's child [CareTask]s against [_taskTitles]
  /// (unified task/routine model). Simplest correct approach: drop every
  /// existing child task for [routineId], then recreate one per title with
  /// a minted id, the routine's [patientId], and `routineId` set so the
  /// task is bundled under the routine rather than riding the schedule on
  /// its own.
  Future<void> _reconcileChildTasks(
    String routineId,
    String patientId,
  ) async {
    final CareTasksRepository repo =
        ref.read(careTasksRepositoryProvider);
    final List<CareTask> all = await repo.listTasks();
    for (final CareTask existing in all) {
      if (existing.routineId == routineId) {
        await repo.deleteTask(existing.id);
      }
    }
    for (final String title in _taskTitles) {
      final String taskId = 'task-${DateTime.now().millisecondsSinceEpoch}-'
          '${math.Random().nextInt(1 << 32)}';
      await repo.upsertTask(CareTask(
        id: taskId,
        title: title,
        patientId: patientId,
        routineId: routineId,
      ));
    }
  }

  Future<void> _delete() async {
    final String? id = widget.routineId;
    if (id == null) return;
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete routine?'),
        content: const Text(
          'It will stop appearing on your schedule. This cannot be '
          'undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await ref.read(carePlanProvider.notifier).delete(id);
    invalidatePatientTimeline(ref);
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medical/routines');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CarePlanRoutine>> async =
        ref.watch(carePlanProvider);
    if (widget.isEdit) {
      async.whenData((List<CarePlanRoutine> rs) {
        final CarePlanRoutine? found = rs
            .where((CarePlanRoutine r) => r.id == widget.routineId)
            .cast<CarePlanRoutine?>()
            .firstWhere((CarePlanRoutine? r) => r != null, orElse: () => null);
        if (found != null) _hydrate(found);
      });
    }
    final MaterialLocalizations loc = MaterialLocalizations.of(context);
    final TextTheme tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: context.cb.background,
      appBar: AppBar(
        // The title + Back live in the body PathHeader; this bar only hosts
        // the (edit-only) Delete action and suppresses the auto back-arrow.
        automaticallyImplyLeading: false,
        backgroundColor: context.cb.background,
        elevation: 0,
        actions: <Widget>[
          if (widget.isEdit)
            IconButton(
              key: CarePlanRoutineForm.deleteButtonKey,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete routine',
              color: context.cb.primary,
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
              PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  const PathHeaderCrumb(label: 'Home', route: '/'),
                  const PathHeaderCrumb(label: 'Care', route: '/medical'),
                  const PathHeaderCrumb(
                    label: 'Routines',
                    route: '/medical/routines',
                  ),
                  PathHeaderCrumb(
                    label: widget.isEdit ? 'Edit routine' : 'Add routine',
                  ),
                ],
                title: widget.isEdit ? 'Edit routine' : 'Add routine',
                backLabel: 'Back to Routines',
                leadingIcon: Icons.assignment_outlined,
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: CarePlanRoutineForm.titleFieldKey,
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'e.g. Morning hygiene',
                ),
                validator: (String? v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Title is required.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: CarePlanRoutineForm.bodyFieldKey,
                controller: _body,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'What to do, in order. Markdown OK.',
                ),
              ),
              const SizedBox(height: 16),
              _SubtaskEditor(
                taskTitles: _taskTitles,
                controller: _subtaskInput,
                onAdd: _addSubtask,
                onRemove: _removeSubtask,
              ),
              const SizedBox(height: 16),
              InkWell(
                key: CarePlanRoutineForm.timeFieldKey,
                onTap: _pickTime,
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Time'),
                  child: Text(
                    loc.formatTimeOfDay(_time),
                    style: tt.bodyLarge,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<FrequencyKind>(
                key: CarePlanRoutineForm.frequencyDropdownKey,
                initialValue: _frequency,
                decoration: const InputDecoration(labelText: 'Frequency'),
                items: const <DropdownMenuItem<FrequencyKind>>[
                  DropdownMenuItem<FrequencyKind>(
                    value: FrequencyKind.daily,
                    child: Text('Daily'),
                  ),
                  DropdownMenuItem<FrequencyKind>(
                    value: FrequencyKind.weekly,
                    child: Text('Weekly (pick days)'),
                  ),
                  DropdownMenuItem<FrequencyKind>(
                    value: FrequencyKind.asNeeded,
                    child: Text('As needed (no schedule)'),
                  ),
                ],
                onChanged: (FrequencyKind? v) {
                  if (v == null) return;
                  setState(() => _frequency = v);
                },
              ),
              if (_frequency == FrequencyKind.weekly) ...<Widget>[
                const SizedBox(height: 16),
                _WeeklyDayPicker(
                  selected: _daysOfWeek,
                  onChanged: (Set<int> next) {
                    setState(() => _daysOfWeek = next);
                  },
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                key: CarePlanRoutineForm.submitButtonKey,
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.cb.cta,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(56),
                ),
                child: Text(_submitting
                    ? 'Saving…'
                    : (widget.isEdit ? 'Save changes' : 'Save routine')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline editor for the child tasks a routine bundles (unified
/// task/routine model). Shows the current tasks (each removable), then a
/// text field + Add button to append a new one. Stateless — the form owns
/// the [taskTitles] list and the input [controller]; on save the titles
/// are reconciled into real child [CareTask] rows.
class _SubtaskEditor extends StatelessWidget {
  const _SubtaskEditor({
    required this.taskTitles,
    required this.controller,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> taskTitles;
  final TextEditingController controller;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Tasks (optional)',
          style: tt.bodyMedium?.copyWith(color: context.cb.primary),
        ),
        const SizedBox(height: 4),
        Text(
          'Break the routine into tasks — e.g. brush teeth, '
          'wash face, get dressed.',
          style: tt.bodySmall?.copyWith(
            color: context.cb.primary.withValues(alpha: 0.7),
          ),
        ),
        for (int i = 0; i < taskTitles.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.check_box_outline_blank,
                  size: 20,
                  color: context.cb.primarySoft,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(taskTitles[i], style: tt.bodyLarge)),
                IconButton(
                  key: CarePlanRoutineForm.subtaskRemoveKey(i),
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Remove task',
                  onPressed: () => onRemove(i),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: CarePlanRoutineForm.subtaskFieldKey,
                controller: controller,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => onAdd(),
                decoration: const InputDecoration(
                  hintText: 'Add a task',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              key: CarePlanRoutineForm.subtaskAddKey,
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('Add'),
            ),
          ],
        ),
      ],
    );
  }
}

class _WeeklyDayPicker extends StatelessWidget {
  const _WeeklyDayPicker({required this.selected, required this.onChanged});

  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;

  static const List<String> _labels = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: <Widget>[
        for (int i = 0; i < 7; i++)
          FilterChip(
            label: Text(_labels[i]),
            selected: selected.contains(i + 1),
            onSelected: (bool on) {
              final Set<int> next = <int>{...selected};
              if (on) {
                next.add(i + 1);
              } else {
                next.remove(i + 1);
              }
              onChanged(next);
            },
          ),
      ],
    );
  }
}
