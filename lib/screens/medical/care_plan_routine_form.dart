import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_plan_routine.dart';
import '../../models/medication.dart' show FrequencyKind;
import '../../providers/care_plan_provider.dart';
import '../../providers/patient_timeline_provider.dart'
    show invalidatePatientTimeline;
import '../../theme.dart';

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

  @override
  ConsumerState<CarePlanRoutineForm> createState() =>
      _CarePlanRoutineFormState();
}

class _CarePlanRoutineFormState extends ConsumerState<CarePlanRoutineForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  FrequencyKind _frequency = FrequencyKind.daily;
  Set<int> _daysOfWeek = const <int>{1, 2, 3, 4, 5, 6, 7};
  bool _hydrated = false;
  bool _submitting = false;

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
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
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

    final String id = widget.routineId ??
        'routine-${DateTime.now().millisecondsSinceEpoch}-'
            '${math.Random().nextInt(1 << 32)}';
    final CarePlanRoutine routine = CarePlanRoutine(
      id: id,
      patientId: 'demo-patient-mary',
      title: _title.text.trim(),
      body: _body.text.trim(),
      scheduledTime: _time,
      frequencyKind: _frequency,
      daysOfWeek: _frequency == FrequencyKind.weekly
          ? _daysOfWeek
          : const <int>{},
      startsOn: DateTime.now(),
    );
    try {
      await ref.read(carePlanProvider.notifier).upsert(routine);
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
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: Text(widget.isEdit ? 'Edit routine' : 'Add routine'),
        actions: <Widget>[
          if (widget.isEdit)
            IconButton(
              key: CarePlanRoutineForm.deleteButtonKey,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete routine',
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
                key: CarePlanRoutineForm.titleFieldKey,
                controller: _title,
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
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'What to do, in order. Markdown OK.',
                ),
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
                  backgroundColor: careblazersColors.cta,
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
