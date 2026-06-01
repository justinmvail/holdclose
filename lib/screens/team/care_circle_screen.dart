import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/care_circle_membership.dart';
import '../../models/caregiver.dart';
import '../../providers/care_circle_provider.dart';
import '../../providers/link_launcher_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'care_circle_screen.g.dart';

/// Everything the roster renders, bundled so the screen consumes a single
/// [AsyncValue] (TASKS.md Phase 14.27).
@immutable
class CareCircleView {
  const CareCircleView({required this.members});

  final List<CareCircleMember> members;

  bool get isEmpty => members.isEmpty;
}

/// Bundles the care-circle members for [CareCircleScreen] (TASKS.md Phase
/// 14.27).
///
/// Watches the [CareCircle] notifier (not the repository directly) so an
/// add / accept / edit / remove saved through the notifier refreshes the
/// view without a manual invalidate. Tests override this provider
/// wholesale for the display + golden cases, and override
/// [careCircleRepositoryProvider] with an in-memory repo for the
/// edit-through-the-notifier cases.
@riverpod
Future<CareCircleView> careCircleView(Ref ref) async {
  final List<CareCircleMember> members =
      await ref.watch(careCircleProvider.future);
  return CareCircleView(members: members);
}

/// Care Circle roster at `/team/circle` (TASKS.md Phase 14.27,
/// BUILD_SPEC.md §5.14).
///
/// A [PathHeader] (`Home › Care Team › Care Circle`, back to Care Team)
/// with an "Invite caregiver" header action sits above the loved one's
/// caregivers. Each row carries an avatar (initials fallback), the
/// display name, a role chip, a permission badge (Owner / Editor /
/// Viewer), a tap-to-call button when a phone is on file, and a
/// long-press menu to edit the role + permission. The empty state nudges
/// the lone caregiver to invite someone to share the load.
class CareCircleScreen extends ConsumerWidget {
  const CareCircleScreen({super.key});

  static const Key listKey = Key('care-circle-list');
  static const Key emptyStateKey = Key('care-circle-empty');
  static const Key emptyCtaKey = Key('care-circle-empty-cta');
  static const Key inviteActionKey = Key('care-circle-invite');

  /// Stable per-row keys derived from the caregiver id so tests target a
  /// node rather than a copy string.
  static Key rowKey(String caregiverId) => Key('care-circle-row-$caregiverId');
  static Key callButtonKey(String caregiverId) =>
      Key('care-circle-call-$caregiverId');
  static Key permissionBadgeKey(String caregiverId) =>
      Key('care-circle-permission-$caregiverId');

  // Long-press edit sheet (role + permission).
  static const Key editSheetKey = Key('care-circle-edit-sheet');
  static const Key editSaveKey = Key('care-circle-edit-save');
  static Key editRoleOptionKey(CaregiverRole role) =>
      Key('care-circle-edit-role-${role.name}');
  static Key editPermissionOptionKey(PermissionLevel level) =>
      Key('care-circle-edit-permission-${level.name}');

  static const String _inviteRoute = '/team/circle/invite';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<CareCircleView> async = ref.watch(careCircleViewProvider);

    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Align(
                    alignment: Alignment.centerRight,
                    child: _InviteAction(
                      onPressed: () => context.push(_inviteRoute),
                    ),
                  ),
                  const PathHeader(
                    breadcrumbs: <PathHeaderCrumb>[
                      PathHeaderCrumb(label: 'Home', route: '/'),
                      PathHeaderCrumb(label: 'Care Team', route: '/team'),
                      PathHeaderCrumb(label: 'Care Circle'),
                    ],
                    title: 'Care Circle',
                    backLabel: 'Back to Care Team',
                    leadingIcon: Icons.diversity_3_outlined,
                  ),
                ],
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (CareCircleView view) {
                  if (view.isEmpty) return const _EmptyState();
                  return _MemberList(members: view.members);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InviteAction extends StatelessWidget {
  const _InviteAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Invite caregiver. Open the invite form.',
      child: TextButton.icon(
        key: CareCircleScreen.inviteActionKey,
        onPressed: onPressed,
        icon: Icon(Icons.person_add_alt_1_outlined, color: careblazersColors.cta),
        label: Text(
          'Invite caregiver',
          style: textTheme.labelLarge?.copyWith(color: careblazersColors.cta),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
      ),
    );
  }
}

class _MemberList extends StatelessWidget {
  const _MemberList({required this.members});

  final List<CareCircleMember> members;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: CareCircleScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: <Widget>[
        for (final CareCircleMember member in members)
          _MemberRow(member: member),
      ],
    );
  }
}

class _MemberRow extends ConsumerWidget {
  const _MemberRow({required this.member});

