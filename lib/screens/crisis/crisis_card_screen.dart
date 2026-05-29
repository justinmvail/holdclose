import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/patient.dart';
import '../../providers/storage_provider.dart';
import '../../seed/mary_henderson.dart';
import '../../services/pdf_exporter.dart';
import '../../theme.dart';

part 'crisis_card_screen.g.dart';

/// Build-time flag (BUILD_SPEC.md §9.3 — `DEMO_MODE`). Mirrors the same
/// flag the auth + storage providers consume; declared here too so the
/// crisis card can ship its seed-on-first-launch behavior without
/// reaching into another provider's private state.
// ignore: do_not_use_environment
const bool _demoMode = bool.fromEnvironment('DEMO_MODE', defaultValue: false);

/// The [Patient] the crisis card seeds on first launch when storage is
/// empty (BUILD_SPEC.md §9.1). In demo mode this is [maryHenderson]; in
/// real-mode builds it's null so the caregiver starts on an empty card
/// they fill in inline.
///
/// Exposed as an overridable provider so widget tests can force-seed
/// (or force-empty) without flipping the global build define.
@Riverpod(keepAlive: true)
Patient? crisisCardDemoSeed(Ref ref) => _demoMode ? maryHenderson() : null;

/// Wall clock the crisis card samples for the "Updated …" footer.
/// Override in tests to keep golden + widget assertions stable.
@Riverpod(keepAlive: true)
DateTime Function() crisisCardClock(Ref ref) => DateTime.now;

/// Crisis card tab root (BUILD_SPEC.md §5.9).
///
/// A single scrollable card the caregiver can hand a paramedic or ER
/// nurse from. Reads + writes the singleton [Patient] row via
/// [StorageProvider.getPatient] / [StorageProvider.upsertPatient]. On
/// first launch with empty storage, demo-mode seeds [maryHenderson] so
/// the pitch demo opens to a populated card.
///
/// Every text field is inline-editable: tap to swap the static label
/// for a [TextField], focus-loss / submit persists. Lists (medications,
/// allergies, calms, escalates) edit per-row with add/remove buttons.
///
/// AppBar actions:
///   - 🖨 Print — invokes [PdfExporter.crisisCard] and hands the bytes
///     to [PdfExporter.sharePdf] so the OS share sheet (or AirPrint)
///     opens. Mirrors the journal export plumbing in §5.5.
///   - 📷 QR — pops a dialog with a placeholder QR pattern that encodes
///     `https://careblazers.app/patient/{patient.id}`. v1 has no public
///     endpoint behind that URL yet (§5.9 "TBD — for v1, the QR encodes
///     nothing or a placeholder URL"); the dialog is the seam the real
///     endpoint slots into later.
class CrisisCardScreen extends ConsumerStatefulWidget {
  const CrisisCardScreen({super.key});

  static const Key printButtonKey = Key('crisis-print');
  static const Key qrButtonKey = Key('crisis-qr');
  static const Key cardKey = Key('crisis-card');
  static const Key emptyPlaceholderKey = Key('crisis-empty');
  static const Key nameFieldKey = Key('crisis-field-name');
  static const Key ageFieldKey = Key('crisis-field-age');
  static const Key diagnosisFieldKey = Key('crisis-field-diagnosis');
  static const Key primaryCaregiverNameKey =
      Key('crisis-field-primary-caregiver-name');
  static const Key primaryCaregiverPhoneKey =
      Key('crisis-field-primary-caregiver-phone');
  static const Key poaNameKey = Key('crisis-field-poa-name');
  static const Key poaPhoneKey = Key('crisis-field-poa-phone');
  static const Key directiveOnFileKey = Key('crisis-field-directive-on-file');
  static const Key directiveDnrKey = Key('crisis-field-directive-dnr');
  static const Key qrDialogKey = Key('crisis-qr-dialog');
  static const Key updatedFooterKey = Key('crisis-footer-updated');

  @override
  ConsumerState<CrisisCardScreen> createState() => _CrisisCardScreenState();
}

