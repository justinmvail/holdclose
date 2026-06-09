import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/document.dart';
import '../../providers/documents_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';
import 'emergency_card_screen.dart'
    show EmergencyCardView, emergencyCardViewProvider;

/// Edit form for the loved one's Emergency Card. Loads the existing card
/// (if any) via [emergencyCardViewProvider], lets the caregiver edit the
/// first-responder fields, and persists through
/// `emergencyCardsProvider.notifier.updateCard`. Reached from the card's
/// Edit action at `/medical/cards/emergency/edit`.
class EmergencyCardEditScreen extends ConsumerWidget {
  const EmergencyCardEditScreen({super.key});

  static const Key bodyKey = Key('emergency-card-edit-body');
  static const Key conditionsFieldKey = Key('emergency-card-edit-conditions');
  static const Key medicationsFieldKey = Key('emergency-card-edit-medications');
  static const Key allergiesFieldKey = Key('emergency-card-edit-allergies');
  static const Key addContactKey = Key('emergency-card-edit-add-contact');
  static const Key saveButtonKey = Key('emergency-card-edit-save');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<EmergencyCardView> async =
        ref.watch(emergencyCardViewProvider);
    return Scaffold(
      backgroundColor: context.cb.background,
      // The PathHeader sits OUTSIDE the `.when()` so the breadcrumb back
      // affordance is present on EVERY branch — including the loading and
      // error states (alpha bug fb_1780932762335231: those branches were
      // swipe-only with no header).
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care', route: '/medical'),
                  PathHeaderCrumb(
                    label: 'Emergency Card',
                    route: '/medical/cards/emergency',
                  ),
                  PathHeaderCrumb(label: 'Edit'),
                ],
                title: 'Edit Emergency Card',
                leadingIcon: Icons.edit_outlined,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text("We couldn't load the emergency card.",
                      style: Theme.of(context).textTheme.bodyLarge),
                ),
                data: (EmergencyCardView view) =>
                    _EmergencyCardForm(view: view),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmergencyCardForm extends ConsumerStatefulWidget {
  const _EmergencyCardForm({required this.view});

  final EmergencyCardView view;

  @override
  ConsumerState<_EmergencyCardForm> createState() => _EmergencyCardFormState();
}

