import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/medication.dart';
import '../../models/medication_draft.dart';
import '../../providers/patient_timeline_provider.dart'
    show invalidatePatientTimeline;
import '../../services/medication_repository.dart';
import '../../theme.dart';
import '../../widgets/form/labelled_field.dart';
import '../../widgets/form_validation.dart';
import '../../widgets/path_header.dart';
import 'medication_form_screen.dart'
    show TitleCaseTextFormatter, medicationFormIdFactoryProvider;
import 'medication_list_screen.dart';
import 'prescription_scan_flow.dart';

/// Review-and-approve screen for a scanned prescription
/// (`/medications/scan/review`).
///
/// The AI photo-scan proposes a [MedicationDraft]; this screen shows what
/// it read in **editable** fields and saves NOTHING until the caregiver
/// taps Save. That is the human-in-the-loop gate — the AI transcribes to
/// save typing, the caregiver stays the decision-maker (Caregiver AI
/// Principle 2). A failed/blank scan simply opens this screen empty, so the
/// same surface doubles as fast manual entry.
///
/// Because a label wraps around the bottle, one photo rarely shows
/// everything — "Scan another side" runs a second scan and **fills the
/// empty fields** (Rx #, quantity, refills, pharmacy) without clobbering
/// what's already there.
class MedicationImportReviewScreen extends ConsumerStatefulWidget {
  const MedicationImportReviewScreen({
    super.key,
    required this.draft,
    this.uncertain = const <String>{},
  });

  /// The AI's proposed read. An empty draft renders blank fields.
  final MedicationDraft draft;

  /// JSON keys the scan flagged as read-but-not-confident (its `uncertain`
  /// array — see [uncertainFieldsFrom]). Each named field gets an amber
  /// "check this — we weren't sure" treatment so the caregiver verifies it
  /// before saving. Defaults to none; a blank/manual scan carries an empty
  /// set. Keys match the extraction schema (`name`, `dosage`, `route`, …).
  final Set<String> uncertain;

  /// Pull the scan's `uncertain` array out of a raw extraction JSON [map]
  /// into a set of field keys. Tolerant of a missing/malformed value (any
  /// non-list, or non-string entries, are ignored → empty set), so an old
  /// or partial reply never crashes the review screen. Visible for the
  /// scan flow that constructs this screen, and for tests.
  static Set<String> uncertainFieldsFrom(Map<String, dynamic> map) {
    final dynamic raw = map['uncertain'];
    if (raw is! List) return const <String>{};
    return <String>{
      for (final dynamic e in raw)
        if (e is String && e.trim().isNotEmpty) e.trim(),
    };
  }

  static const Key bannerKey = Key('rx-import-banner');
  static const Key uncertainBannerKey = Key('rx-import-uncertain-banner');
  static const Key scanAnotherKey = Key('rx-import-scan-another');
  static const Key nameFieldKey = Key('rx-import-name');
  static const Key dosageFieldKey = Key('rx-import-dosage');
  static const Key routeDropdownKey = Key('rx-import-route');
  static const Key prescriberFieldKey = Key('rx-import-prescriber');
  static const Key notesFieldKey = Key('rx-import-notes');
  static const Key rxNumberFieldKey = Key('rx-import-rxnumber');
  static const Key quantityFieldKey = Key('rx-import-quantity');
  static const Key refillsFieldKey = Key('rx-import-refills');
  static const Key pharmacyNameFieldKey = Key('rx-import-pharmacy-name');
  static const Key pharmacyPhoneFieldKey = Key('rx-import-pharmacy-phone');
  static const Key dateFilledFieldKey = Key('rx-import-date-filled');
  static const Key discardAfterFieldKey = Key('rx-import-discard-after');
  static const Key saveButtonKey = Key('rx-import-save');
  static const Key discardButtonKey = Key('rx-import-discard');

  @override
  ConsumerState<MedicationImportReviewScreen> createState() =>
      _MedicationImportReviewScreenState();
}

