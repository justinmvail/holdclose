import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/document.dart';
import '../../models/patient.dart';
import '../../providers/documents_provider.dart';
import '../../providers/share_provider.dart';
import '../../providers/storage_provider.dart';
import '../../theme.dart';
import '../../widgets/document_scan_view.dart';
import '../../widgets/path_header.dart';

part 'poa_screen.g.dart';

/// Fallback loved-one id used when no [Patient] is on file yet — mirrors
/// the health-log / care-plan forms so a freshly added POA lines up with
/// the demo seed's `maryHenderson` id.
const String _fallbackPatientId = 'demo-patient-mary';

/// Everything the POA screen renders, bundled so the screen consumes a
/// single [AsyncValue] (TASKS.md Phase 14.24).
///
/// The Cards & Documents → Power of Attorney page shows a single document
/// per loved one — the active POA on file. [doc] is null until one is
/// added; [patient] anchors the form's `patientId` and may be null on a
/// fresh real-mode install.
@immutable
class PoaView {
  const PoaView({required this.patient, required this.doc});

  final Patient? patient;
  final PowerOfAttorneyDoc? doc;
}

/// Bundles the loved one + their single POA document for [PoaScreen]
/// (TASKS.md Phase 14.24).
///
/// Watches [powerOfAttorneyDocsProvider] (not the repository directly) so
/// an edit saved through the notifier refreshes the view without a manual
/// invalidate. Tests override this provider wholesale with a fixed
/// [PoaView].
@riverpod
Future<PoaView> poaView(Ref ref) async {
  final StorageProvider storage = ref.watch(storageProvider);
  final Patient? patient = await storage.getPatient();

  final List<PowerOfAttorneyDoc> docs =
      await ref.watch(powerOfAttorneyDocsProvider.future);
  final List<PowerOfAttorneyDoc> mine = patient == null
      ? docs
      : docs
          .where((PowerOfAttorneyDoc d) => d.patientId == patient.id)
          .toList();

  return PoaView(
    patient: patient,
    doc: mine.isEmpty ? null : mine.first,
  );
}

/// Power of Attorney screen at `/medical/cards/poa` (TASKS.md Phase
/// 14.24, BUILD_SPEC.md §5.13 / §5.17).
///
/// A read-only view of the single POA document on file: who holds
/// authority ([PowerOfAttorneyDoc.agentName]), the optional successor
/// ([PowerOfAttorneyDoc.alternateName]), the [PoaScope] (a chip), the
/// effective date, and a tappable scan thumbnail that opens a full-screen
/// viewer. A Share action hands a plain-text summary to the OS share
/// sheet. The AppBar Edit action pushes the edit form at
/// `/medical/cards/poa/edit`.
///
/// Organisational record-keeping — nothing here is legal advice.
class PoaScreen extends ConsumerWidget {
  const PoaScreen({super.key});

  static const Key editActionKey = Key('poa-edit');
  static const Key scrollKey = Key('poa-scroll');
  static const Key documentCardKey = Key('poa-document-card');
  static const Key emptyPlaceholderKey = Key('poa-empty');
  static const Key emptyCtaKey = Key('poa-empty-cta');
  static const Key shareButtonKey = Key('poa-share');
  static const Key scopeChipKey = Key('poa-scope-chip');