  final CareCircleMember member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Caregiver caregiver = member.caregiver;
    final String? phone = caregiver.phone;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: '${caregiver.displayName}, ${_roleLabel(caregiver.role)}, '
            '${_permissionLabel(member.membership.permissionLevel)}.'
            '${member.isPending ? ' Invite pending.' : ''} '
            'Long-press to edit role and permission.',
        child: Material(
          color: careblazersColors.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: CareCircleScreen.rowKey(caregiver.id),
            borderRadius: BorderRadius.circular(16),
            onLongPress: () => _openEditMenu(context, ref),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  _Avatar(caregiver: caregiver),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          caregiver.displayName,
                          style: textTheme.bodyLarge?.copyWith(
                            color: careblazersColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            _RoleChip(role: caregiver.role),
                            _PermissionBadge(
                              caregiverId: caregiver.id,
                              level: member.membership.permissionLevel,
                            ),
                            if (member.isPending) const _PendingTag(),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (phone != null && phone.trim().isNotEmpty)
                    Semantics(
                      button: true,
                      label: 'Call ${caregiver.displayName}.',
                      child: IconButton(
                        key: CareCircleScreen.callButtonKey(caregiver.id),
                        icon: const Icon(Icons.call),
                        color: careblazersColors.cta,
                        tooltip: 'Call ${caregiver.displayName}',
                        onPressed: () =>
                            ref.read(linkLauncherProvider).launch(_telUri(phone)),
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

  Future<void> _openEditMenu(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: careblazersColors.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) => _EditMemberSheet(member: member),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.caregiver});

  final Caregiver caregiver;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String? path = caregiver.avatarPath;
    final bool hasPhoto = path != null && File(path).existsSync();

    return CircleAvatar(
      radius: 24,
      backgroundColor: careblazersColors.primarySoft.withValues(alpha: 0.14),
      backgroundImage: hasPhoto ? FileImage(File(path)) : null,
      child: hasPhoto
          ? null
          : Text(
              _initials(caregiver.displayName),
              style: textTheme.titleLarge?.copyWith(
                color: careblazersColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final CaregiverRole role;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: careblazersColors.primarySoft.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _roleLabel(role),
        style: textTheme.bodyMedium?.copyWith(
          color: careblazersColors.primarySoft,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PermissionBadge extends StatelessWidget {
  const _PermissionBadge({required this.caregiverId, required this.level});

  final String caregiverId;
  final PermissionLevel level;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color color = _permissionColor(level);
    return Container(
      key: CareCircleScreen.permissionBadgeKey(caregiverId),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        _permissionLabel(level),
        style: textTheme.bodyMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PendingTag extends StatelessWidget {
  const _PendingTag();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      'Invite pending',
      style: textTheme.bodyMedium?.copyWith(
        color: careblazersColors.text,
        fontStyle: FontStyle.italic,
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
      key: CareCircleScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.diversity_3_outlined,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'Your care circle is just you right now. Invite someone to '
            'share the load.',
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'Invite caregiver. Open the invite form.',
            child: ElevatedButton.icon(
              key: CareCircleScreen.emptyCtaKey,
              onPressed: () => context.push('/team/circle/invite'),
              icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
              label: Text(
                'Invite caregiver',
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

// ---------------------------------------------------------------------------
// Edit role + permission (long-press menu)
// ---------------------------------------------------------------------------

/// Bottom sheet that edits a member's role + permission (TASKS.md Phase
/// 14.27). Opened on long-press of a roster row. Save writes both changes
/// through the [CareCircle] notifier — which refreshes the roster — then
/// pops.
class _EditMemberSheet extends ConsumerStatefulWidget {
  const _EditMemberSheet({required this.member});

  final CareCircleMember member;

  @override
  ConsumerState<_EditMemberSheet> createState() => _EditMemberSheetState();
}

class _EditMemberSheetState extends ConsumerState<_EditMemberSheet> {
  late CaregiverRole _role = widget.member.caregiver.role;
  late PermissionLevel _level = widget.member.membership.permissionLevel;
  bool _submitting = false;

  Future<void> _save() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    final CareCircle notifier = ref.read(careCircleProvider.notifier);
    await notifier.editRole(widget.member.caregiver.id, _role);
    await notifier.editPermission(widget.member.membership.id, _level);

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: CareCircleScreen.editSheetKey,
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Edit ${widget.member.caregiver.displayName}',
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Role',
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final CaregiverRole role in CaregiverRole.values)
                _ChoiceChip(
                  key: CareCircleScreen.editRoleOptionKey(role),
                  label: _roleLabel(role),
                  selected: role == _role,
                  onTap: () => setState(() => _role = role),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Permission',
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final PermissionLevel level in PermissionLevel.values)
                _ChoiceChip(
                  key: CareCircleScreen.editPermissionOptionKey(level),
                  label: _permissionLabel(level),
                  selected: level == _level,
                  onTap: () => setState(() => _level = level),
                ),
            ],
          ),
          const SizedBox(height: 28),
          ElevatedButton(
            key: CareCircleScreen.editSaveKey,
            onPressed: _submitting ? null : _save,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              backgroundColor: careblazersColors.cta,
              foregroundColor: Colors.white,
            ),
            child: Text(
              _submitting ? 'Saving…' : 'Save changes',
              style: textTheme.labelLarge?.copyWith(color: Colors.white),
            ),
          ),
        ],
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
          "We couldn't load your care circle.\n$message",
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

/// Up to two uppercase initials from [displayName]; falls back to `?` for
/// an empty name.
String _initials(String displayName) {
  final List<String> parts = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .where((String p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
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

Color _permissionColor(PermissionLevel level) {
  switch (level) {
    case PermissionLevel.owner:
      return careblazersColors.cta;
    case PermissionLevel.editor:
      return careblazersColors.link;
    case PermissionLevel.viewer:
      return careblazersColors.primarySoft;
  }
}

/// Build a dialable `tel:` URI from a free-text phone number, stripping
/// the formatting (spaces, parens, dashes) the caregiver typed but keeping
/// a leading `+` for international numbers. Mirrors the emergency-card
/// helper (BUILD_SPEC.md §5.17).
Uri _telUri(String phone) {
  final String digits = phone
      .replaceAll(RegExp(r'[^0-9+]'), '')
      .replaceAll(RegExp(r'(?!^)\+'), '');
  return Uri(scheme: 'tel', path: digits);
}
