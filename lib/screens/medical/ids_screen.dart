import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

part 'ids_screen.g.dart';

/// Fallback loved-one id used when no [Patient] is on file yet — mirrors
/// the other Cards & Documents forms so a freshly added ID lines up with
/// the demo seed's `maryHenderson` id.
const String _fallbackPatientId = 'demo-patient-mary';

/// Number of days before expiry within which an ID's expires date is
/// flagged coral on the list (TASKS.md Phase 14.24). Past-dated IDs are
/// flagged too.
const int _expirySoonDays = 60;

/// Everything the IDs list renders, bundled so the screen consumes a
/// single [AsyncValue] (TASKS.md Phase 14.24).
@immutable
class IdsView {
  const IdsView({required this.patient, required this.docs});

  final Patient? patient;
  final List<IdentificationDoc> docs;
}

/// Bundles the loved one + their identification documents for [IdsScreen]
/// (TASKS.md Phase 14.24).
///
/// Watches [identificationDocsProvider] (not the repository directly) so
/// an add / edit / delete saved through the notifier refreshes the view
/// without a manual invalidate. Tests override this provider wholesale.
@riverpod
Future<IdsView> idsView(Ref ref) async {
  final StorageProvider storage = ref.watch(storageProvider);
  final Patient? patient = await storage.getPatient();

  final List<IdentificationDoc> docs =
      await ref.watch(identificationDocsProvider.future);
  final List<IdentificationDoc> mine = patient == null
      ? docs
      : docs
          .where((IdentificationDoc d) => d.patientId == patient.id)
          .toList();

  return IdsView(patient: patient, docs: mine);
}

/// One identification document by [id], resolved off the already-loaded
/// [identificationDocsProvider] list so a detail view refreshes after an
/// edit (TASKS.md Phase 14.24). Null when the row was deleted.
@riverpod
Future<IdentificationDoc?> idDetail(Ref ref, String id) async {
  final List<IdentificationDoc> docs =
      await ref.watch(identificationDocsProvider.future);
  for (final IdentificationDoc d in docs) {
    if (d.id == id) return d;
  }
  return null;
}

/// Wall clock used to decide whether an expires date is "soon" (within
/// [_expirySoonDays]) or past. Overridable so tests pin a fixed time and
/// the boundary coloring stays deterministic regardless of host time.
@Riverpod(keepAlive: true)
DateTime Function() idsClock(Ref ref) => DateTime.now;

/// Identification list at `/medical/cards/ids` (TASKS.md Phase 14.24,
/// BUILD_SPEC.md §5.13 / §5.17).
///
/// A [PathHeader] (`Home › Medical › Cards & Documents › Identification`,
/// back to Cards & Documents) sits above the loved one's ID documents.
/// Each row carries a kind chip, the masked id number (`****1234`), and
/// the expires date — rendered coral when the document expires within 60
/// days or has already lapsed. Tapping a row opens the detail at
/// `/medical/cards/ids/:id`; the floating "+" action adds a new ID.
class IdsScreen extends ConsumerWidget {
  const IdsScreen({super.key});

  static const Key listKey = Key('ids-list');
  static const Key emptyStateKey = Key('ids-empty');
  static const Key emptyCtaKey = Key('ids-empty-cta');
  static const Key fabKey = Key('ids-fab');

  /// Stable per-row key derived from the document id. Tests tap by id
  /// rather than by visible label so a copy edit doesn't break them.
  static Key rowKey(String docId) => Key('ids-row-$docId');

  /// Per-row expires text key so the coloring assertion targets a stable
  /// node rather than matching on a formatted date string.
  static Key expiresKey(String docId) => Key('ids-expires-$docId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<IdsView> async = ref.watch(idsViewProvider);
    final DateTime now = ref.watch(idsClockProvider)();

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Medical', route: '/medical'),
                  PathHeaderCrumb(
                    label: 'Cards & Documents',
                    route: '/medical/cards',
                  ),
                  PathHeaderCrumb(label: 'Identification'),
                ],
                title: 'Identification',
                backLabel: 'Back to Cards & Documents',
                leadingIcon: Icons.badge_outlined,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (IdsView view) {
                  if (view.docs.isEmpty) return const _EmptyState();
                  return _IdList(docs: view.docs, now: now);
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: async.maybeWhen(
        data: (IdsView view) {
          if (view.docs.isEmpty) return null;
          return _AddIdFab(
            onPressed: () => context.push('/medical/cards/ids/new'),
          );
        },
        orElse: () => null,
      ),
    );
  }
}