  static const String editRoute = '/medical/cards/poa/edit';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PoaView> async = ref.watch(poaViewProvider);

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: careblazersColors.background,
        elevation: 0,
        actions: <Widget>[
          Semantics(
            button: true,
            label: 'Edit the power of attorney.',
            child: IconButton(
              key: editActionKey,
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit power of attorney',
              color: careblazersColors.primary,
              onPressed: () => context.push(editRoute),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (PoaView view) => _Body(view: view),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.view});

  final PoaView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PowerOfAttorneyDoc? doc = view.doc;
    return SingleChildScrollView(
      key: PoaScreen.scrollKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const PathHeader(
            breadcrumbs: <PathHeaderCrumb>[
              PathHeaderCrumb(label: 'Home', route: '/'),
              PathHeaderCrumb(label: 'Medical', route: '/medical'),
              PathHeaderCrumb(
                label: 'Cards & Documents',
                route: '/medical/cards',
              ),
              PathHeaderCrumb(label: 'Power of Attorney'),
            ],
            title: 'Power of Attorney',
            backLabel: 'Back to Cards & Documents',
            leadingIcon: Icons.gavel_outlined,
          ),
          const SizedBox(height: 16),
          if (doc == null)
            const _EmptyPlaceholder()
          else
            _DocumentCard(doc: doc, patient: view.patient),
        ],
      ),
    );
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: PoaScreen.emptyPlaceholderKey,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.gavel_outlined,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'No power of attorney on file.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Record who can make decisions for your loved one, so the '
            'paperwork is at hand when it matters.',
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Semantics(
            button: true,
            label: 'Add power of attorney. Open the form.',
            child: ElevatedButton.icon(
              key: PoaScreen.emptyCtaKey,
              onPressed: () => context.push(PoaScreen.editRoute),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                'Add power of attorney',
                style: textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: careblazersColors.cta,
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

class _DocumentCard extends ConsumerWidget {
  const _DocumentCard({required this.doc, required this.patient});

  final PowerOfAttorneyDoc doc;
  final Patient? patient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: PoaScreen.documentCardKey,
      width: double.infinity,
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: careblazersColors.primary.withValues(alpha: 0.12),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Agent',
                      style: textTheme.bodyMedium?.copyWith(
                        color: careblazersColors.primarySoft,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      doc.agentName,
                      style: textTheme.titleLarge?.copyWith(
                        color: careblazersColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              _ScopeChip(scope: doc.scope),
            ],
          ),
          const SizedBox(height: 16),
          if (doc.alternateName != null && doc.alternateName!.isNotEmpty)
            _LabeledValue(label: 'Alternate', value: doc.alternateName!),
          _LabeledValue(
            label: 'Effective',
            value: _formatDate(doc.effectiveDate),
          ),
          const SizedBox(height: 16),
          DocumentScanThumbnail(path: doc.scanPath, label: 'Scan'),
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: 'Share the power of attorney details.',
            child: OutlinedButton.icon(
              key: PoaScreen.shareButtonKey,
              onPressed: () =>
                  ref.read(sharerProvider).share(_shareText(), subject: _subject()),
              icon: Icon(Icons.ios_share, color: careblazersColors.link),
              label: Text(
                'Share',
                style: textTheme.labelLarge?.copyWith(
                  color: careblazersColors.link,
                ),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                side: BorderSide(color: careblazersColors.link),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _subject() => 'Power of Attorney — ${patient?.name ?? 'Loved one'}';

  String _shareText() {
    final StringBuffer b = StringBuffer()
      ..writeln('Power of Attorney')
      ..writeln('Agent: ${doc.agentName}');
    if (doc.alternateName != null && doc.alternateName!.isNotEmpty) {
      b.writeln('Alternate: ${doc.alternateName}');
    }
    b
      ..writeln('Scope: ${_scopeLabel(doc.scope)}')
      ..writeln('Effective: ${_formatDate(doc.effectiveDate)}');
    return b.toString().trimRight();
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.scope});

  final PoaScope scope;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: PoaScreen.scopeChipKey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: careblazersColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _scopeLabel(scope),
        style: textTheme.bodyMedium?.copyWith(
          color: careblazersColors.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LabeledValue extends StatelessWidget {
  const _LabeledValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: careblazersColors.primarySoft,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
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
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          "We couldn't load the power of attorney.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit form
// ---------------------------------------------------------------------------

/// Mint a new id for the POA row the form inserts. Overridable for tests
/// + the demo tour so id sequences are deterministic.
typedef PoaIdFactory = String Function();

String _defaultPoaIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'poa-$ms-$rand';
}

/// ID factory the form uses. Tests override this with a monotonic counter
/// so the inserted id is stable across runs.
@Riverpod(keepAlive: true)
PoaIdFactory poaFormIdFactory(Ref ref) => _defaultPoaIdFactory;

/// Wall clock the form samples when stamping a default effective date and
/// the row's `updatedAt`. Overridable so tests pin a fixed time.
@Riverpod(keepAlive: true)
DateTime Function() poaFormClock(Ref ref) => DateTime.now;

/// What the form needs before it can render: the loved-one id a new doc
/// attaches to, and the existing POA document being edited (null on the
/// add path).
@immutable
class PoaFormData {
  const PoaFormData({this.doc, required this.patientId});

  final PowerOfAttorneyDoc? doc;
  final String patientId;
}

/// Async loader for the POA form (TASKS.md Phase 14.24). Resolves the
/// active loved-one id from [storageProvider] and the existing single POA
/// document for that loved one from [powerOfAttorneyDocsProvider].
@riverpod
Future<PoaFormData> poaFormHydration(Ref ref) async {
  final StorageProvider storage = ref.watch(storageProvider);
  final Patient? patient = await storage.getPatient();
  final String patientId = patient?.id ?? _fallbackPatientId;

  final List<PowerOfAttorneyDoc> docs =
      await ref.watch(powerOfAttorneyDocsProvider.future);
  final List<PowerOfAttorneyDoc> mine = patient == null
      ? docs
      : docs
          .where((PowerOfAttorneyDoc d) => d.patientId == patient.id)
          .toList();

  return PoaFormData(
    doc: mine.isEmpty ? null : mine.first,
    patientId: mine.isEmpty ? patientId : mine.first.patientId,
  );
}

/// Add / edit power-of-attorney form (TASKS.md Phase 14.24) at
/// `/medical/cards/poa/edit`.
///
/// Captures the agent name (required), an optional alternate agent, the
/// [PoaScope] (a single-select chip row), and the effective date (a date
/// picker, defaulting to today). Save upserts through the
/// [powerOfAttorneyDocsProvider] notifier — which refreshes the screen's
/// view — and pops; an existing doc also offers Delete. The optional scan
/// pointer is preserved across an edit. Organisational record-keeping —
/// nothing here is legal advice.
class PoaEditForm extends ConsumerStatefulWidget {
  const PoaEditForm({super.key});

  static const Key formKey = Key('poa-form');
  static const Key agentFieldKey = Key('poa-form-agent');
  static const Key alternateFieldKey = Key('poa-form-alternate');
  static const Key dateFieldKey = Key('poa-form-date');
  static const Key saveButtonKey = Key('poa-form-save');
  static const Key deleteButtonKey = Key('poa-form-delete');

  static Key scopeChipKey(PoaScope scope) => Key('poa-form-scope-${scope.name}');

  @override
  ConsumerState<PoaEditForm> createState() => _PoaEditFormState();
}

class _PoaEditFormState extends ConsumerState<PoaEditForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _agent = TextEditingController();
  final TextEditingController _alternate = TextEditingController();

  PoaScope _scope = PoaScope.medical;
  late DateTime _effectiveDate;
  String _patientId = _fallbackPatientId;
  String? _existingId;
  String? _existingScanPath;

  bool _hydrated = false;
  bool _submitting = false;

  bool get _isEdit => _existingId != null;

  @override
  void initState() {
    super.initState();
    _effectiveDate = ref.read(poaFormClockProvider)();
  }

  @override
  void dispose() {
    _agent.dispose();
    _alternate.dispose();
    super.dispose();
  }

  void _hydrate(PoaFormData data) {
    if (_hydrated) return;
    _hydrated = true;
    _patientId = data.patientId;
    final PowerOfAttorneyDoc? doc = data.doc;
    if (doc == null) return;
    _existingId = doc.id;
    _existingScanPath = doc.scanPath;
    _agent.text = doc.agentName;
    _alternate.text = doc.alternateName ?? '';
    _scope = doc.scope;
    _effectiveDate = doc.effectiveDate;
  }

  void _selectScope(PoaScope scope) {
    if (scope == _scope) return;
    setState(() => _scope = scope);
  }

  Future<void> _pickDate() async {
    final DateTime now = ref.read(poaFormClockProvider)();
    final DateTime first = DateTime(now.year - 30);
    final DateTime last = DateTime(now.year + 30);
    final DateTime initial =
        _effectiveDate.isBefore(first) || _effectiveDate.isAfter(last)
            ? now
            : _effectiveDate;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked == null) return;
    setState(() => _effectiveDate = DateTime(
          picked.year,
          picked.month,
          picked.day,
        ));
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    setState(() => _submitting = true);

    final String id = _existingId ?? ref.read(poaFormIdFactoryProvider)();
    final String alternate = _alternate.text.trim();
    final PowerOfAttorneyDoc doc = PowerOfAttorneyDoc(
      id: id,
      patientId: _patientId,
      updatedAt: ref.read(poaFormClockProvider)(),
      agentName: _agent.text.trim(),
      scope: _scope,
      effectiveDate: _effectiveDate,
      alternateName: alternate.isEmpty ? null : alternate,
      scanPath: _existingScanPath,
    );

    final PowerOfAttorneyDocs notifier =
        ref.read(powerOfAttorneyDocsProvider.notifier);
    if (_isEdit) {
      await notifier.updateDoc(doc);
    } else {
      await notifier.add(doc);
    }

    if (!mounted) return;
    _leave();
  }

  Future<void> _delete() async {
    final String? id = _existingId;
    if (id == null || _submitting) return;
    setState(() => _submitting = true);
    await ref.read(powerOfAttorneyDocsProvider.notifier).delete(id);
    if (!mounted) return;
    _leave();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medical/cards/poa');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<PoaFormData> hydration = ref.watch(poaFormHydrationProvider);
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: hydration.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (PoaFormData data) {
            _hydrate(data);
            return Form(
              key: _formKey,
              child: ListView(
                key: PoaEditForm.formKey,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: <Widget>[
                  PathHeader(
                    breadcrumbs: const <PathHeaderCrumb>[
                      PathHeaderCrumb(label: 'Home', route: '/'),
                      PathHeaderCrumb(label: 'Medical', route: '/medical'),
                      PathHeaderCrumb(
                        label: 'Cards & Documents',
                        route: '/medical/cards',
                      ),
                      PathHeaderCrumb(
                        label: 'Power of Attorney',
                        route: '/medical/cards/poa',
                      ),
                      PathHeaderCrumb(label: 'Edit'),
                    ],
                    title: _isEdit
                        ? 'Edit power of attorney'
                        : 'Add power of attorney',
                    backLabel: 'Back to Power of Attorney',
                    leadingIcon: Icons.gavel_outlined,
                  ),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'Agent'),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: PoaEditForm.agentFieldKey,
                    controller: _agent,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      hintText: 'Full name of the person who holds authority',
                    ),
                    validator: (String? v) {
                      if ((v ?? '').trim().isEmpty) {
                        return 'Enter the agent\'s name.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'Alternate (optional)'),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: PoaEditForm.alternateFieldKey,
                    controller: _alternate,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      hintText: 'Successor agent, if any',
                    ),
                  ),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'Scope'),
                  const SizedBox(height: 8),
                  _ScopePicker(selected: _scope, onSelected: _selectScope),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'Effective date'),
                  const SizedBox(height: 8),
                  _DateField(
                    fieldKey: PoaEditForm.dateFieldKey,
                    label: _formatDate(_effectiveDate),
                    onTap: _pickDate,
                  ),
                  const SizedBox(height: 28),
                  Semantics(
                    button: true,
                    label: _isEdit
                        ? 'Save changes to the power of attorney.'
                        : 'Save the power of attorney.',
                    child: ElevatedButton(
                      key: PoaEditForm.saveButtonKey,
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: careblazersColors.cta,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        _submitting
                            ? 'Saving…'
                            : (_isEdit ? 'Save changes' : 'Save'),
                        style:
                            textTheme.labelLarge?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                  if (_isEdit) ...<Widget>[
                    const SizedBox(height: 12),
                    Semantics(
                      button: true,
                      label: 'Delete the power of attorney.',
                      child: OutlinedButton.icon(
                        key: PoaEditForm.deleteButtonKey,
                        onPressed: _submitting ? null : _delete,
                        icon: Icon(
                          Icons.delete_outline,
                          color: careblazersColors.accentDeep,
                        ),
                        label: Text(
                          'Delete',
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

class _ScopePicker extends StatelessWidget {
  const _ScopePicker({required this.selected, required this.onSelected});

  final PoaScope selected;
  final ValueChanged<PoaScope> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (final PoaScope scope in PoaScope.values)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: scope == PoaScope.values.last ? 0 : 8,
              ),
              child: _ScopeOption(
                scope: scope,
                selected: scope == selected,
                onTap: () => onSelected(scope),
              ),
            ),
          ),
      ],
    );
  }
}

class _ScopeOption extends StatelessWidget {
  const _ScopeOption({
    required this.scope,
    required this.selected,
    required this.onTap,
  });

  final PoaScope scope;
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
      label: _scopeLabel(scope),
      child: InkWell(
        key: PoaEditForm.scopeChipKey(scope),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _scopeLabel(scope),
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

class _DateField extends StatelessWidget {
  const _DateField({
    required this.fieldKey,
    required this.label,
    required this.onTap,
  });

  final Key fieldKey;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Effective date, $label. Double-tap to change.',
      child: InkWell(
        key: fieldKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
          decoration: BoxDecoration(
            color: careblazersColors.surfaceWarm,
            border: Border.all(color: careblazersColors.primarySoft),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.calendar_today_outlined,
                size: 20,
                color: careblazersColors.primarySoft,
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                ),
              ),
            ],
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _scopeLabel(PoaScope scope) {
  switch (scope) {
    case PoaScope.medical:
      return 'Medical';
    case PoaScope.financial:
      return 'Financial';
    case PoaScope.general:
      return 'General';
  }
}

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime t) =>
    '${_months[t.month - 1]} ${t.day}, ${t.year}';