class _EmergencyCardFormState extends ConsumerState<_EmergencyCardForm> {
  late final TextEditingController _conditions;
  late final TextEditingController _medications;
  late final TextEditingController _allergies;
  late final TextEditingController _carrier;
  late final TextEditingController _policy;
  late final TextEditingController _group;
  late final List<_ContactCtrls> _contacts;
  late DonorStatus _donor;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final EmergencyCard? card = widget.view.card;
    _conditions =
        TextEditingController(text: (card?.conditions ?? <String>[]).join('\n'));
    _medications = TextEditingController(
        text: (card?.medications ?? <String>[]).join('\n'));
    _allergies =
        TextEditingController(text: (card?.allergies ?? <String>[]).join('\n'));
    final Insurance? ins = card?.insurance;
    _carrier = TextEditingController(text: ins?.carrier ?? '');
    _policy = TextEditingController(text: ins?.policyNumber ?? '');
    _group = TextEditingController(text: ins?.groupNumber ?? '');
    _contacts = (card?.emergencyContacts ?? <EmergencyContact>[])
        .map(_ContactCtrls.from)
        .toList();
    _donor = card?.donorStatus ?? DonorStatus.unknown;
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _conditions,
      _medications,
      _allergies,
      _carrier,
      _policy,
      _group,
    ]) {
      c.dispose();
    }
    for (final _ContactCtrls c in _contacts) {
      c.dispose();
    }
    super.dispose();
  }

  /// Split a multi-line field into trimmed, non-empty entries — the
  /// caregiver types one condition / medication / allergy per line.
  List<String> _lines(TextEditingController c) => c.text
      .split('\n')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  Future<void> _save() async {
    final patientId = widget.view.patient?.id;
    if (patientId == null) return;
    setState(() => _saving = true);
    final EmergencyCard? existing = widget.view.card;
    final EmergencyCard card = EmergencyCard(
      id: existing?.id ?? 'emergency-card-$patientId',
      patientId: patientId,
      updatedAt: DateTime.now(),
      conditions: _lines(_conditions),
      medications: _lines(_medications),
      allergies: _lines(_allergies),
      // Drop blank rows the caregiver added but never filled in.
      emergencyContacts: _contacts
          .map((_ContactCtrls c) => c.toContact())
          .where((EmergencyContact c) =>
              c.name.isNotEmpty || c.phone.isNotEmpty)
          .toList(),
      insurance: Insurance(
        carrier: _carrier.text.trim(),
        policyNumber: _policy.text.trim(),
        groupNumber: _group.text.trim(),
      ),
      donorStatus: _donor,
      attachmentPath: existing?.attachmentPath,
    );
    await ref.read(emergencyCardsProvider.notifier).updateCard(card);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool hasPatient = widget.view.patient != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        key: EmergencyCardEditScreen.bodyKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: 8),
          if (!hasPatient)
            Text(
              'Add a loved one before filling out the emergency card.',
              style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
            )
          else ...<Widget>[
            _MultilineField(
              fieldKey: EmergencyCardEditScreen.conditionsFieldKey,
              label: 'Medical conditions',
              hint: 'One per line — e.g. Alzheimer\'s, Type 2 diabetes',
              controller: _conditions,
            ),
            const SizedBox(height: 20),
            _MultilineField(
              fieldKey: EmergencyCardEditScreen.medicationsFieldKey,
              label: 'Medications',
              hint: 'One per line — e.g. Donepezil 10 mg, Metformin 500 mg',
              controller: _medications,
            ),
            const SizedBox(height: 20),
            _MultilineField(
              fieldKey: EmergencyCardEditScreen.allergiesFieldKey,
              label: 'Allergies',
              hint: 'One per line — e.g. Penicillin, Latex',
              controller: _allergies,
            ),
            const SizedBox(height: 28),
            _SectionLabel('Emergency contacts', textTheme: textTheme),
            const SizedBox(height: 8),
            for (int i = 0; i < _contacts.length; i++) ...<Widget>[
              _ContactRow(
                ctrls: _contacts[i],
                onRemove: () => setState(() {
                  _contacts.removeAt(i).dispose();
                }),
              ),
              const SizedBox(height: 12),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: EmergencyCardEditScreen.addContactKey,
                onPressed: () =>
                    setState(() => _contacts.add(_ContactCtrls.empty())),
                icon: const Icon(Icons.add),
                label: const Text('Add contact'),
                style: TextButton.styleFrom(
                  foregroundColor: context.cb.link,
                ),
              ),
            ),
            const SizedBox(height: 24),
            _SectionLabel('Insurance', textTheme: textTheme),
            const SizedBox(height: 8),
            _TextField(label: 'Carrier', controller: _carrier),
            const SizedBox(height: 12),
            _TextField(label: 'Policy number', controller: _policy),
            const SizedBox(height: 12),
            _TextField(label: 'Group number', controller: _group),
            const SizedBox(height: 28),
            _SectionLabel('Organ donor', textTheme: textTheme),
            const SizedBox(height: 8),
            _DonorPicker(
              value: _donor,
              onChanged: (DonorStatus s) => setState(() => _donor = s),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              key: EmergencyCardEditScreen.saveButtonKey,
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.cb.cta,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
              child: Text(
                _saving ? 'Saving…' : 'Save emergency card',
                style: textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Per-contact set of controllers (name / relation / phone).
class _ContactCtrls {
  _ContactCtrls(this.name, this.relation, this.phone);

  factory _ContactCtrls.from(EmergencyContact c) => _ContactCtrls(
        TextEditingController(text: c.name),
        TextEditingController(text: c.relation),
        TextEditingController(text: c.phone),
      );

  factory _ContactCtrls.empty() => _ContactCtrls(
        TextEditingController(),
        TextEditingController(),
        TextEditingController(),
      );

  final TextEditingController name;
  final TextEditingController relation;
  final TextEditingController phone;

  EmergencyContact toContact() => EmergencyContact(
        name: name.text.trim(),
        relation: relation.text.trim(),
        phone: phone.text.trim(),
      );

  void dispose() {
    name.dispose();
    relation.dispose();
    phone.dispose();
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.textTheme});

  final String text;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: textTheme.titleMedium?.copyWith(
          color: context.cb.primary,
          fontWeight: FontWeight.w700,
        ),
      );
}

class _MultilineField extends StatelessWidget {
  const _MultilineField({
    required this.fieldKey,
    required this.label,
    required this.hint,
    required this.controller,
  });

  final Key fieldKey;
  final String label;
  final String hint;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionLabel(label, textTheme: textTheme),
        const SizedBox(height: 6),
        TextField(
          key: fieldKey,
          controller: controller,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(hintText: hint),
        ),
      ],
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({required this.label, required this.controller});

  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
      );
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.ctrls, required this.onRemove});

  final _ContactCtrls ctrls;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.cb.surfaceWarm,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: ctrls.name,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove contact',
                  color: context.cb.primarySoft,
                  onPressed: onRemove,
                ),
              ],
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: ctrls.relation,
                    decoration: const InputDecoration(labelText: 'Relation'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: ctrls.phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DonorPicker extends StatelessWidget {
  const _DonorPicker({required this.value, required this.onChanged});

  final DonorStatus value;
  final ValueChanged<DonorStatus> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DonorStatus>(
      segments: const <ButtonSegment<DonorStatus>>[
        ButtonSegment<DonorStatus>(
          value: DonorStatus.donor,
          label: Text('Donor'),
        ),
        ButtonSegment<DonorStatus>(
          value: DonorStatus.notDonor,
          label: Text('Not a donor'),
        ),
        ButtonSegment<DonorStatus>(
          value: DonorStatus.unknown,
          label: Text('Unknown'),
        ),
      ],
      selected: <DonorStatus>{value},
      showSelectedIcon: false,
      onSelectionChanged: (Set<DonorStatus> s) => onChanged(s.first),
    );
  }
}
