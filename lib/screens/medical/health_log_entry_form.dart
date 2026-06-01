import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/health_log_entry.dart';
import '../../models/patient.dart';
import '../../providers/health_log_provider.dart';
import '../../providers/storage_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'health_log_entry_form.g.dart';

/// Fallback loved-one id used when no [Patient] is on file yet — e.g. a
/// fresh real-mode install where the caregiver hasn't filled in the
/// emergency card. Matches the demo seed's `maryHenderson` id so the
/// `byPatient` selector lines up with any seeded entries.
const String _fallbackPatientId = 'demo-patient-mary';

/// Mint a new id for the health-log row the form inserts. Overridable
/// for tests + the demo tour so id sequences are deterministic — same
/// shape as the appointment / medication form id factories.
typedef HealthLogIdFactory = String Function();

String _defaultHealthLogIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'hl-$ms-$rand';
}

/// ID factory the form screen uses. Tests override this with a monotonic
/// counter so the inserted id is stable across runs.
@Riverpod(keepAlive: true)
HealthLogIdFactory healthLogFormIdFactory(Ref ref) =>
    _defaultHealthLogIdFactory;

/// What the form needs before it can render: the entry being edited (null
/// on the add path) plus the loved-one id a freshly-added entry attaches
/// to.
@immutable
class HealthLogFormData {
  const HealthLogFormData({this.entry, required this.patientId});

  /// The row hydrating the edit path, or null on the add path.
  final HealthLogEntry? entry;

  /// The loved one a new entry is filed under. On the edit path this is
  /// the existing entry's own [HealthLogEntry.patientId] so a save never
  /// silently re-homes the row.
  final String patientId;
}

/// Async loader for the entry form (TASKS.md Phase 14.17). Resolves the
/// active loved-one id from [storageProvider] and — on the edit path —
/// the existing [HealthLogEntry] from [healthLogRepositoryProvider].
///
/// Returns the add-path shape (null entry, resolved patientId) when
/// [entryId] is null or points at a row that has since been deleted.
@Riverpod(keepAlive: false)
Future<HealthLogFormData> healthLogFormHydration(
  Ref ref,
  String? entryId,
) async {
  final StorageProvider storage = ref.watch(storageProvider);
  final Patient? patient = await storage.getPatient();
  final String patientId = patient?.id ?? _fallbackPatientId;

  if (entryId == null) {
    return HealthLogFormData(patientId: patientId);
  }
  final HealthLogRepository repo = ref.watch(healthLogRepositoryProvider);
  final HealthLogEntry? entry = await repo.getById(entryId);
  return HealthLogFormData(
    entry: entry,
    patientId: entry?.patientId ?? patientId,
  );
}

/// Add / edit health-log entry form (TASKS.md Phase 14.17) at
/// `/medical/health-log/new` and `/medical/health-log/:id/edit`.
///
/// A kind picker switches the body between three shapes:
///   - [HealthLogKind.vitals] — BP (systolic / diastolic), heart rate,
///     and temperature inputs. At least one reading is required, and a
///     blood-pressure reading needs both numbers.
///   - [HealthLogKind.symptom] — a 1–5 severity chip row plus the
///     (required) symptom description in the notes field.
///   - [HealthLogKind.note] — just the (required) notes field.
///
/// The notes textarea is present for every kind. Save upserts the
/// [HealthLogEntry] through the [healthLogProvider] notifier (which
/// refreshes the list the screen watches) and pops; the edit path also
/// offers a Delete action. This is a wellness record, not a clinical
/// one — nothing here diagnoses or prescribes.
class HealthLogEntryForm extends ConsumerStatefulWidget {
  const HealthLogEntryForm({super.key, this.entryId});

  /// Non-null on the edit path; null on the add path.
  final String? entryId;

  bool get isEdit => entryId != null;

  static const Key formKey = Key('health-log-form');
  static const Key systolicFieldKey = Key('health-log-form-systolic');
  static const Key diastolicFieldKey = Key('health-log-form-diastolic');
  static const Key heartRateFieldKey = Key('health-log-form-heart-rate');
  static const Key temperatureFieldKey = Key('health-log-form-temperature');
  static const Key notesFieldKey = Key('health-log-form-notes');
  static const Key saveButtonKey = Key('health-log-form-save');
  static const Key deleteButtonKey = Key('health-log-form-delete');
  static const Key formErrorKey = Key('health-log-form-error');
  static const Key vitalsSectionKey = Key('health-log-form-vitals-section');
  static const Key severitySectionKey =
      Key('health-log-form-severity-section');

  static Key kindChipKey(HealthLogKind kind) =>
      Key('health-log-form-kind-${kind.name}');
  static Key severityChipKey(int level) =>
      Key('health-log-form-severity-$level');