class _CrisisCardScreenState extends ConsumerState<CrisisCardScreen> {
  Patient? _patient;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Defer the async bootstrap one microtask so `initState` itself
    // stays synchronous — Riverpod allows `ref.read` here but the
    // `StorageProvider.upsertPatient` write is async and we want the
    // first frame to render the loading placeholder, not block on it.
    Future<void>.microtask(_bootstrap);
  }

  Future<void> _bootstrap() async {
    final StorageProvider storage = ref.read(storageProvider);
    Patient? existing = await storage.getPatient();
    if (existing == null) {
      final Patient? seed = ref.read(crisisCardDemoSeedProvider);
      if (seed != null) {
        await storage.upsertPatient(seed);
        existing = seed;
      }
    }
    if (!mounted) return;
    setState(() {
      _patient = existing;
      _loading = false;
    });
  }

  Future<void> _persist(Patient updated) async {
    final StorageProvider storage = ref.read(storageProvider);
    await storage.upsertPatient(updated);
    if (!mounted) return;
    setState(() => _patient = updated);
  }

  Future<void> _print() async {
    final Patient? p = _patient;
    if (p == null) return;
    final PdfExporter exporter = ref.read(pdfExporterProvider);
    final Uint8List bytes = await exporter.crisisCard(p);
    await exporter.sharePdf(bytes, filename: 'crisis-card-${p.id}.pdf');
  }

  void _showQr() {
    final Patient? p = _patient;
    if (p == null) return;
    final String url = 'https://careblazers.app/patient/${p.id}';
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        final TextTheme dialogText = Theme.of(dialogContext).textTheme;
        return AlertDialog(
          key: CrisisCardScreen.qrDialogKey,
          title: const Text('Patient handoff QR'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(child: _PlaceholderQr(data: url, size: 220)),
                const SizedBox(height: 16),
                SelectableText(
                  url,
                  style: dialogText.bodyMedium?.copyWith(
                    color: careblazersColors.link,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Show this to a clinician to pull up the handoff page.',
                  style: dialogText.bodyMedium?.copyWith(
                    color: careblazersColors.primarySoft,
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        title: const Text('Hospital handoff card'),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          Semantics(
            button: true,
            enabled: _patient != null,
            label: 'Print or share the handoff card as a PDF.',
            child: IconButton(
              key: CrisisCardScreen.printButtonKey,
              icon: const Icon(Icons.print_outlined),
              tooltip: 'Print / share as PDF',
              onPressed: _patient == null ? null : _print,
            ),
          ),
          Semantics(
            button: true,
            enabled: _patient != null,
            label: 'Show the patient handoff QR code.',
            child: IconButton(
              key: CrisisCardScreen.qrButtonKey,
              icon: const Icon(Icons.qr_code),
              tooltip: 'Show patient QR code',
              onPressed: _patient == null ? null : _showQr,
            ),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final Patient? p = _patient;
    if (p == null) return const _EmptyPlaceholder();
    return _CardView(
      patient: p,
      now: ref.read(crisisCardClockProvider)(),
      onChanged: _persist,
    );
  }
}

// ---------------------------------------------------------------------------
// Empty placeholder (real-mode, first launch)
// ---------------------------------------------------------------------------

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Center(
      key: CrisisCardScreen.emptyPlaceholderKey,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          "Add your loved one's profile to start the handoff card.",
          style: textTheme.headlineMedium?.copyWith(
            color: careblazersColors.primary,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card layout
// ---------------------------------------------------------------------------

class _CardView extends StatelessWidget {
  const _CardView({
    required this.patient,
    required this.now,
    required this.onChanged,
  });

  final Patient patient;
  final DateTime now;
  final ValueChanged<Patient> onChanged;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      key: CrisisCardScreen.cardKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Container(
        decoration: BoxDecoration(
          color: careblazersColors.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _SectionLabel(label: '👤 Loved one'),
            const SizedBox(height: 4),
            _EditableText(
              fieldKey: CrisisCardScreen.nameFieldKey,
              label: 'Name',
              value: patient.name,
              onSubmitted: (String v) =>
                  onChanged(patient.copyWith(name: v.trim())),
            ),
            _EditableText(
              fieldKey: CrisisCardScreen.ageFieldKey,
              label: 'Age',
              value: patient.age.toString(),
              keyboardType: TextInputType.number,
              onSubmitted: (String v) {
                final int? parsed = int.tryParse(v.trim());
                if (parsed == null) return;
                onChanged(patient.copyWith(age: parsed));
              },
            ),
            _EditableText(
              fieldKey: CrisisCardScreen.diagnosisFieldKey,
              label: 'Diagnosis',
              value: patient.diagnosis,
              multiline: true,
              onSubmitted: (String v) =>
                  onChanged(patient.copyWith(diagnosis: v.trim())),
            ),
            _ReadOnlyRow(
              label: 'Diagnosed',
              value: _formatDate(patient.diagnosedAt),
            ),
            const SizedBox(height: 16),
            const _SectionLabel(label: '💊 Medications'),
            const SizedBox(height: 4),
            _MedicationList(
              medications: patient.medications,
              onChanged: (List<Medication> meds) =>
                  onChanged(patient.copyWith(medications: meds)),
            ),
            const SizedBox(height: 16),
            const _SectionLabel(label: '⚠ Allergies'),
            const SizedBox(height: 4),
            _StringBulletList(
              keyPrefix: 'allergy',
              items: patient.allergies,
              addLabel: 'Add allergy',
              onChanged: (List<String> next) =>
                  onChanged(patient.copyWith(allergies: next)),
            ),
            const SizedBox(height: 16),
            const _SectionLabel(label: 'What calms her'),
            const SizedBox(height: 4),
            _StringBulletList(
              keyPrefix: 'calms',
              items: patient.calms,
              addLabel: 'Add a comfort',
              onChanged: (List<String> next) =>
                  onChanged(patient.copyWith(calms: next)),
            ),
            const SizedBox(height: 16),
            const _SectionLabel(label: 'What escalates her'),
            const SizedBox(height: 4),
            _StringBulletList(
              keyPrefix: 'escalates',
              items: patient.escalates,
              addLabel: 'Add a trigger',
              onChanged: (List<String> next) =>
                  onChanged(patient.copyWith(escalates: next)),
            ),
            const SizedBox(height: 16),
            const _SectionLabel(label: '📞 Primary caregiver'),
            const SizedBox(height: 4),
            _EditableText(
              fieldKey: CrisisCardScreen.primaryCaregiverNameKey,
              label: 'Name',
              value: patient.primaryCaregiver.name,
              onSubmitted: (String v) => onChanged(
                patient.copyWith(
                  primaryCaregiver:
                      patient.primaryCaregiver.copyWith(name: v.trim()),
                ),
              ),
            ),
            _EditableText(
              fieldKey: CrisisCardScreen.primaryCaregiverPhoneKey,
              label: 'Phone',
              value: patient.primaryCaregiver.phone,
              keyboardType: TextInputType.phone,
              onSubmitted: (String v) => onChanged(
                patient.copyWith(
                  primaryCaregiver:
                      patient.primaryCaregiver.copyWith(phone: v.trim()),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _SectionLabel(label: '📞 Healthcare POA'),
            const SizedBox(height: 4),
            _EditableText(
              fieldKey: CrisisCardScreen.poaNameKey,
              label: 'Name',
              value: patient.healthcarePOA.name,
              onSubmitted: (String v) => onChanged(
                patient.copyWith(
                  healthcarePOA:
                      patient.healthcarePOA.copyWith(name: v.trim()),
                ),
              ),
            ),
            _EditableText(
              fieldKey: CrisisCardScreen.poaPhoneKey,
              label: 'Phone',
              value: patient.healthcarePOA.phone,
              keyboardType: TextInputType.phone,
              onSubmitted: (String v) => onChanged(
                patient.copyWith(
                  healthcarePOA:
                      patient.healthcarePOA.copyWith(phone: v.trim()),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _SectionLabel(label: '⚙ Advance directive'),
            const SizedBox(height: 4),
            _EditableText(
              fieldKey: CrisisCardScreen.directiveOnFileKey,
              label: 'On file at',
              value: patient.advanceDirective.onFileAt,
              onSubmitted: (String v) => onChanged(
                patient.copyWith(
                  advanceDirective: patient.advanceDirective
                      .copyWith(onFileAt: v.trim()),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  Text(
                    'DNR',
                    style: textTheme.bodyLarge?.copyWith(
                      color: careblazersColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Semantics(
                    toggled: patient.advanceDirective.dnr,
                    label: 'Do Not Resuscitate directive.',
                    child: Switch(
                      key: CrisisCardScreen.directiveDnrKey,
                      value: patient.advanceDirective.dnr,
                      activeThumbColor: careblazersColors.cta,
                      onChanged: (bool v) => onChanged(
                        patient.copyWith(
                          advanceDirective:
                              patient.advanceDirective.copyWith(dnr: v),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    patient.advanceDirective.dnr ? 'Yes' : 'No',
                    style: textTheme.bodyLarge?.copyWith(
                      color: careblazersColors.text,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              key: CrisisCardScreen.updatedFooterKey,
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Updated ${_formatDate(now)}',
                style: textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.primarySoft,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section label
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        label,
        style: textTheme.titleLarge?.copyWith(
          color: careblazersColors.primary,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Editable text field — tap to edit, blur/submit to save
// ---------------------------------------------------------------------------

class _EditableText extends StatefulWidget {
  const _EditableText({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onSubmitted,
    this.keyboardType,
    this.multiline = false,
  });

  final Key fieldKey;
  final String label;
  final String value;
  final ValueChanged<String> onSubmitted;
  final TextInputType? keyboardType;
  final bool multiline;

  @override
  State<_EditableText> createState() => _EditableTextState();
}

class _EditableTextState extends State<_EditableText> {
  bool _editing = false;
  late TextEditingController _controller;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_EditableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && oldWidget.value != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _enterEdit() {
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _commit() {
    if (!_editing) return;
    setState(() => _editing = false);
    final String next = _controller.text;
    if (next.trim() != widget.value.trim()) {
      widget.onSubmitted(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool hasLabel = widget.label.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (hasLabel) ...<Widget>[
            SizedBox(
              width: 110,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  widget.label,
                  style: textTheme.bodyLarge?.copyWith(
                    color: careblazersColors.primarySoft,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: _editing
                ? TextField(
                    key: widget.fieldKey,
                    controller: _controller,
                    focusNode: _focus,
                    keyboardType: widget.keyboardType,
                    minLines: 1,
                    maxLines: widget.multiline ? 4 : 1,
                    style: textTheme.bodyLarge?.copyWith(
                      color: careblazersColors.text,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: careblazersColors.background,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: careblazersColors.primarySoft
                              .withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                    onTapOutside: (PointerDownEvent _) => _commit(),
                    onSubmitted: (String _) => _commit(),
                  )
                : Semantics(
                    button: true,
                    label: hasLabel
                        ? 'Edit ${widget.label.toLowerCase()}.'
                        : 'Edit entry.',
                    child: InkWell(
                      key: widget.fieldKey,
                      onTap: _enterEdit,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 12,
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                widget.value.isEmpty
                                    ? 'Tap to add'
                                    : widget.value,
                                style: textTheme.bodyLarge?.copyWith(
                                  color: widget.value.isEmpty
                                      ? careblazersColors.primarySoft
                                      : careblazersColors.text,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: careblazersColors.primarySoft,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Read-only labelled row (diagnosed date — derived from diagnosedAt)
// ---------------------------------------------------------------------------

class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: textTheme.bodyLarge?.copyWith(
                color: careblazersColors.primarySoft,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: textTheme.bodyLarge?.copyWith(
                color: careblazersColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Editable string-bullet list (allergies, calms, escalates)
// ---------------------------------------------------------------------------

class _StringBulletList extends StatelessWidget {
  const _StringBulletList({
    required this.keyPrefix,
    required this.items,
    required this.addLabel,
    required this.onChanged,
  });

  final String keyPrefix;
  final List<String> items;
  final String addLabel;
  final ValueChanged<List<String>> onChanged;

  static Key itemKey(String keyPrefix, int index) =>
      Key('crisis-$keyPrefix-item-$index');
  static Key removeKey(String keyPrefix, int index) =>
      Key('crisis-$keyPrefix-remove-$index');
  static Key addKey(String keyPrefix) => Key('crisis-$keyPrefix-add');

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < items.length; i++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Text(
                '•',
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.primarySoft,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _EditableText(
                  fieldKey: itemKey(keyPrefix, i),
                  label: '',
                  value: items[i],
                  onSubmitted: (String v) {
                    final List<String> next = List<String>.from(items);
                    next[i] = v.trim();
                    onChanged(next);
                  },
                ),
              ),
              Semantics(
                button: true,
                label: 'Remove this entry.',
                child: IconButton(
                  key: removeKey(keyPrefix, i),
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: careblazersColors.primarySoft,
                  ),
                  tooltip: 'Remove',
                  onPressed: () {
                    final List<String> next = List<String>.from(items)
                      ..removeAt(i);
                    onChanged(next);
                  },
                ),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 16),
          child: Semantics(
            button: true,
            label: '$addLabel.',
            child: TextButton.icon(
              key: addKey(keyPrefix),
              icon: const Icon(Icons.add, size: 18),
              label: Text(addLabel),
              style: TextButton.styleFrom(
                foregroundColor: careblazersColors.primary,
              ),
              onPressed: () {
                final List<String> next = List<String>.from(items)..add('');
                onChanged(next);
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Editable medication list
// ---------------------------------------------------------------------------

class _MedicationList extends StatelessWidget {
  const _MedicationList({
    required this.medications,
    required this.onChanged,
  });

  final List<Medication> medications;
  final ValueChanged<List<Medication>> onChanged;

  static Key nameKey(int index) => Key('crisis-med-name-$index');
  static Key doseKey(int index) => Key('crisis-med-dose-$index');
  static Key scheduleKey(int index) => Key('crisis-med-schedule-$index');
  static Key removeKey(int index) => Key('crisis-med-remove-$index');
  static const Key addKey = Key('crisis-med-add');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < medications.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              decoration: BoxDecoration(
                color: careblazersColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  _EditableText(
                    fieldKey: nameKey(i),
                    label: 'Name',
                    value: medications[i].name,
                    onSubmitted: (String v) {
                      final List<Medication> next =
                          List<Medication>.from(medications);
                      next[i] = next[i].copyWith(name: v.trim());
                      onChanged(next);
                    },
                  ),
                  _EditableText(
                    fieldKey: doseKey(i),
                    label: 'Dose',
                    value: medications[i].dose,
                    onSubmitted: (String v) {
                      final List<Medication> next =
                          List<Medication>.from(medications);
                      next[i] = next[i].copyWith(dose: v.trim());
                      onChanged(next);
                    },
                  ),
                  _EditableText(
                    fieldKey: scheduleKey(i),
                    label: 'Schedule',
                    value: medications[i].schedule,
                    onSubmitted: (String v) {
                      final List<Medication> next =
                          List<Medication>.from(medications);
                      next[i] = next[i].copyWith(schedule: v.trim());
                      onChanged(next);
                    },
                  ),
                  Semantics(
                    button: true,
                    label: 'Remove this medication.',
                    child: TextButton.icon(
                      key: removeKey(i),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Remove'),
                      style: TextButton.styleFrom(
                        foregroundColor: careblazersColors.primarySoft,
                      ),
                      onPressed: () {
                        final List<Medication> next =
                            List<Medication>.from(medications)..removeAt(i);
                        onChanged(next);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Semantics(
            button: true,
            label: 'Add medication.',
            child: TextButton.icon(
              key: addKey,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add medication'),
              style: TextButton.styleFrom(
                foregroundColor: careblazersColors.primary,
              ),
              onPressed: () {
                final List<Medication> next = List<Medication>.from(medications)
                  ..add(const Medication(name: '', dose: '', schedule: ''));
                onChanged(next);
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Placeholder QR
// ---------------------------------------------------------------------------

/// Deterministic, scan-unsafe placeholder QR pattern (BUILD_SPEC.md §5.9
/// — "for v1, the QR encodes nothing or a placeholder URL"). Renders the
/// three corner-finder squares + a 21x21 module grid seeded from a stable
/// hash of [data], so the dialog *looks* like a QR without us shipping a
/// real encoder. The actual URL is shown beneath it for any human who
/// needs to type it.
class _PlaceholderQr extends StatelessWidget {
  const _PlaceholderQr({required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          'Placeholder QR code for the patient handoff URL. The URL is '
          'shown below for clinicians who cannot scan it.',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(
            color: careblazersColors.primarySoft.withValues(alpha: 0.4),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.all(8),
        child: CustomPaint(
          painter: _PlaceholderQrPainter(data: data),
        ),
      ),
    );
  }
}

class _PlaceholderQrPainter extends CustomPainter {
  _PlaceholderQrPainter({required this.data});

  final String data;

  static const int _modules = 21;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint fill = Paint()..color = const Color(0xFF1F2A44);
    final double cell = size.width / _modules;
    final List<List<bool>> grid = _buildGrid(data);
    for (int y = 0; y < _modules; y++) {
      for (int x = 0; x < _modules; x++) {
        if (!grid[y][x]) continue;
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell, cell),
          fill,
        );
      }
    }
  }

  /// Build a 21x21 grid that mimics the visual rhythm of a QR code:
  /// three 7x7 finder patterns in the corners, a quiet zone of one
  /// module padding inside the border, and a deterministic pseudo-random
  /// fill for the remaining modules seeded from [data]. Pure visual —
  /// nothing here decodes back to a URL.
  List<List<bool>> _buildGrid(String data) {
    final List<List<bool>> grid = List<List<bool>>.generate(
      _modules,
      (_) => List<bool>.filled(_modules, false),
    );

    // Finder pattern: 7x7 square with an outer ring + center 3x3 block.
    void drawFinder(int ox, int oy) {
      for (int y = 0; y < 7; y++) {
        for (int x = 0; x < 7; x++) {
          final bool outer = x == 0 || x == 6 || y == 0 || y == 6;
          final bool inner = x >= 2 && x <= 4 && y >= 2 && y <= 4;
          grid[oy + y][ox + x] = outer || inner;
        }
      }
    }

    drawFinder(0, 0);
    drawFinder(_modules - 7, 0);
    drawFinder(0, _modules - 7);

    // Pseudo-random fill driven off a stable hash of `data`. Skip the
    // three finder zones so the corners stay recognizable.
    final math.Random rng = math.Random(_stableHash(data));
    bool insideFinder(int x, int y) {
      return (x < 8 && y < 8) ||
          (x >= _modules - 8 && y < 8) ||
          (x < 8 && y >= _modules - 8);
    }

    for (int y = 0; y < _modules; y++) {
      for (int x = 0; x < _modules; x++) {
        if (insideFinder(x, y)) continue;
        if (rng.nextDouble() < 0.48) grid[y][x] = true;
      }
    }
    return grid;
  }

  int _stableHash(String s) {
    // FNV-1a 32-bit — deterministic across hosts (unlike `s.hashCode`,
    // which the Dart VM may randomize per-isolate).
    int hash = 0x811c9dc5;
    for (int i = 0; i < s.length; i++) {
      hash ^= s.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  @override
  bool shouldRepaint(_PlaceholderQrPainter old) => old.data != data;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime t) {
  return '${_months[t.month - 1]} ${t.day}, ${t.year}';
}
