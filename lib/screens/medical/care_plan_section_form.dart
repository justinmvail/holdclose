import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/care_plan_section.dart';
import '../../models/patient.dart';
import '../../providers/care_plan_provider.dart';
import '../../providers/storage_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'care_plan_section_form.g.dart';

/// Fallback loved-one id used when no [Patient] is on file yet — matches
/// the demo seed's `maryHenderson` id so a freshly-added section lines up
/// with any seeded care plan. Same fallback the health-log form uses.
const String _fallbackPatientId = 'demo-patient-mary';

/// Mint a new id for the care-plan section the form inserts. Overridable
/// for tests + the demo tour so id sequences are deterministic — same
/// shape as the health-log / appointment form id factories.
typedef CarePlanIdFactory = String Function();

String _defaultCarePlanIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'cp-$ms-$rand';
}

/// ID factory the form screen uses. Tests override this with a monotonic
/// counter so the inserted id is stable across runs.
@Riverpod(keepAlive: true)
CarePlanIdFactory carePlanFormIdFactory(Ref ref) => _defaultCarePlanIdFactory;

/// What the form needs before it can render: the section being edited
/// (null on the add path) plus the loved-one id a freshly-added section
/// attaches to.
@immutable
class CarePlanFormData {
  const CarePlanFormData({this.section, required this.patientId});

  /// The row hydrating the edit path, or null on the add path.
  final CarePlanSection? section;

  /// The loved one a new section is filed under. On the edit path this is
  /// the existing section's own [CarePlanSection.patientId] so a save
  /// never silently re-homes the row.
  final String patientId;
}

/// Async loader for the section form (TASKS.md Phase 14.19). Resolves the
/// active loved-one id from [storageProvider] and — on the edit path — the
/// existing [CarePlanSection] from [carePlanRepositoryProvider].
///
/// Returns the add-path shape (null section, resolved patientId) when
/// [sectionId] is null or points at a row that has since been deleted.
@Riverpod(keepAlive: false)
Future<CarePlanFormData> carePlanFormHydration(
  Ref ref,
  String? sectionId,
) async {
  final StorageProvider storage = ref.watch(storageProvider);
  final Patient? patient = await storage.getPatient();
  final String patientId = patient?.id ?? _fallbackPatientId;

  if (sectionId == null) {
    return CarePlanFormData(patientId: patientId);
  }
  final CarePlanRepository repo = ref.watch(carePlanRepositoryProvider);
  final CarePlanSection? section = await repo.getById(sectionId);
  return CarePlanFormData(
    section: section,
    patientId: section?.patientId ?? patientId,
  );
}

/// Add / edit care-plan section form (TASKS.md Phase 14.19) at
/// `/medical/care-plan/new` and `/medical/care-plan/:id/edit`.
///
/// A slot picker (Morning / Afternoon / Evening / Night / As needed) and a
/// stage picker (Early / Middle / Late / Any stage) sit above the title
/// and the markdown body field. Save writes through the [carePlanProvider]
/// notifier so the screen reflects the change without a manual invalidate:
///
///   - **Add** → `add`, which appends the section to the end of its slot.
///   - **Edit, same slot** → `updateSection`, preserving the section's
///     existing order.
///   - **Edit, slot changed** → `delete` from the old slot (which closes
///     the gap) then `add` to the new slot (which appends it) — the
///     notifier owns the per-slot ordering invariant, so re-homing this
///     way keeps both slots contiguous.
///
/// The edit path also offers a Delete action. This is an organisational
/// routine, not a clinical plan — nothing here diagnoses or prescribes.
class CarePlanSectionForm extends ConsumerStatefulWidget {
  const CarePlanSectionForm({super.key, this.sectionId});

  /// Non-null on the edit path; null on the add path.
  final String? sectionId;

  bool get isEdit => sectionId != null;

  static const Key formKey = Key('care-plan-form');
  static const Key titleFieldKey = Key('care-plan-form-title');
  static const Key bodyFieldKey = Key('care-plan-form-body');
  static const Key saveButtonKey = Key('care-plan-form-save');
  static const Key deleteButtonKey = Key('care-plan-form-delete');

