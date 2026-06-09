import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/document.dart';
import '../../models/medication.dart';
import '../../models/patient.dart';
import '../../providers/documents_provider.dart';
import '../../providers/link_launcher_provider.dart';
import '../../providers/storage_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';
import '../../services/medication_repository.dart';

part 'emergency_card_screen.g.dart';

/// Everything the Emergency Card screen renders, gathered into one bundle
/// so the screen consumes a single [AsyncValue] (TASKS.md Phase 14.23).
///
/// The card blends three sources: the loved one's identity (the singleton
/// [Patient] via [StorageProvider.getPatient]), the structured handoff
/// data ([EmergencyCard] via [EmergencyCards]), and a **read-only mirror**
/// of the live medication tracker ([medicationListProvider]). The ICE card
/// shows the medications the caregiver is actually tracking rather than a
/// second hand-typed list, so it can never drift out of sync.
@immutable
class EmergencyCardView {
  const EmergencyCardView({
    required this.patient,
    required this.card,
    required this.medications,
  });

  /// The loved one's profile, or null before one is created.
  final Patient? patient;

  /// The structured emergency card for [patient], or null if none on file.
  final EmergencyCard? card;

  /// Read-only mirror of the medication tracker (TASKS.md Phase 14.23).
  /// Flat list of live medications — the ICE view doesn't need the
  /// window grouping; first responders want "what is she on" not
  /// "what does she take at 8am".
  final List<Medication> medications;
}

/// Bundles the loved one, their emergency card, and the live medication
/// mirror for [EmergencyCardScreen] (TASKS.md Phase 14.23).
///
/// Watches [emergencyCardsProvider] (not the repository directly) so an
/// edit saved through the notifier refreshes the view without a manual
/// invalidate. Tests override this provider wholesale with a fixed
/// [EmergencyCardView] so the screen renders deterministically without
/// standing up three drift backends.
@riverpod
Future<EmergencyCardView> emergencyCardView(Ref ref) async {
  final StorageProvider storage = ref.watch(storageProvider);
  final Patient? patient = await storage.getPatient();

  final List<EmergencyCard> cards =
      await ref.watch(emergencyCardsProvider.future);
  final List<EmergencyCard> mine = patient == null
      ? const <EmergencyCard>[]
      : cards.where((EmergencyCard c) => c.patientId == patient.id).toList();

  // Live mirror of the medication tracker — flat list, alphabetical.
  final MedicationRepository medRepo =
      ref.watch(medicationRepositoryBackendProvider);
  final List<Medication> meds = await medRepo.listMedications();

  return EmergencyCardView(
    patient: patient,
    card: mine.isEmpty ? null : mine.first,
    medications: meds,
  );
}

/// Emergency Card screen at `/medical/cards/emergency` (TASKS.md Phase
/// 14.23, BUILD_SPEC.md §5.17). Replaces the old inline-editable
/// CrisisCardScreen.
///
/// A read-only "show to first responders" card under Medical. The
/// [PathHeader] carries the `Home › Medical` trail (back to Medical);
/// the AppBar carries a single Edit action that pushes
/// `/medical/cards/emergency/edit`. (Was previously nested under a
/// "Cards & Documents" sub-hub alongside POA + IDs; that sub-hub was
/// removed and Emergency Card promoted to a top-level Medical tile.)
///
/// Body sections, each a labeled bordered card: Patient identity,
/// Conditions, Medications (the live tracker mirror), Allergies, Emergency
/// Contacts (each with a one-tap `tel:` call button), Insurance, and Donor
/// status. Empty fields read "None on file" rather than collapsing, so a
/// paramedic can see at a glance that a section was left blank rather than
/// missed.
///
/// Nothing here diagnoses or prescribes — it's reference data the caregiver
/// entered for a handoff.
class EmergencyCardScreen extends ConsumerWidget {
  const EmergencyCardScreen({super.key});

  static const Key editActionKey = Key('emergency-card-edit');
  static const Key scrollKey = Key('emergency-card-scroll');
  static const Key headlineKey = Key('emergency-card-headline');
  static const Key emptyPlaceholderKey = Key('emergency-card-empty');
  static const Key patientSectionKey = Key('emergency-card-patient');
  static const Key conditionsSectionKey = Key('emergency-card-conditions');
  static const Key medicationsSectionKey = Key('emergency-card-medications');
  static const Key allergiesSectionKey = Key('emergency-card-allergies');
  static const Key contactsSectionKey = Key('emergency-card-contacts');
  static const Key insuranceSectionKey = Key('emergency-card-insurance');
  static const Key donorSectionKey = Key('emergency-card-donor');

