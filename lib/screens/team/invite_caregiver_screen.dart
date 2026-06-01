import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/care_circle_membership.dart';
import '../../models/caregiver.dart';
import '../../models/patient.dart';
import '../../providers/care_circle_provider.dart';
import '../../providers/share_provider.dart';
import '../../providers/storage_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'invite_caregiver_screen.g.dart';

/// Fallback loved-one id used when no [Patient] is on file yet — e.g. a
/// fresh real-mode install where onboarding hasn't populated one. Matches
/// the demo seed's `maryHenderson` id so a freshly-invited membership
/// lines up with any seeded care-circle rows. Mirrors the health-log
/// form's fallback (Phase 14.17).
const String _fallbackPatientId = 'demo-patient-mary';

/// Base URL the invite link is built against. Token generation +
/// acceptance back-end are deferred (TASKS.md Phase 14.28) — this is the
/// share-surface placeholder the caregiver hands a co-caregiver.
const String _inviteBaseUrl = 'https://careblazers.app/invite';

/// Mints the unique fragments the invite needs — the caregiver row id,
/// the membership row id, and the share-link token. Overridable for tests
/// + the demo tour so id/token sequences are deterministic; same shape as
/// the health-log / appointment / medication form id factories.
typedef InviteIdFactory = String Function();

String _defaultInviteIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return '$ms-$rand';
}

/// ID/token factory the invite form uses. Tests override this with a
/// monotonic counter so the minted ids + token are stable across runs.
@Riverpod(keepAlive: true)
InviteIdFactory inviteCaregiverIdFactory(Ref ref) => _defaultInviteIdFactory;

/// Care Circle invite form (TASKS.md Phase 14.28, BUILD_SPEC.md §5.14) at
/// `/team/circle/invite`.
///
/// Collects a display name (required), a role, at least one contact point
/// (email OR phone), and a permission level (Owner / Editor / Viewer,
/// defaulting to Viewer). Send lands a pending [CareCircleMembership]
/// (`acceptedAt` null) plus its [Caregiver] through the [CareCircle]
/// notifier, then composes the share message
/// ("Join my Careblazers care circle: …/invite/<token>") and hands it to
/// the platform share sheet via [sharerProvider].
///
/// Token generation + the acceptance back-end are deferred to a later
/// phase — this task lands the data row + the share surface only.
class InviteCaregiverScreen extends ConsumerStatefulWidget {
  const InviteCaregiverScreen({super.key});

  static const Key formKey = Key('invite-caregiver-form');
  static const Key displayNameFieldKey = Key('invite-caregiver-display-name');
  static const Key emailFieldKey = Key('invite-caregiver-email');
  static const Key phoneFieldKey = Key('invite-caregiver-phone');
  static const Key contactErrorKey = Key('invite-caregiver-contact-error');
  static const Key sendButtonKey = Key('invite-caregiver-send');

  static Key roleChipKey(CaregiverRole role) =>
      Key('invite-caregiver-role-${role.name}');
  static Key permissionRadioKey(PermissionLevel level) =>
      Key('invite-caregiver-permission-${level.name}');

  @override
  ConsumerState<InviteCaregiverScreen> createState() =>
      _InviteCaregiverScreenState();
}