  @override
  ConsumerState<HealthLogEntryForm> createState() =>
      _HealthLogEntryFormState();
}

class _HealthLogEntryFormState extends ConsumerState<HealthLogEntryForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _systolic = TextEditingController();
  final TextEditingController _diastolic = TextEditingController();
  final TextEditingController _heartRate = TextEditingController();
  final TextEditingController _temperature = TextEditingController();
  final TextEditingController _notes = TextEditingController();

  HealthLogKind _kind = HealthLogKind.vitals;
  int? _severity;
  late DateTime _recordedAt;
  String _patientId = _fallbackPatientId;
  String? _formError;

  bool _hydrated = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // New entries stamp "now" once; the edit path overwrites this from
    // the loaded row so a save preserves the original time.
    _recordedAt = ref.read(healthLogClockProvider)();
  }

  @override
  void dispose() {
    _systolic.dispose();
    _diastolic.dispose();
    _heartRate.dispose();
    _temperature.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _hydrate(HealthLogFormData data) {
    if (_hydrated) return;
    _hydrated = true;
    _patientId = data.patientId;
    final HealthLogEntry? entry = data.entry;
    if (entry == null) return;
    _kind = entry.kind;
    _severity = entry.severity;
    _recordedAt = entry.recordedAt;
    _systolic.text = entry.systolic?.toString() ?? '';
    _diastolic.text = entry.diastolic?.toString() ?? '';
    _heartRate.text = entry.heartRate?.toString() ?? '';
    _temperature.text = entry.temperatureF == null
        ? ''
        : _trimDouble(entry.temperatureF!);
    _notes.text = entry.notes ?? '';
  }

  void _selectKind(HealthLogKind kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      _formError = null;
    });
  }

  void _toggleSeverity(int level) {
    setState(() => _severity = _severity == level ? null : level);
  }

  int? _parsedInt(TextEditingController c) {
    final String t = c.text.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }

  double? _parsedDouble(TextEditingController c) {
    final String t = c.text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    // Cross-field rules the per-field validators can't express.
    final String? crossFieldError = _validateCrossFields();
    if (crossFieldError != null) {
      setState(() => _formError = crossFieldError);
      return;
    }
    setState(() {
      _formError = null;
      _submitting = true;
    });

    final HealthLogIdFactory mint =
        ref.read(healthLogFormIdFactoryProvider);
    final String id = widget.entryId ?? mint();
    final String notes = _notes.text.trim();
    final bool isVitals = _kind == HealthLogKind.vitals;
    final bool isSymptom = _kind == HealthLogKind.symptom;

    final HealthLogEntry entry = HealthLogEntry(
      id: id,
      patientId: _patientId,
      recordedAt: _recordedAt,
      kind: _kind,
      severity: isSymptom ? _severity : null,
      systolic: isVitals ? _parsedInt(_systolic) : null,
      diastolic: isVitals ? _parsedInt(_diastolic) : null,
      heartRate: isVitals ? _parsedInt(_heartRate) : null,
      temperatureF: isVitals ? _parsedDouble(_temperature) : null,
      notes: notes.isEmpty ? null : notes,
    );

    final HealthLog notifier = ref.read(healthLogProvider.notifier);
    if (widget.isEdit) {
      await notifier.updateEntry(entry);
    } else {
      await notifier.add(entry);
    }

    if (!mounted) return;
    _leave();
  }

  /// Rules that span more than one field, so they live outside the
  /// individual [TextFormField] validators:
  ///   - a vitals entry needs at least one reading, and
  ///   - a blood-pressure reading needs both the top and bottom numbers.
  String? _validateCrossFields() {
    if (_kind != HealthLogKind.vitals) return null;
    final int? sys = _parsedInt(_systolic);
    final int? dia = _parsedInt(_diastolic);
    final int? hr = _parsedInt(_heartRate);
    final double? temp = _parsedDouble(_temperature);
    final bool hasBpOne = sys != null || dia != null;
    final bool hasBpBoth = sys != null && dia != null;
    if (hasBpOne && !hasBpBoth) {
      return 'Enter both the top and bottom blood-pressure numbers.';
    }
    final bool hasAnyReading = hasBpBoth || hr != null || temp != null;
    if (!hasAnyReading) {
      return 'Add at least one reading — blood pressure, heart rate, or '
          'temperature.';
    }
    return null;
  }

  Future<void> _delete() async {
    final String? id = widget.entryId;
    if (id == null || _submitting) return;
    setState(() => _submitting = true);
    await ref.read(healthLogProvider.notifier).delete(id);
    if (!mounted) return;
    _leave();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medical/health-log');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<HealthLogFormData> hydration =
        ref.watch(healthLogFormHydrationProvider(widget.entryId));
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: hydration.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (HealthLogFormData data) {
            _hydrate(data);
            return Form(
              key: _formKey,
              child: ListView(
                key: HealthLogEntryForm.formKey,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: <Widget>[
                  PathHeader(
                    breadcrumbs: const <PathHeaderCrumb>[
                      PathHeaderCrumb(label: 'Home', route: '/'),
                      PathHeaderCrumb(label: 'Medical', route: '/medical'),
                      PathHeaderCrumb(
                        label: 'Health Log',
                        route: '/medical/health-log',
                      ),
                      PathHeaderCrumb(label: 'Entry'),
                    ],
                    title: widget.isEdit ? 'Edit entry' : 'New entry',
                    backLabel: 'Back to Health Log',
                    leadingIcon: Icons.monitor_heart_outlined,
                  ),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'What are you logging?'),
                  const SizedBox(height: 8),
                  _KindPicker(selected: _kind, onSelected: _selectKind),
                  if (_kind == HealthLogKind.vitals) ...<Widget>[
                    const SizedBox(height: 24),
                    _buildVitals(textTheme),
                  ],
                  if (_kind == HealthLogKind.symptom) ...<Widget>[
                    const SizedBox(height: 24),
                    _buildSeverity(textTheme),
                  ],
                  const SizedBox(height: 24),
                  _FieldLabel(label: _notesLabel(_kind)),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: HealthLogEntryForm.notesFieldKey,
                    controller: _notes,
                    maxLines: 5,
                    minLines: 3,
                    decoration: InputDecoration(
                      hintText: _notesHint(_kind),
                    ),
                    validator: (String? v) {
                      if (_kind == HealthLogKind.vitals) return null;
                      if ((v ?? '').trim().isEmpty) {
                        return _kind == HealthLogKind.symptom
                            ? 'Describe the symptom you noticed.'
                            : 'Add a few words for this note.';
                      }
                      return null;
                    },
                  ),
                  if (_formError != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _formError!,
                      key: HealthLogEntryForm.formErrorKey,
                      style: textTheme.bodyMedium?.copyWith(
                        color: careblazersColors.cta,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Semantics(
                    button: true,
                    label: widget.isEdit
                        ? 'Save changes to this entry.'
                        : 'Save this entry.',
                    child: ElevatedButton(
                      key: HealthLogEntryForm.saveButtonKey,
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: careblazersColors.cta,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        _submitting
                            ? 'Saving…'
                            : (widget.isEdit ? 'Save changes' : 'Save entry'),
                        style: textTheme.labelLarge
                            ?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                  if (widget.isEdit) ...<Widget>[
                    const SizedBox(height: 12),
                    Semantics(
                      button: true,
                      label: 'Delete this entry.',
                      child: OutlinedButton.icon(
                        key: HealthLogEntryForm.deleteButtonKey,
                        onPressed: _submitting ? null : _delete,
                        icon: Icon(
                          Icons.delete_outline,
                          color: careblazersColors.accentDeep,
                        ),
                        label: Text(
                          'Delete entry',
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

  Widget _buildVitals(TextTheme textTheme) {
    return Column(
      key: HealthLogEntryForm.vitalsSectionKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _FieldLabel(label: 'Blood pressure (mmHg)'),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: TextFormField(
                key: HealthLogEntryForm.systolicFieldKey,
                controller: _systolic,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  labelText: 'Systolic',
                  hintText: 'e.g. 130',
                ),
                validator: (String? v) => _intRangeValidator(
                  v,
                  min: 40,
                  max: 300,
                  noun: 'systolic',
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '/',
                style: textTheme.headlineSmall?.copyWith(
                  color: careblazersColors.primarySoft,
                ),
              ),
            ),
            Expanded(
              child: TextFormField(
                key: HealthLogEntryForm.diastolicFieldKey,
                controller: _diastolic,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  labelText: 'Diastolic',
                  hintText: 'e.g. 82',
                ),
                validator: (String? v) => _intRangeValidator(
                  v,
                  min: 20,
                  max: 200,
                  noun: 'diastolic',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const _FieldLabel(label: 'Heart rate (bpm)'),
        const SizedBox(height: 8),
        TextFormField(
          key: HealthLogEntryForm.heartRateFieldKey,
          controller: _heartRate,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: const InputDecoration(hintText: 'e.g. 76'),
          validator: (String? v) =>
              _intRangeValidator(v, min: 20, max: 250, noun: 'heart rate'),
        ),
        const SizedBox(height: 16),
        const _FieldLabel(label: 'Temperature (°F)'),
        const SizedBox(height: 8),
        TextFormField(
          key: HealthLogEntryForm.temperatureFieldKey,
          controller: _temperature,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: const InputDecoration(hintText: 'e.g. 98.6'),
          validator: (String? v) {
            final String t = (v ?? '').trim();
            if (t.isEmpty) return null;
            final double? parsed = double.tryParse(t);
            if (parsed == null) return 'Enter a number like 98.6.';
            if (parsed < 90 || parsed > 113) {
              return 'Enter a temperature between 90 and 113°F.';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildSeverity(TextTheme textTheme) {
    return Column(
      key: HealthLogEntryForm.severitySectionKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _FieldLabel(label: 'How severe? (optional)'),
        const SizedBox(height: 4),
        Text(
          '1 is mild, 5 is severe. Tap again to clear.',
          style: textTheme.bodyMedium?.copyWith(
            color: careblazersColors.primarySoft,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            for (int level = 1; level <= 5; level++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _SeverityChip(
                  level: level,
                  selected: _severity == level,
                  onTap: () => _toggleSeverity(level),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Numeric integer validator for an optional vitals field: empty passes
/// (the cross-field rule decides whether at least one reading is
/// required); a non-empty value must parse and sit inside the sane
/// [min]–[max] band.
String? _intRangeValidator(
  String? value, {
  required int min,
  required int max,
  required String noun,
}) {
  final String t = (value ?? '').trim();
  if (t.isEmpty) return null;
  final int? parsed = int.tryParse(t);
  if (parsed == null) return 'Enter a whole number.';
  if (parsed < min || parsed > max) {
    return 'Enter a $noun between $min and $max.';
  }
  return null;
}

class _KindPicker extends StatelessWidget {
  const _KindPicker({required this.selected, required this.onSelected});

  final HealthLogKind selected;
  final ValueChanged<HealthLogKind> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (final HealthLogKind kind in HealthLogKind.values)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: kind == HealthLogKind.values.last ? 0 : 8,
              ),
              child: _KindChip(
                kind: kind,
                selected: kind == selected,
                onTap: () => onSelected(kind),
              ),
            ),
          ),
      ],
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.kind,
    required this.selected,
    required this.onTap,
  });

  final HealthLogKind kind;
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
    final Color fg =
        selected ? careblazersColors.cta : careblazersColors.text;
    return Semantics(
      button: true,
      selected: selected,
      label: _kindLabel(kind),
      child: InkWell(
        key: HealthLogEntryForm.kindChipKey(kind),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(_kindGlyph(kind), size: 22, color: fg),
              const SizedBox(height: 6),
              Text(
                _kindLabel(kind),
                style: textTheme.bodyMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeverityChip extends StatelessWidget {
  const _SeverityChip({
    required this.level,
    required this.selected,
    required this.onTap,
  });

  final int level;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color border =
        selected ? careblazersColors.cta : careblazersColors.primarySoft;
    final Color fill =
        selected ? careblazersColors.cta : Colors.transparent;
    final Color fg = selected ? Colors.white : careblazersColors.text;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Severity $level of 5',
      child: InkWell(
        key: HealthLogEntryForm.severityChipKey(level),
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$level',
            style: textTheme.titleMedium?.copyWith(
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
          "We couldn't load this entry.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

String _notesLabel(HealthLogKind kind) {
  switch (kind) {
    case HealthLogKind.vitals:
      return 'Notes (optional)';
    case HealthLogKind.symptom:
      return 'What did you notice?';
    case HealthLogKind.note:
      return 'Note';
  }
}

String _notesHint(HealthLogKind kind) {
  switch (kind) {
    case HealthLogKind.vitals:
      return 'e.g. Taken resting, before breakfast.';
    case HealthLogKind.symptom:
      return 'e.g. Headache, holding her right temple.';
    case HealthLogKind.note:
      return 'e.g. Slept well, ate a full lunch, calmer afternoon.';
  }
}

String _kindLabel(HealthLogKind kind) {
  switch (kind) {
    case HealthLogKind.vitals:
      return 'Vitals';
    case HealthLogKind.symptom:
      return 'Symptom';
    case HealthLogKind.note:
      return 'Note';
  }
}

IconData _kindGlyph(HealthLogKind kind) {
  switch (kind) {
    case HealthLogKind.vitals:
      return Icons.favorite_outline;
    case HealthLogKind.symptom:
      return Icons.sick_outlined;
    case HealthLogKind.note:
      return Icons.sticky_note_2_outlined;
  }
}

/// Drop a trailing `.0` so a whole-degree temperature hydrates the field
/// as "99" not "99.0".
String _trimDouble(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toString();
}