  /// Per-contact call button — tests tap by index and assert the launched
  /// `tel:` URI without firing the platform plugin.
  static Key callButtonKey(int index) => Key('emergency-card-call-$index');

  static const String editRoute = '/medical/cards/emergency/edit';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<EmergencyCardView> async =
        ref.watch(emergencyCardViewProvider);

    return Scaffold(
      backgroundColor: context.cb.background,
      // No AppBar: the Edit action lives in the PathHeader's trailing slot
      // so an empty bar doesn't push the whole card down. The PathHeader
      // sits OUTSIDE the `.when()` so the breadcrumb back affordance is
      // present on EVERY branch — including the loading and error states
      // (alpha bug fb_1780932762335231: those branches were swipe-only
      // with no header).
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PathHeader(
                breadcrumbs: const <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(label: 'Emergency Card'),
                ],
                title: 'Emergency Card',
                leadingIcon: Icons.emergency_outlined,
                // Edit lives here (not an AppBar) so it sits beside the
                // title instead of adding a bar that pushes the card down.
                trailing: Semantics(
                  button: true,
                  label: 'Edit the emergency card.',
                  child: IconButton(
                    key: EmergencyCardScreen.editActionKey,
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit emergency card',
                    color: context.cb.primary,
                    onPressed: () =>
                        context.push(EmergencyCardScreen.editRoute),
                  ),
                ),
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (EmergencyCardView view) => _Body(view: view),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.view});

  final EmergencyCardView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Patient? patient = view.patient;
    final EmergencyCard? card = view.card;

    return SingleChildScrollView(
      key: EmergencyCardScreen.scrollKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _IceHeadline(),
          const SizedBox(height: 16),
          if (patient == null)
            const _EmptyPlaceholder()
          else ...<Widget>[
            _SectionCard(
              sectionKey: EmergencyCardScreen.patientSectionKey,
              label: 'Patient',
              child: _PatientBlock(patient: patient),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              sectionKey: EmergencyCardScreen.conditionsSectionKey,
              label: 'Conditions',
              child: _ChipList(
                items: card?.conditions ?? const <String>[],
                emptyLabel: 'None on file',
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              sectionKey: EmergencyCardScreen.medicationsSectionKey,
              label: 'Medications',
              child: _MedicationMirror(items: view.medications),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              sectionKey: EmergencyCardScreen.allergiesSectionKey,
              label: 'Allergies',
              child: _ChipList(
                items: card?.allergies ?? const <String>[],
                emptyLabel: 'None on file',
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              sectionKey: EmergencyCardScreen.contactsSectionKey,
              label: 'Emergency Contacts',
              child: _ContactList(
                contacts: card?.emergencyContacts ??
                    const <EmergencyContact>[],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              sectionKey: EmergencyCardScreen.insuranceSectionKey,
              label: 'Insurance',
              child: _InsuranceBlock(insurance: card?.insurance),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              sectionKey: EmergencyCardScreen.donorSectionKey,
              label: 'Organ Donor',
              child: _DonorBlock(
                status: card?.donorStatus ?? DonorStatus.unknown,
              ),
            ),
            if (card != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                'Updated ${_formatDate(card.updatedAt)}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.cb.primarySoft,
                    ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ICE headline
// ---------------------------------------------------------------------------

class _IceHeadline extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      'ICE CARD — Show to First Responders',
      key: EmergencyCardScreen.headlineKey,
      style: textTheme.headlineMedium?.copyWith(
        color: context.cb.cta,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty placeholder (no loved one's profile yet)
// ---------------------------------------------------------------------------

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: EmergencyCardScreen.emptyPlaceholderKey,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.emergency_outlined,
            size: 56,
            color: context.cb.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            "Add your loved one's profile to build the emergency card.",
            style: textTheme.headlineMedium?.copyWith(
              color: context.cb.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Tap edit to record the conditions, allergies, contacts, and '
            'insurance a first responder needs.',
            style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section card — labeled, bordered container
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.sectionKey,
    required this.label,
    required this.child,
  });

  final Key sectionKey;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: sectionKey,
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.cb.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: context.cb.primary.withValues(alpha: 0.12),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: textTheme.titleLarge?.copyWith(
              color: context.cb.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Patient identity block
// ---------------------------------------------------------------------------

class _PatientBlock extends StatelessWidget {
  const _PatientBlock({required this.patient});

  final Patient patient;

  // TODO(decision): the Patient model (lib/models/patient.dart) carries
  // `age` + `diagnosedAt` but no date-of-birth or photo path. We render the
  // identity slot with an initials avatar (the "photo thumbnail") and the
  // age line until the Patient model gains a `dateOfBirth` / `photoPath`.
  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _InitialsAvatar(name: patient.name),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                patient.name,
                style: textTheme.bodyLarge?.copyWith(
                  color: context.cb.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Age ${patient.age}',
                style: textTheme.bodyMedium?.copyWith(
                  color: context.cb.primarySoft,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InitialsAvatar extends StatelessWidget {
  const _InitialsAvatar({required this.name});

  final String name;

  String get _initials {
    final List<String> parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((String p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      width: 52,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.cb.primary.withValues(alpha: 0.10),
        shape: BoxShape.circle,
      ),
      child: Text(
        _initials,
        style: textTheme.titleLarge?.copyWith(
          color: context.cb.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chip list (conditions, allergies)
// ---------------------------------------------------------------------------

class _ChipList extends StatelessWidget {
  const _ChipList({required this.items, required this.emptyLabel});

  final List<String> items;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return _EmptyLine(label: emptyLabel);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final String item in items) _Chip(label: item),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: context.cb.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: textTheme.bodyMedium?.copyWith(
          color: context.cb.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Medication mirror (read-only, from the medication tracker)
// ---------------------------------------------------------------------------

class _MedicationMirror extends StatelessWidget {
  const _MedicationMirror({required this.items});

  final List<Medication> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _EmptyLine(label: 'None on file');
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final Medication item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: item.name,
                    style: textTheme.bodyLarge?.copyWith(
                      color: context.cb.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text: '  ${item.dosage}',
                    style: textTheme.bodyMedium?.copyWith(
                      color: context.cb.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Emergency contacts (each row carries a tel: call button)
// ---------------------------------------------------------------------------

class _ContactList extends ConsumerWidget {
  const _ContactList({required this.contacts});

  final List<EmergencyContact> contacts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (contacts.isEmpty) return const _EmptyLine(label: 'None on file');
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < contacts.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == contacts.length - 1 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${contacts[i].name} — ${contacts[i].relation}',
                        style: textTheme.bodyLarge?.copyWith(
                          color: context.cb.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        contacts[i].phone,
                        style: textTheme.bodyMedium?.copyWith(
                          color: context.cb.text,
                        ),
                      ),
                    ],
                  ),
                ),
                Semantics(
                  button: true,
                  label: 'Call ${contacts[i].name}.',
                  child: IconButton(
                    key: EmergencyCardScreen.callButtonKey(i),
                    icon: const Icon(Icons.call),
                    color: context.cb.cta,
                    tooltip: 'Call ${contacts[i].name}',
                    onPressed: () => ref
                        .read(linkLauncherProvider)
                        .launch(_telUri(contacts[i].phone)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Build a dialable `tel:` URI from a free-text phone number, stripping
/// the formatting (spaces, parens, dashes) the caregiver typed but keeping
/// a leading `+` for international numbers.
Uri _telUri(String phone) {
  final String digits =
      phone.replaceAll(RegExp(r'[^0-9+]'), '').replaceAll(RegExp(r'(?!^)\+'), '');
  return Uri(scheme: 'tel', path: digits);
}

// ---------------------------------------------------------------------------
// Insurance block
// ---------------------------------------------------------------------------

class _InsuranceBlock extends StatelessWidget {
  const _InsuranceBlock({required this.insurance});

  final Insurance? insurance;

  @override
  Widget build(BuildContext context) {
    final Insurance? ins = insurance;
    if (ins == null) return const _EmptyLine(label: 'Not on file');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _LabeledValue(label: 'Carrier', value: ins.carrier),
        _LabeledValue(label: 'Policy', value: ins.policyNumber),
        _LabeledValue(label: 'Group', value: ins.groupNumber),
      ],
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: context.cb.primarySoft,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: textTheme.bodyMedium?.copyWith(
                color: context.cb.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Donor status block
// ---------------------------------------------------------------------------

class _DonorBlock extends StatelessWidget {
  const _DonorBlock({required this.status});

  final DonorStatus status;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      _donorLabel(status),
      style: textTheme.bodyLarge?.copyWith(
        color: context.cb.text,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

String _donorLabel(DonorStatus status) {
  switch (status) {
    case DonorStatus.donor:
      return 'Registered organ donor';
    case DonorStatus.notDonor:
      return 'Not an organ donor';
    case DonorStatus.unknown:
      return 'Unknown';
  }
}

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      label,
      style: textTheme.bodyMedium?.copyWith(
        color: context.cb.primarySoft,
        fontStyle: FontStyle.italic,
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
          "We couldn't load the emergency card.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime t) => '${_months[t.month - 1]} ${t.day}, ${t.year}';