class _IdList extends StatelessWidget {
  const _IdList({required this.docs, required this.now});

  final List<IdentificationDoc> docs;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: IdsScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: <Widget>[
        for (final IdentificationDoc doc in docs) _IdRow(doc: doc, now: now),
      ],
    );
  }
}

class _IdRow extends StatelessWidget {
  const _IdRow({required this.doc, required this.now});

  final IdentificationDoc doc;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final DateTime? expires = doc.expiresOn;
    final bool soon = expires != null && _isExpiringSoon(expires, now);
    final Color expiresColor =
        soon ? careblazersColors.cta : careblazersColors.primarySoft;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: '${_kindLabel(doc.kind)}, ${_maskIdNumber(doc.idNumber)}. '
            '${_expiresSemantic(expires, soon)} Double-tap to open.',
        child: Material(
          color: careblazersColors.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: IdsScreen.rowKey(doc.id),
            borderRadius: BorderRadius.circular(16),
            onTap: () => context.push('/medical/cards/ids/${doc.id}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: careblazersColors.link.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _kindGlyph(doc.kind),
                      size: 22,
                      color: careblazersColors.link,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            _KindChip(kind: doc.kind),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _maskIdNumber(doc.idNumber),
                                style: textTheme.bodyLarge?.copyWith(
                                  color: careblazersColors.text,
                                  fontWeight: FontWeight.w700,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _expiresLabel(expires),
                          key: IdsScreen.expiresKey(doc.id),
                          style: textTheme.bodyMedium?.copyWith(
                            color: expiresColor,
                            fontWeight: soon ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});

  final IdKind kind;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: careblazersColors.link.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _kindLabel(kind),
        style: textTheme.bodyMedium?.copyWith(
          color: careblazersColors.link,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: IdsScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.badge_outlined,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'No IDs on file.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "Keep your loved one's license, Medicare, and insurance cards "
            'here so they are ready for a hospital visit or paperwork.',
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'Add an ID. Open the new identification form.',
            child: ElevatedButton.icon(
              key: IdsScreen.emptyCtaKey,
              onPressed: () => context.push('/medical/cards/ids/new'),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                'Add an ID',
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

class _AddIdFab extends StatelessWidget {
  const _AddIdFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add an ID. Open the new identification form.',
      child: FloatingActionButton.extended(
        key: IdsScreen.fabKey,
        onPressed: onPressed,
        backgroundColor: careblazersColors.cta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Add ID',
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------

/// Identification detail at `/medical/cards/ids/:id` (TASKS.md Phase
/// 14.24). Shows the front + back photo thumbnails (each tappable to a
/// full-screen viewer), the **unmasked** id number, the expires date, and
/// a Share action. The AppBar Edit action pushes the edit form.
class IdDetailScreen extends ConsumerWidget {
  const IdDetailScreen({super.key, required this.docId});

  final String docId;

  static const Key editActionKey = Key('id-detail-edit');
  static const Key scrollKey = Key('id-detail-scroll');
  static const Key idNumberKey = Key('id-detail-number');
  static const Key shareButtonKey = Key('id-detail-share');
  static const Key missingKey = Key('id-detail-missing');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<IdentificationDoc?> async =
        ref.watch(idDetailProvider(docId));

    return Scaffold(
      backgroundColor: careblazersColors.background,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: careblazersColors.background,
        elevation: 0,
        actions: <Widget>[
          Semantics(
            button: true,
            label: 'Edit this ID.',
            child: IconButton(
              key: editActionKey,
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit ID',
              color: careblazersColors.primary,
              onPressed: () => context.push('/medical/cards/ids/$docId/edit'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (IdentificationDoc? doc) {
            if (doc == null) return const _MissingView();
            return _DetailBody(doc: doc);
          },
        ),
      ),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.doc});

  final IdentificationDoc doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      key: IdDetailScreen.scrollKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                label: 'Identification',
                route: '/medical/cards/ids',
              ),
              PathHeaderCrumb(label: 'Detail'),
            ],
            title: _kindLabel(doc.kind),
            backLabel: 'Back to Identification',
            leadingIcon: Icons.badge_outlined,
          ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              DocumentScanThumbnail(path: doc.photoFrontPath, label: 'Front'),
              const SizedBox(width: 16),
              DocumentScanThumbnail(path: doc.photoBackPath, label: 'Back'),
            ],
          ),
          const SizedBox(height: 24),
          const _DetailLabel(label: 'ID number'),
          const SizedBox(height: 4),
          Text(
            doc.idNumber,
            key: IdDetailScreen.idNumberKey,
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          const _DetailLabel(label: 'Expires'),
          const SizedBox(height: 4),
          Text(
            _expiresLabel(doc.expiresOn),
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          ),
          const SizedBox(height: 28),
          Semantics(
            button: true,
            label: 'Share this ID\'s details.',
            child: OutlinedButton.icon(
              key: IdDetailScreen.shareButtonKey,
              onPressed: () => ref
                  .read(sharerProvider)
                  .share(_shareText(doc), subject: _subject(doc)),
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
}

class _DetailLabel extends StatelessWidget {
  const _DetailLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      label,
      style: textTheme.bodyMedium?.copyWith(
        color: careblazersColors.primarySoft,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _MissingView extends StatelessWidget {
  const _MissingView();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: IdDetailScreen.missingKey,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          'This ID is no longer on file.',
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

String _subject(IdentificationDoc doc) => _kindLabel(doc.kind);

String _shareText(IdentificationDoc doc) {
  final StringBuffer b = StringBuffer()
    ..writeln(_kindLabel(doc.kind))
    ..writeln('ID number: ${doc.idNumber}');
  if (doc.expiresOn != null) {
    b.writeln('Expires: ${_formatDate(doc.expiresOn!)}');
  }
  return b.toString().trimRight();
}

// ---------------------------------------------------------------------------
// Edit form
// ---------------------------------------------------------------------------

/// Mint a new id for the ID row the form inserts. Overridable for tests +
/// the demo tour so id sequences are deterministic.
typedef IdDocFactory = String Function();

String _defaultIdDocFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'id-$ms-$rand';
}

/// ID factory the form uses. Tests override this with a monotonic counter.
@Riverpod(keepAlive: true)
IdDocFactory idFormIdFactory(Ref ref) => _defaultIdDocFactory;

/// Wall clock the form samples for the row's `updatedAt` + the expiry
/// picker's anchor. Overridable so tests pin a fixed time.
@Riverpod(keepAlive: true)
DateTime Function() idFormClock(Ref ref) => DateTime.now;

/// What the form needs before it can render: the loved-one id a new doc
/// attaches to, plus the document being edited (null on the add path).
@immutable
class IdFormData {
  const IdFormData({this.doc, required this.patientId});

  final IdentificationDoc? doc;
  final String patientId;
}

/// Async loader for the ID form (TASKS.md Phase 14.24). Resolves the
/// active loved-one id from [storageProvider] and — on the edit path —
/// the existing document off [identificationDocsProvider].
@riverpod
Future<IdFormData> idFormHydration(Ref ref, String? docId) async {
  final StorageProvider storage = ref.watch(storageProvider);
  final Patient? patient = await storage.getPatient();
  final String patientId = patient?.id ?? _fallbackPatientId;

  if (docId == null) {
    return IdFormData(patientId: patientId);
  }
  final List<IdentificationDoc> docs =
      await ref.watch(identificationDocsProvider.future);
  IdentificationDoc? found;
  for (final IdentificationDoc d in docs) {
    if (d.id == docId) {
      found = d;
      break;
    }
  }
  return IdFormData(
    doc: found,
    patientId: found?.patientId ?? patientId,
  );
}

/// Add / edit identification form (TASKS.md Phase 14.24) at
/// `/medical/cards/ids/new` and `/medical/cards/ids/:id/edit`.
///
/// Captures the [IdKind] (a single-select chip row), the id number
/// (required), and an optional expires date. Save upserts through the
/// [identificationDocsProvider] notifier — which refreshes the list — and
/// pops; an existing doc also offers Delete. The optional front/back
/// photo pointers are preserved across an edit. The app never validates
/// an ID; this is reference data the caregiver keeps at hand.
class IdEditForm extends ConsumerStatefulWidget {
  const IdEditForm({super.key, this.docId});

  /// Non-null on the edit path; null on the add path.
  final String? docId;

  bool get isEdit => docId != null;

  static const Key formKey = Key('id-form');
  static const Key idNumberFieldKey = Key('id-form-number');
  static const Key expiryFieldKey = Key('id-form-expiry');
  static const Key expiryClearKey = Key('id-form-expiry-clear');
  static const Key saveButtonKey = Key('id-form-save');
  static const Key deleteButtonKey = Key('id-form-delete');

  static Key kindChipKey(IdKind kind) => Key('id-form-kind-${kind.name}');

  @override
  ConsumerState<IdEditForm> createState() => _IdEditFormState();
}

class _IdEditFormState extends ConsumerState<IdEditForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _idNumber = TextEditingController();

  IdKind _kind = IdKind.driverLicense;
  DateTime? _expiresOn;
  String _patientId = _fallbackPatientId;
  String? _frontPath;
  String? _backPath;

  bool _hydrated = false;
  bool _submitting = false;

  @override
  void dispose() {
    _idNumber.dispose();
    super.dispose();
  }

  void _hydrate(IdFormData data) {
    if (_hydrated) return;
    _hydrated = true;
    _patientId = data.patientId;
    final IdentificationDoc? doc = data.doc;
    if (doc == null) return;
    _kind = doc.kind;
    _idNumber.text = doc.idNumber;
    _expiresOn = doc.expiresOn;
    _frontPath = doc.photoFrontPath;
    _backPath = doc.photoBackPath;
  }

  void _selectKind(IdKind kind) {
    if (kind == _kind) return;
    setState(() => _kind = kind);
  }

  Future<void> _pickExpiry() async {
    final DateTime now = ref.read(idFormClockProvider)();
    final DateTime first = DateTime(now.year - 30);
    final DateTime last = DateTime(now.year + 30);
    final DateTime anchor = _expiresOn ?? now;
    final DateTime initial =
        anchor.isBefore(first) || anchor.isAfter(last) ? now : anchor;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked == null) return;
    setState(() =>
        _expiresOn = DateTime(picked.year, picked.month, picked.day));
  }

  void _clearExpiry() => setState(() => _expiresOn = null);

  Future<void> _submit() async {
    if (_submitting) return;
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    setState(() => _submitting = true);

    final String id = widget.docId ?? ref.read(idFormIdFactoryProvider)();
    final IdentificationDoc doc = IdentificationDoc(
      id: id,
      patientId: _patientId,
      updatedAt: ref.read(idFormClockProvider)(),
      kind: _kind,
      idNumber: _idNumber.text.trim(),
      expiresOn: _expiresOn,
      photoFrontPath: _frontPath,
      photoBackPath: _backPath,
    );

    final IdentificationDocs notifier =
        ref.read(identificationDocsProvider.notifier);
    if (widget.isEdit) {
      await notifier.updateDoc(doc);
    } else {
      await notifier.add(doc);
    }

    if (!mounted) return;
    _leave();
  }

  Future<void> _delete() async {
    final String? id = widget.docId;
    if (id == null || _submitting) return;
    setState(() => _submitting = true);
    await ref.read(identificationDocsProvider.notifier).delete(id);
    if (!mounted) return;
    _leave();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/medical/cards/ids');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<IdFormData> hydration =
        ref.watch(idFormHydrationProvider(widget.docId));
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: hydration.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
          data: (IdFormData data) {
            _hydrate(data);
            return Form(
              key: _formKey,
              child: ListView(
                key: IdEditForm.formKey,
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
                        label: 'Identification',
                        route: '/medical/cards/ids',
                      ),
                      PathHeaderCrumb(label: 'Edit'),
                    ],
                    title: widget.isEdit ? 'Edit ID' : 'New ID',
                    backLabel: 'Back to Identification',
                    leadingIcon: Icons.badge_outlined,
                  ),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'Type'),
                  const SizedBox(height: 8),
                  _KindPicker(selected: _kind, onSelected: _selectKind),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'ID number'),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: IdEditForm.idNumberFieldKey,
                    controller: _idNumber,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: <TextInputFormatter>[
                      LengthLimitingTextInputFormatter(40),
                    ],
                    decoration: const InputDecoration(
                      hintText: 'Number on the card',
                    ),
                    validator: (String? v) {
                      if ((v ?? '').trim().isEmpty) {
                        return 'Enter the ID number.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  const _FieldLabel(label: 'Expires (optional)'),
                  const SizedBox(height: 8),
                  _ExpiryField(
                    label: _expiresOn == null
                        ? 'No expiry date'
                        : _formatDate(_expiresOn!),
                    hasValue: _expiresOn != null,
                    onTap: _pickExpiry,
                    onClear: _clearExpiry,
                  ),
                  const SizedBox(height: 28),
                  Semantics(
                    button: true,
                    label: widget.isEdit
                        ? 'Save changes to this ID.'
                        : 'Save this ID.',
                    child: ElevatedButton(
                      key: IdEditForm.saveButtonKey,
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: careblazersColors.cta,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        _submitting
                            ? 'Saving…'
                            : (widget.isEdit ? 'Save changes' : 'Save ID'),
                        style:
                            textTheme.labelLarge?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                  if (widget.isEdit) ...<Widget>[
                    const SizedBox(height: 12),
                    Semantics(
                      button: true,
                      label: 'Delete this ID.',
                      child: OutlinedButton.icon(
                        key: IdEditForm.deleteButtonKey,
                        onPressed: _submitting ? null : _delete,
                        icon: Icon(
                          Icons.delete_outline,
                          color: careblazersColors.accentDeep,
                        ),
                        label: Text(
                          'Delete ID',
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

class _KindPicker extends StatelessWidget {
  const _KindPicker({required this.selected, required this.onSelected});

  final IdKind selected;
  final ValueChanged<IdKind> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final IdKind kind in IdKind.values)
          _KindOption(
            kind: kind,
            selected: kind == selected,
            onTap: () => onSelected(kind),
          ),
      ],
    );
  }
}

class _KindOption extends StatelessWidget {
  const _KindOption({
    required this.kind,
    required this.selected,
    required this.onTap,
  });

  final IdKind kind;
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
      label: _kindLabel(kind),
      child: InkWell(
        key: IdEditForm.kindChipKey(kind),
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
            _kindLabel(kind),
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

class _ExpiryField extends StatelessWidget {
  const _ExpiryField({
    required this.label,
    required this.hasValue,
    required this.onTap,
    required this.onClear,
  });

  final String label;
  final bool hasValue;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            button: true,
            label: 'Expiry date, $label. Double-tap to change.',
            child: InkWell(
              key: IdEditForm.expiryFieldKey,
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
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
          ),
        ),
        if (hasValue)
          Semantics(
            button: true,
            label: 'Clear the expiry date.',
            child: IconButton(
              key: IdEditForm.expiryClearKey,
              icon: Icon(Icons.clear, color: careblazersColors.primarySoft),
              tooltip: 'Clear expiry date',
              onPressed: onClear,
            ),
          ),
      ],
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
          "We couldn't load the IDs.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Mask all but the last four characters of [idNumber] as `****1234`.
/// Numbers of four or fewer characters keep the `****` prefix so nothing
/// leaks; an empty number renders as bare `****`.
String _maskIdNumber(String idNumber) {
  final String trimmed = idNumber.trim();
  if (trimmed.length <= 4) return '****$trimmed';
  return '****${trimmed.substring(trimmed.length - 4)}';
}

/// True when [expiresOn] is within [_expirySoonDays] of [now] or already
/// past, compared by calendar day so a same-day boundary doesn't flip on
/// the time of day. At exactly 60 days out the document is still "soon".
bool _isExpiringSoon(DateTime expiresOn, DateTime now) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime exp = DateTime(
    expiresOn.toLocal().year,
    expiresOn.toLocal().month,
    expiresOn.toLocal().day,
  );
  final int daysUntil = exp.difference(today).inDays;
  return daysUntil <= _expirySoonDays;
}

String _expiresLabel(DateTime? expiresOn) {
  if (expiresOn == null) return 'No expiry date';
  return 'Expires ${_formatDate(expiresOn)}';
}

String _expiresSemantic(DateTime? expiresOn, bool soon) {
  if (expiresOn == null) return 'No expiry date.';
  final String base = 'Expires ${_formatDate(expiresOn)}.';
  return soon ? '$base Expiring soon.' : base;
}

String _kindLabel(IdKind kind) {
  switch (kind) {
    case IdKind.driverLicense:
      return 'Driver License';
    case IdKind.stateId:
      return 'State ID';
    case IdKind.passport:
      return 'Passport';
    case IdKind.medicare:
      return 'Medicare';
    case IdKind.insuranceCard:
      return 'Insurance';
  }
}

IconData _kindGlyph(IdKind kind) {
  switch (kind) {
    case IdKind.driverLicense:
      return Icons.directions_car_outlined;
    case IdKind.stateId:
      return Icons.badge_outlined;
    case IdKind.passport:
      return Icons.book_outlined;
    case IdKind.medicare:
      return Icons.local_hospital_outlined;
    case IdKind.insuranceCard:
      return Icons.shield_outlined;
  }
}

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime t) =>
    '${_months[t.month - 1]} ${t.day}, ${t.year}';