class _MedicationImportReviewScreenState
    extends ConsumerState<MedicationImportReviewScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _dosage;
  late final TextEditingController _prescriber;
  late final TextEditingController _notes;
  late final TextEditingController _rxNumber;
  late final TextEditingController _quantity;
  late final TextEditingController _refills;
  late final TextEditingController _pharmacyName;
  late final TextEditingController _pharmacyPhone;
  late final TextEditingController _dateFilled;
  late final TextEditingController _discardAfter;
  late MedicationRoute _route;
  bool _submitting = false;
  bool _scanning = false;

  /// Fields the scan flagged as read-but-not-confident, shown with the
  /// amber "check this" treatment. Mutable: a field clears from the set the
  /// moment the caregiver edits it (they've now verified it themselves).
  late Set<String> _uncertain;

  @override
  void initState() {
    super.initState();
    final MedicationDraft d = widget.draft;
    _uncertain = <String>{...widget.uncertain};
    _name = TextEditingController(text: d.name ?? '');
    _dosage = TextEditingController(text: d.dosage ?? '');
    _prescriber = TextEditingController(text: d.prescriber ?? '');
    _notes = TextEditingController(text: d.notes ?? '');
    _rxNumber = TextEditingController(text: d.rxNumber ?? '');
    _quantity = TextEditingController(text: d.quantity ?? '');
    _refills = TextEditingController(text: d.refills ?? '');
    _pharmacyName = TextEditingController(text: d.pharmacyName ?? '');
    _pharmacyPhone = TextEditingController(text: d.pharmacyPhone ?? '');
    _dateFilled = TextEditingController(text: d.dateFilled ?? '');
    _discardAfter = TextEditingController(text: d.discardAfter ?? '');
    _route = d.route ?? MedicationRoute.oral;
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name,
      _dosage,
      _prescriber,
      _notes,
      _rxNumber,
      _quantity,
      _refills,
      _pharmacyName,
      _pharmacyPhone,
      _dateFilled,
      _discardAfter,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _clean(TextEditingController c) {
    final String t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _save() async {
    if (_submitting) return;
    if (!validateAndScrollToFirstError(_formKey)) return;
    setState(() => _submitting = true);

    final MedicationRepository repo =
        ref.read(medicationRepositoryBackendProvider);
    final String Function() mint = ref.read(medicationFormIdFactoryProvider);

    final Medication medication = Medication(
      id: 'med-${mint()}',
      name: _name.text.trim(),
      dosage: _dosage.text.trim(),
      route: _route,
      prescriber: _clean(_prescriber),
      notes: _clean(_notes),
      rxNumber: _clean(_rxNumber),
      quantity: _clean(_quantity),
      refills: _clean(_refills),
      pharmacyName: _clean(_pharmacyName),
      pharmacyPhone: _clean(_pharmacyPhone),
      dateFilled: _clean(_dateFilled),
      discardAfter: _clean(_discardAfter),
    );

    await repo.upsertMedication(medication);
    ref.invalidate(medicationListProvider);
    invalidatePatientTimeline(ref);

    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medications');
    }
  }

  /// Fill [c] from [value] only when the field is currently empty — the
  /// second-photo merge tops up gaps, it never overwrites reviewed data.
  void _fillIfEmpty(TextEditingController c, String? value) {
    if (c.text.trim().isEmpty && value != null && value.trim().isNotEmpty) {
      c.text = value.trim();
    }
  }

  Future<void> _scanAnotherSide() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    final MedicationDraft? draft = await capturePrescriptionDraft(context, ref);
    if (!mounted) return;
    setState(() => _scanning = false);
    if (draft == null) return; // cancelled
    if (draft.isEmpty) {
      showScanEmptyHint(context);
      return;
    }
    setState(() {
      _fillIfEmpty(_name, draft.name);
      _fillIfEmpty(_dosage, draft.dosage);
      _fillIfEmpty(_prescriber, draft.prescriber);
      _fillIfEmpty(_notes, draft.notes);
      _fillIfEmpty(_rxNumber, draft.rxNumber);
      _fillIfEmpty(_quantity, draft.quantity);
      _fillIfEmpty(_refills, draft.refills);
      _fillIfEmpty(_pharmacyName, draft.pharmacyName);
      _fillIfEmpty(_pharmacyPhone, draft.pharmacyPhone);
      _fillIfEmpty(_dateFilled, draft.dateFilled);
      _fillIfEmpty(_discardAfter, draft.discardAfter);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Added details from the second photo.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme tt = theme.textTheme;
    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Medications', route: '/medications'),
                  PathHeaderCrumb(label: 'Review scan'),
                ],
                title: 'Review scan',
                backLabel: 'Back to Medications',
                leadingIcon: Icons.document_scanner_outlined,
              ),
            ),
            Expanded(
              child: Form(
                key: _formKey,
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                        children: <Widget>[
                          const _ReviewBanner(
                            key: MedicationImportReviewScreen.bannerKey,
                          ),
                          if (_uncertain.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 12),
                            _UncertainBanner(
                              key: MedicationImportReviewScreen
                                  .uncertainBannerKey,
                              count: _uncertain.length,
                            ),
                          ],
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: MedicationImportReviewScreen.scanAnotherKey,
                            onPressed: _scanning ? null : _scanAnotherSide,
                            icon: const Icon(Icons.add_a_photo_outlined),
                            label: Text(_scanning
                                ? 'Reading…'
                                : 'Scan another side of the label'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: context.hc.primary,
                              minimumSize: const Size.fromHeight(48),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _textField(
                            label: 'Name',
                            controller: _name,
                            fieldKey:
                                MedicationImportReviewScreen.nameFieldKey,
                            fieldName: 'name',
                            hint: 'e.g. Tizanidine',
                            titleCase: true,
                            validator: (String? v) =>
                                (v == null || v.trim().isEmpty)
                                    ? 'Name is required.'
                                    : null,
                          ),
                          _textField(
                            label: 'Dosage',
                            controller: _dosage,
                            fieldKey:
                                MedicationImportReviewScreen.dosageFieldKey,
                            fieldName: 'dosage',
                            hint: 'e.g. 2 mg',
                            validator: (String? v) =>
                                (v == null || v.trim().isEmpty)
                                    ? 'Dosage is required.'
                                    : null,
                          ),
                          LabelledField(
                            label: 'Route',
                            child: DropdownButtonFormField<MedicationRoute>(
                              key: MedicationImportReviewScreen.routeDropdownKey,
                              initialValue: _route,
                              isExpanded: true,
                              items: const <DropdownMenuItem<MedicationRoute>>[
                                DropdownMenuItem<MedicationRoute>(
                                  value: MedicationRoute.oral,
                                  child: Text('Oral (by mouth)',
                                      overflow: TextOverflow.ellipsis),
                                ),
                                DropdownMenuItem<MedicationRoute>(
                                  value: MedicationRoute.topical,
                                  child: Text('Topical (patch / cream)',
                                      overflow: TextOverflow.ellipsis),
                                ),
                                DropdownMenuItem<MedicationRoute>(
                                  value: MedicationRoute.injection,
                                  child: Text('Injection',
                                      overflow: TextOverflow.ellipsis),
                                ),
                                DropdownMenuItem<MedicationRoute>(
                                  value: MedicationRoute.other,
                                  child: Text('Other',
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ],
                              onChanged: (MedicationRoute? next) {
                                if (next == null) return;
                                setState(() => _route = next);
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                          _textField(
                            label: 'Prescriber (optional)',
                            controller: _prescriber,
                            fieldKey:
                                MedicationImportReviewScreen.prescriberFieldKey,
                            fieldName: 'prescriber',
                            hint: 'e.g. Dr. Berger',
                            titleCase: true,
                          ),
                          _textField(
                            label: 'Directions / notes (optional)',
                            controller: _notes,
                            fieldKey:
                                MedicationImportReviewScreen.notesFieldKey,
                            fieldName: 'notes',
                            hint: 'e.g. Take one tablet by mouth at bedtime.',
                            maxLines: 3,
                          ),
                          const SizedBox(height: 8),
                          _SectionLabel(
                            'Prescription details (optional)',
                            color: context.hc.primary,
                          ),
                          _textField(
                            label: 'Rx number',
                            controller: _rxNumber,
                            fieldKey:
                                MedicationImportReviewScreen.rxNumberFieldKey,
                            fieldName: 'rxNumber',
                            hint: 'e.g. 1687749',
                          ),
                          _textField(
                            label: 'Quantity',
                            controller: _quantity,
                            fieldKey:
                                MedicationImportReviewScreen.quantityFieldKey,
                            fieldName: 'quantity',
                            hint: 'e.g. 180',
                          ),
                          _textField(
                            label: 'Refills remaining',
                            controller: _refills,
                            fieldKey:
                                MedicationImportReviewScreen.refillsFieldKey,
                            fieldName: 'refills',
                            hint: 'e.g. 3',
                          ),
                          _textField(
                            label: 'Pharmacy',
                            controller: _pharmacyName,
                            fieldKey: MedicationImportReviewScreen
                                .pharmacyNameFieldKey,
                            fieldName: 'pharmacyName',
                            hint: 'e.g. CVS Pharmacy',
                          ),
                          _textField(
                            label: 'Pharmacy phone',
                            controller: _pharmacyPhone,
                            fieldKey: MedicationImportReviewScreen
                                .pharmacyPhoneFieldKey,
                            fieldName: 'pharmacyPhone',
                            hint: 'e.g. 843-767-4500',
                            keyboardType: TextInputType.phone,
                          ),
                          _textField(
                            label: 'Date filled',
                            controller: _dateFilled,
                            fieldKey:
                                MedicationImportReviewScreen.dateFilledFieldKey,
                            fieldName: 'dateFilled',
                            hint: 'e.g. 12/3/21',
                          ),
                          _textField(
                            label: 'Discard after',
                            controller: _discardAfter,
                            fieldKey: MedicationImportReviewScreen
                                .discardAfterFieldKey,
                            fieldName: 'discardAfter',
                            hint: 'e.g. 12/3/22',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'You can set dose times and days after saving, '
                            'from the medication’s edit screen.',
                            style: tt.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Semantics(
                            button: true,
                            label: 'Save this medication to the list.',
                            child: ElevatedButton(
                              key: MedicationImportReviewScreen.saveButtonKey,
                              onPressed: _submitting ? null : _save,
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size.fromHeight(56),
                                backgroundColor: context.hc.cta,
                                foregroundColor: Colors.white,
                              ),
                              child: Text(
                                _submitting ? 'Saving…' : 'Save medication',
                                style: tt.labelLarge
                                    ?.copyWith(color: Colors.white),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            key: MedicationImportReviewScreen.discardButtonKey,
                            onPressed: _submitting
                                ? null
                                : () {
                                    if (context.canPop()) {
                                      context.pop();
                                    } else {
                                      context.go('/medications');
                                    }
                                  },
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  context.hc.text.withValues(alpha: 0.65),
                              minimumSize: const Size.fromHeight(44),
                            ),
                            child: const Text('Discard'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact labelled text field builder — keeps the long form readable.
  ///
  /// When [fieldName] is one the scan flagged as uncertain ([_uncertain]),
  /// the field paints an amber border + a "check this — we weren't sure"
  /// hint so the caregiver verifies before saving; editing the field clears
  /// its uncertain flag (they've now confirmed it themselves).
  Widget _textField({
    required String label,
    required TextEditingController controller,
    required Key fieldKey,
    String? fieldName,
    String? hint,
    String? Function(String?)? validator,
    int maxLines = 1,
    bool titleCase = false,
    TextInputType? keyboardType,
  }) {
    final bool uncertain =
        fieldName != null && _uncertain.contains(fieldName);
    final Color amber = context.hc.cta;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: LabelledField(
        label: label,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextFormField(
              key: fieldKey,
              controller: controller,
              maxLines: maxLines,
              minLines: maxLines > 1 ? 2 : 1,
              keyboardType: keyboardType,
              textInputAction: maxLines > 1
                  ? TextInputAction.newline
                  : TextInputAction.next,
              textCapitalization: titleCase
                  ? TextCapitalization.words
                  : TextCapitalization.none,
              inputFormatters: titleCase
                  ? <TextInputFormatter>[TitleCaseTextFormatter()]
                  : null,
              onChanged: uncertain
                  // The caregiver has looked at it — drop the flag so the
                  // amber treatment doesn't nag once they've verified.
                  ? (_) => setState(() => _uncertain.remove(fieldName))
                  : null,
              decoration: InputDecoration(
                hintText: hint,
                enabledBorder: uncertain
                    ? OutlineInputBorder(
                        borderSide: BorderSide(color: amber, width: 1.5),
                      )
                    : null,
              ),
              validator: validator,
            ),
            if (uncertain) ...<Widget>[
              const SizedBox(height: 6),
              Row(
                key: _uncertainHintKey(fieldName),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.error_outline, size: 16, color: amber),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "Check this — we weren't sure we read it right.",
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: amber),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Per-field key for the amber "check this" hint, so a test can target
  /// exactly the flagged field's caption.
  static Key _uncertainHintKey(String fieldName) =>
      Key('rx-import-uncertain-$fieldName');
}

/// Section divider label inside the review form.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Amber caution banner shown when the scan flagged one or more fields as
/// read-but-not-confident. Points the caregiver at the amber-outlined
/// fields below to verify before saving — the human-approval gate is what
/// makes a low-confidence read safe.
class _UncertainBanner extends StatelessWidget {
  const _UncertainBanner({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final Color amber = context.hc.cta;
    final String fields = count == 1 ? 'one field' : '$count fields';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: amber),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 20, color: amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "We weren't sure we read $fields correctly — they're marked "
              'below in amber. Please check them before you save.',
              style: tt.bodyMedium?.copyWith(color: context.hc.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Transparency banner — tells the caregiver the fields came from the
/// photo and that nothing saves until they approve.
class _ReviewBanner extends StatelessWidget {
  const _ReviewBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.hc.surfaceWarm,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hc.cta.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.document_scanner_outlined,
              size: 20, color: context.hc.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'We read these from your photo. Check every field before '
              'saving — nothing is added to your medications until you '
              'tap Save. A label wraps around the bottle, so use “Scan '
              'another side” to fill in anything missing.',
              style: tt.bodyMedium?.copyWith(color: context.hc.text),
            ),
          ),
        ],
      ),
    );
  }
}