class _InviteCaregiverScreenState extends ConsumerState<InviteCaregiverScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _displayName = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _phone = TextEditingController();

  CaregiverRole _role = CaregiverRole.other;
  PermissionLevel _permission = PermissionLevel.viewer;
  String? _contactError;
  bool _submitting = false;

  @override
  void dispose() {
    _displayName.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _selectRole(CaregiverRole role) {
    if (role == _role) return;
    setState(() => _role = role);
  }

  void _selectPermission(PermissionLevel? level) {
    if (level == null || level == _permission) return;
    setState(() => _permission = level);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    // "At least one of email / phone" spans two fields, so it lives
    // outside the per-field validators — same shape as the health-log
    // form's cross-field rule.
    final String email = _email.text.trim();
    final String phone = _phone.text.trim();
    if (email.isEmpty && phone.isEmpty) {
      setState(() => _contactError =
          'Add an email or a phone number so we can reach them.');
      return;
    }

    setState(() {
      _contactError = null;
      _submitting = true;
    });

    // Captured before the awaits below so the post-share confirmation
    // doesn't reach for `context` across an async gap. The app-level
    // messenger survives the pop back to the roster.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    // Resolve the loved one the new member is attached to. Onboarding
    // populates the single patient row; fall back to the demo id when
    // it's empty so an invite still lands.
    final Patient? patient = await ref.read(storageProvider).getPatient();
    final String patientId = patient?.id ?? _fallbackPatientId;

    final InviteIdFactory mint = ref.read(inviteCaregiverIdFactoryProvider);
    final String caregiverId = 'cg-${mint()}';
    final String membershipId = 'm-${mint()}';
    final String token = mint();
    final DateTime now = ref.read(careCircleClockProvider)();

    final Caregiver caregiver = Caregiver(
      id: caregiverId,
      displayName: _displayName.text.trim(),
      role: _role,
      phone: phone.isEmpty ? null : phone,
      email: email.isEmpty ? null : email,
    );
    final CareCircleMembership membership = CareCircleMembership(
      id: membershipId,
      caregiverId: caregiverId,
      patientId: patientId,
      permissionLevel: _permission,
      invitedAt: now,
      // Pending until the co-caregiver accepts (acceptance back-end is a
      // later phase).
    );

    await ref
        .read(careCircleProvider.notifier)
        .addMember(caregiver: caregiver, membership: membership);

    // share_plus is already a dep (pubspec.yaml + BUILD_SPEC.md §1), so
    // hand the invite to the platform share sheet rather than copying to
    // the clipboard.
    final String message =
        'Join my Careblazers care circle: $_inviteBaseUrl/$token';
    await ref
        .read(sharerProvider)
        .share(message, subject: 'Join my Careblazers care circle');

    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('Invitation ready for ${caregiver.displayName}.'),
      ),
    );
    _leave();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/team/circle');
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            key: InviteCaregiverScreen.formKey,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: <Widget>[
              const PathHeader(
                breadcrumbs: <PathHeaderCrumb>[
                  PathHeaderCrumb(label: 'Home', route: '/'),
                  PathHeaderCrumb(label: 'Care Team', route: '/team'),
                  PathHeaderCrumb(
                    label: 'Care Circle',
                    route: '/team/circle',
                  ),
                  PathHeaderCrumb(label: 'Invite'),
                ],
                title: 'Invite a caregiver',
                backLabel: 'Back to Care Circle',
                leadingIcon: Icons.person_add_alt_1_outlined,
              ),
              const SizedBox(height: 8),
              Text(
                'Share the load. Invite someone who helps care for your '
                'loved one and choose what they can see and change.',
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                ),
              ),
              const SizedBox(height: 24),
              const _FieldLabel(label: 'Name'),
              const SizedBox(height: 8),
              TextFormField(
                key: InviteCaregiverScreen.displayNameFieldKey,
                controller: _displayName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  hintText: 'e.g. Sarah Henderson',
                ),
                validator: (String? v) {
                  if ((v ?? '').trim().isEmpty) {
                    return 'Add a name so you know who you invited.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),
              const _FieldLabel(label: 'Their role'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final CaregiverRole role in CaregiverRole.values)
                    _ChoiceChip(
                      key: InviteCaregiverScreen.roleChipKey(role),
                      label: _roleLabel(role),
                      selected: role == _role,
                      onTap: () => _selectRole(role),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              const _FieldLabel(label: 'How to reach them'),
              const SizedBox(height: 4),
              Text(
                'Add an email, a phone number, or both — at least one.',
                style: textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.primarySoft,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: InviteCaregiverScreen.emailFieldKey,
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'name@example.com',
                ),
                validator: (String? v) {
                  final String t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  if (!t.contains('@') || !t.contains('.')) {
                    return 'Enter a valid email address.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: InviteCaregiverScreen.phoneFieldKey,
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  hintText: '(555) 010-0100',
                ),
                validator: (String? v) {
                  final String t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  final String digits = t.replaceAll(RegExp(r'[^0-9]'), '');
                  if (digits.length < 7) {
                    return 'Enter a valid phone number.';
                  }
                  return null;
                },
              ),
              if (_contactError != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _contactError!,
                  key: InviteCaregiverScreen.contactErrorKey,
                  style: textTheme.bodyMedium?.copyWith(
                    color: careblazersColors.cta,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              const _FieldLabel(label: 'What can they do?'),
              const SizedBox(height: 8),
              RadioGroup<PermissionLevel>(
                groupValue: _permission,
                onChanged: _selectPermission,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final PermissionLevel level in PermissionLevel.values)
                      _PermissionTile(
                        level: level,
                        selected: level == _permission,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Semantics(
                button: true,
                label: 'Send the invitation and share the link.',
                child: ElevatedButton(
                  key: InviteCaregiverScreen.sendButtonKey,
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    backgroundColor: careblazersColors.cta,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    _submitting ? 'Sending…' : 'Send invitation',
                    style: textTheme.labelLarge?.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({required this.level, required this.selected});

  final PermissionLevel level;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? careblazersColors.cta.withValues(alpha: 0.10)
            : careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(12),
        child: RadioListTile<PermissionLevel>(
          key: InviteCaregiverScreen.permissionRadioKey(level),
          value: level,
          activeColor: careblazersColors.cta,
          controlAffinity: ListTileControlAffinity.trailing,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Text(
            _permissionLabel(level),
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            _permissionBlurb(level),
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.text,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
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
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
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

String _roleLabel(CaregiverRole role) {
  switch (role) {
    case CaregiverRole.primary:
      return 'Primary caregiver';
    case CaregiverRole.spouse:
      return 'Spouse';
    case CaregiverRole.child:
      return 'Child';
    case CaregiverRole.sibling:
      return 'Sibling';
    case CaregiverRole.aide:
      return 'Aide';
    case CaregiverRole.agency:
      return 'Agency';
    case CaregiverRole.friend:
      return 'Friend';
    case CaregiverRole.other:
      return 'Other';
  }
}

String _permissionLabel(PermissionLevel level) {
  switch (level) {
    case PermissionLevel.owner:
      return 'Owner';
    case PermissionLevel.editor:
      return 'Editor';
    case PermissionLevel.viewer:
      return 'Viewer';
  }
}

String _permissionBlurb(PermissionLevel level) {
  switch (level) {
    case PermissionLevel.owner:
      return 'Manages the circle — invites, removes, and changes what '
          'others can do.';
    case PermissionLevel.editor:
      return 'Can update care details like medications, appointments, and '
          'tasks.';
    case PermissionLevel.viewer:
      return 'Can see the care details, but not change them.';
  }
}