  static Key slotChipKey(CarePlanSlot slot) =>
      Key('care-plan-form-slot-${slot.name}');
  static Key stageChipKey(CareStage stage) =>
      Key('care-plan-form-stage-${stage.name}');

  @override
  ConsumerState<CarePlanSectionForm> createState() =>
      _CarePlanSectionFormState();
}

class _CarePlanSectionFormState extends ConsumerState<CarePlanSectionForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();

  CarePlanSlot _slot = CarePlanSlot.morning;
  CareStage _stage = CareStage.anyStage;
  String _patientId = _fallbackPatientId;

  /// The slot + order the section had when the form opened — used to
  /// decide whether a save is an in-place update or a re-home, and to
  /// preserve the order on an in-place update.
  CarePlanSlot? _originalSlot;
  int _originalOrder = 0;

  bool _hydrated = false;
  bool _submitting = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _hydrate(CarePlanFormData data) {
    if (_hydrated) return;
    _hydrated = true;
    _patientId = data.patientId;
    final CarePlanSection? section = data.section;
    if (section == null) return;
    _slot = section.slot;
    _stage = section.appliesInStage;
    _title.text = section.title;
    _body.text = section.body;
    _originalSlot = section.slot;
    _originalOrder = section.order;
  }

  void _selectSlot(CarePlanSlot slot) {
    if (slot == _slot) return;
    setState(() => _slot = slot);
  }

  void _selectStage(CareStage stage) {
    if (stage == _stage) return;
    setState(() => _stage = stage);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    setState(() => _submitting = true);

    final CarePlanIdFactory mint = ref.read(carePlanFormIdFactoryProvider);
    final String id = widget.sectionId ?? mint();
    final CarePlan notifier = ref.read(carePlanProvider.notifier);

    final CarePlanSection section = CarePlanSection(
      id: id,
      patientId: _patientId,
      slot: _slot,
      title: _title.text.trim(),
      body: _body.text.trim(),
      // `add` overwrites this with the slot's tail index; `updateSection`
      // keeps it, so we pass the original order to hold position on an
      // in-place edit.
      order: _originalOrder,
      appliesInStage: _stage,
    );

    if (!widget.isEdit) {
      await notifier.add(section);
    } else if (_originalSlot == _slot) {
      await notifier.updateSection(section);
    } else {
      // Slot changed: drop it from the old slot (closing that gap) and
      // re-append it to the new one. `add` upserts by the same id, so the
      // row moves rather than duplicating.
      await notifier.delete(id);
      await notifier.add(section);
    }

    if (!mounted) return;
    _leave();
  }

  Future<void> _delete() async {
    final String? id = widget.sectionId;
    if (id == null || _submitting) return;
    setState(() => _submitting = true);
    await ref.read(carePlanProvider.notifier).delete(id);
    if (!mounted) return;
    _leave();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medical/care-plan');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<CarePlanFormData> hydration =
        ref.watch(carePlanFormHydrationProvider(widget.sectionId));
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: hydration.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (CarePlanFormData data) {
            _hydrate(data);
            return Form(
              key: _formKey,
              child: ListView(
                key: CarePlanSectionForm.formKey,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: <Widget>[
                  PathHeader(
                    breadcrumbs: const <PathHeaderCrumb>[
                      PathHeaderCrumb(label: 'Home', route: '/'),
                      PathHeaderCrumb(label: 'Medical', route: '/medical'),
                      PathHeaderCrumb(
                        label: 'Care Plan',
                        route: '/medical/care-plan',
                      ),
                      PathHeaderCrumb(label: 'Section'),
                    ],
                    title: widget.isEdit ? 'Edit section' : 'New section',
                    backLabel: 'Back to Care Plan',
                    leadingIcon: Icons.assignment_outlined,
                  ),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'When in the day?'),
                  const SizedBox(height: 8),
                  _SlotPicker(selected: _slot, onSelected: _selectSlot),
                  const SizedBox(height: 24),
                  const _FieldLabel(label: 'Which stage?'),
                  const SizedBox(height: 8),
                  _StagePicker(selected: _stage, onSelected: _selectStage),
                  const SizedBox(height: 24),
                  const _FieldLabel(label: 'Title'),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: CarePlanSectionForm.titleFieldKey,
                    controller: _title,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'e.g. Morning wash-up',
                    ),
                    validator: (String? v) =>
                        (v ?? '').trim().isEmpty ? 'Give this section a title.' : null,
                  ),
                  const SizedBox(height: 24),
                  const _FieldLabel(label: 'What to do'),
                  const SizedBox(height: 4),
                  Text(
                    'You can use simple formatting — **bold**, _italic_, and '
                    'bullet lines starting with a dash.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: careblazersColors.primarySoft,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: CarePlanSectionForm.bodyFieldKey,
                    controller: _body,
                    maxLines: 8,
                    minLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: '- Run a warm, not hot, bath\n'
                          '- Lay out clothes in the order they go on',
                    ),
                    validator: (String? v) => (v ?? '').trim().isEmpty
                        ? 'Add a few words on what to do.'
                        : null,
                  ),
                  const SizedBox(height: 28),
                  Semantics(
                    button: true,
                    label: widget.isEdit
                        ? 'Save changes to this section.'
                        : 'Save this section.',
                    child: ElevatedButton(
                      key: CarePlanSectionForm.saveButtonKey,
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
                                : 'Save section'),
                        style: textTheme.labelLarge
                            ?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                  if (widget.isEdit) ...<Widget>[
                    const SizedBox(height: 12),
                    Semantics(
                      button: true,
                      label: 'Delete this section.',
                      child: OutlinedButton.icon(
                        key: CarePlanSectionForm.deleteButtonKey,
                        onPressed: _submitting ? null : _delete,
                        icon: Icon(
                          Icons.delete_outline,
                          color: careblazersColors.accentDeep,
                        ),
                        label: Text(
                          'Delete section',
                          style: textTheme.labelLarge?.copyWith(
                            color: careblazersColors.accentDeep,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          side: BorderSide(color: careblazersColors.accentDeep),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SlotPicker extends StatelessWidget {
  const _SlotPicker({required this.selected, required this.onSelected});

  final CarePlanSlot selected;
  final ValueChanged<CarePlanSlot> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final CarePlanSlot slot in CarePlanSlot.values)
          _PickerChip(
            key: CarePlanSectionForm.slotChipKey(slot),
            label: _slotLabel(slot),
            selected: slot == selected,
            onTap: () => onSelected(slot),
          ),
      ],
    );
  }
}

class _StagePicker extends StatelessWidget {
  const _StagePicker({required this.selected, required this.onSelected});

  final CareStage selected;
  final ValueChanged<CareStage> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final CareStage stage in CareStage.values)
          _PickerChip(
            key: CarePlanSectionForm.stageChipKey(stage),
            label: _stageLabel(stage),
            selected: stage == selected,
            onTap: () => onSelected(stage),
          ),
      ],
    );
  }
}

class _PickerChip extends StatelessWidget {
  const _PickerChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color border =
        selected ? careblazersColors.cta : careblazersColors.primarySoft;
    final Color fill = selected
        ? careblazersColors.cta.withValues(alpha: 0.12)
        : Colors.transparent;
    final Color fg = selected ? careblazersColors.cta : careblazersColors.text;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: textTheme.bodyMedium?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      label,
      style: textTheme.bodyLarge?.copyWith(
        color: careblazersColors.primary,
        fontWeight: FontWeight.w700,
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
          "We couldn't load this section.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

String _slotLabel(CarePlanSlot slot) {
  switch (slot) {
    case CarePlanSlot.morning:
      return 'Morning';
    case CarePlanSlot.afternoon:
      return 'Afternoon';
    case CarePlanSlot.evening:
      return 'Evening';
    case CarePlanSlot.night:
      return 'Night';
    case CarePlanSlot.asNeeded:
      return 'As needed';
  }
}

String _stageLabel(CareStage stage) {
  switch (stage) {
    case CareStage.early:
      return 'Early';
    case CareStage.middle:
      return 'Middle';
    case CareStage.late:
      return 'Late';
    case CareStage.anyStage:
      return 'Any stage';
  }
}
