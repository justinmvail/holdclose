import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/care_task.dart';
import '../../models/caregiver.dart';
import '../../providers/active_patient_provider.dart';
import '../../providers/care_tasks_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

part 'tasks_screen.g.dart';

/// Mints the unique id a new task needs. Overridable for tests + the demo
/// tour so the minted ids are deterministic; same shape as the invite /
/// appointment / medication form id factories.
typedef TaskIdFactory = String Function();

String _defaultTaskIdFactory() {
  final int ms = DateTime.now().millisecondsSinceEpoch;
  final int rand = math.Random().nextInt(1 << 32);
  return 'task-$ms-$rand';
}

/// Id factory the create sheet uses. Tests override this with a monotonic
/// counter so the minted ids are stable across runs.
@Riverpod(keepAlive: true)
TaskIdFactory taskIdFactory(Ref ref) => _defaultTaskIdFactory;

/// Care Circle → Tasks at `/team/tasks` (TASKS.md Phase 14.30, BUILD_SPEC.md
/// §5.14).
///
/// A [PathHeader] (`Home › Care Circle › Tasks`, back to Care Circle) over a
/// segmented filter (Open / Claimed / Done) and the matching task list.
/// Each card shows the title, due time, and — once claimed — the assignee's
/// avatar + name; its action buttons swap by lifecycle: an open task shows
/// **Claim**, a task claimed by the signed-in caregiver shows **Complete**
/// + **Unclaim**, and a done task shows none. The header FAB opens a
/// create-task sheet (title + body + due picker + optional assignee).
///
/// The joined view comes from [careTasksViewProvider]; the screen watches
/// it, filters by the selected segment, and routes mutations through the
/// [CareTasks] notifier.
class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  static const Key fabKey = Key('tasks-fab');
  static const Key listKey = Key('tasks-list');
  static const Key emptyStateKey = Key('tasks-empty');

  static Key segmentKey(CareTaskStatus status) =>
      Key('tasks-segment-${status.name}');

  /// Stable per-card keys derived from the task id so tests target a node
  /// rather than a copy string.
  static Key cardKey(String taskId) => Key('tasks-card-$taskId');
  static Key claimButtonKey(String taskId) => Key('tasks-claim-$taskId');
  static Key completeButtonKey(String taskId) => Key('tasks-complete-$taskId');
  static Key unclaimButtonKey(String taskId) => Key('tasks-unclaim-$taskId');

  // Long-press card menu (edit + delete).
  static const Key cardMenuKey = Key('tasks-card-menu');
  static const Key cardMenuEditKey = Key('tasks-card-menu-edit');
  static const Key cardMenuDeleteKey = Key('tasks-card-menu-delete');

  // Delete-confirmation dialog (a long-press → Delete on a task card).
  static const Key deleteDialogKey = Key('tasks-delete-dialog');
  static const Key deleteConfirmKey = Key('tasks-delete-confirm');
  static const Key deleteCancelKey = Key('tasks-delete-cancel');

  // Create-task sheet.
  static const Key createSheetKey = Key('tasks-create-sheet');
  static const Key titleFieldKey = Key('tasks-create-title');
  static const Key bodyFieldKey = Key('tasks-create-body');
  static const Key dueButtonKey = Key('tasks-create-due');
  static const Key dueClearKey = Key('tasks-create-due-clear');
  static const Key saveButtonKey = Key('tasks-create-save');
  static const Key titleErrorKey = Key('tasks-create-title-error');
  static const Key assigneeNoneKey = Key('tasks-create-assignee-none');
  static Key assigneeOptionKey(String caregiverId) =>
      Key('tasks-create-assignee-$caregiverId');

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  CareTaskStatus _segment = CareTaskStatus.open;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CareTaskCard>> async =
        ref.watch(careTasksViewProvider);
    final String me = ref.watch(currentCaregiverIdProvider);

    return Scaffold(
      backgroundColor: context.cb.background,
      floatingActionButton: _AddTaskFab(onPressed: () => _openCreateSheet()),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const PathHeader(
                    breadcrumbs: <PathHeaderCrumb>[
                      PathHeaderCrumb(label: 'Home', route: '/'),
                      PathHeaderCrumb(label: 'Care Circle', route: '/team'),
                      PathHeaderCrumb(label: 'Tasks'),
                    ],
                    title: 'Tasks',
                    backLabel: 'Back to Care Circle',
                    leadingIcon: Icons.checklist_outlined,
                  ),
                  const SizedBox(height: 12),
                  _SegmentedFilter(
                    selected: _segment,
                    onChanged: (CareTaskStatus s) =>
                        setState(() => _segment = s),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (List<CareTaskCard> cards) {
                  final List<CareTaskCard> filtered = cards
                      .where((CareTaskCard c) => c.task.status == _segment)
                      .toList();
                  if (filtered.isEmpty) {
                    return _EmptyState(segment: _segment);
                  }
                  return _TaskList(cards: filtered, me: me);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCreateSheet({CareTask? existing}) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.cb.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) =>
          _CreateTaskSheet(existing: existing),
    );
  }
}

class _AddTaskFab extends StatelessWidget {
  const _AddTaskFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Add task. Open the new-task form.',
      child: FloatingActionButton.extended(
        key: TasksScreen.fabKey,
        heroTag: 'tasks-add-fab',
        onPressed: onPressed,
        backgroundColor: context.cb.cta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Add task',
          style: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

/// Open / Claimed / Done segmented control. A row of three equal-width
/// pills; the selected one fills with the CTA tint.
class _SegmentedFilter extends StatelessWidget {
  const _SegmentedFilter({required this.selected, required this.onChanged});

  final CareTaskStatus selected;
  final ValueChanged<CareTaskStatus> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (final CareTaskStatus status in CareTaskStatus.values) ...<Widget>[
          Expanded(
            child: _SegmentPill(
              status: status,
              selected: status == selected,
              onTap: () => onChanged(status),
            ),
          ),
          if (status != CareTaskStatus.values.last) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _SegmentPill extends StatelessWidget {
  const _SegmentPill({
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final CareTaskStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String label = _segmentLabel(status);
    final Color border =
        selected ? context.cb.cta : context.cb.primarySoft;
    final Color fill = selected
        ? context.cb.cta.withValues(alpha: 0.12)
        : Colors.transparent;
    final Color fg = selected ? context.cb.cta : context.cb.text;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        key: TasksScreen.segmentKey(status),
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: textTheme.labelLarge?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({required this.cards, required this.me});

  final List<CareTaskCard> cards;
  final String me;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: TasksScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: <Widget>[
        for (final CareTaskCard card in cards) _TaskCard(card: card, me: me),
      ],
    );
  }
}

class _TaskCard extends ConsumerWidget {
  const _TaskCard({required this.card, required this.me});

  final CareTaskCard card;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final CareTask task = card.task;
    final bool claimedByMe = task.claimedBy(me);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        // The card's own actions stay in the action row; this exposes the
        // long-press affordance (edit + delete) to assistive tech.
        label: 'Long-press to edit or delete this task.',
        child: GestureDetector(
          onLongPress: () => _openCardMenu(context),
          child: Container(
            key: TasksScreen.cardKey(task.id),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(
              color: context.cb.surfaceWarm,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  task.title,
                  style: textTheme.bodyLarge?.copyWith(
                    color: context.cb.primary,
                    fontWeight: FontWeight.w700,
                    decoration:
                        task.isDone ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (task.body != null && task.body!.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    task.body!.trim(),
                    style: textTheme.bodyMedium
                        ?.copyWith(color: context.cb.text),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    if (task.dueAt != null) _DueChip(due: task.dueAt!),
                    if (task.claimedAt != null)
                      _AssigneeChip(
                        assignee: card.assignee,
                        isMe: task.assigneeCaregiverId == me,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _Actions(task: task, claimedByMe: claimedByMe, me: me),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Long-press menu on a task card: edit (reopens the create sheet
  /// prefilled, saving through the upsert path) or delete (confirm, then
  /// drop through the [CareTasks] notifier). Mirrors the care-circle roster's
  /// long-press action sheet.
  Future<void> _openCardMenu(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.cb.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) =>
          _TaskCardMenu(task: card.task),
    );
  }
}

/// The long-press action sheet for a task card — Edit (reopens the create
/// sheet prefilled) + Delete (confirm → [CareTasks.removeTask]). Kept as its
/// own consumer so it reads the notifier directly, the way the care-circle
/// edit sheet does.
class _TaskCardMenu extends ConsumerWidget {
  const _TaskCardMenu({required this.task});

  final CareTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: TasksScreen.cardMenuKey,
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
            task.title,
            style: textTheme.titleLarge?.copyWith(
              color: context.cb.primary,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: 'Edit this task.',
            child: ListTile(
              key: TasksScreen.cardMenuEditKey,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined, color: context.cb.link),
              title: Text(
                'Edit task',
                style: textTheme.bodyLarge?.copyWith(
                  color: context.cb.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onTap: () {
                Navigator.of(context).pop();
                _openEditSheet(context);
              },
            ),
          ),
          Semantics(
            button: true,
            label: 'Delete this task.',
            child: ListTile(
              key: TasksScreen.cardMenuDeleteKey,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.delete_outline,
                color: context.cb.accentDeep,
              ),
              title: Text(
                'Delete task',
                style: textTheme.bodyLarge?.copyWith(
                  color: context.cb.accentDeep,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onTap: () => _confirmAndDelete(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  /// Reopen the create sheet seeded with this task so a save replaces it in
  /// place (same id) through the upsert path.
  Future<void> _openEditSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.cb.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) => _CreateTaskSheet(existing: task),
    );
  }

  /// Confirm, then drop the task through the [CareTasks] notifier (which
  /// refreshes the board), then pop the menu. No-op on cancel.
  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            key: TasksScreen.deleteDialogKey,
            title: const Text('Delete task?'),
            content: Text(
              '"${task.title}" will be removed from the board. This can\'t '
              'be undone.',
            ),
            actions: <Widget>[
              TextButton(
                key: TasksScreen.deleteCancelKey,
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: TasksScreen.deleteConfirmKey,
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(
                  'Delete',
                  style: TextStyle(color: context.cb.accentDeep),
                ),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    await ref.read(careTasksProvider.notifier).removeTask(task.id);
    if (!context.mounted) return;
    Navigator.of(context).pop();
  }
}

/// The action row whose buttons swap by lifecycle (BUILD_SPEC.md §5.14):
/// Open → Claim; Claimed-by-me → Complete + Unclaim; everything else (Done,
/// or claimed by another caregiver) → no actions.
class _Actions extends ConsumerWidget {
  const _Actions({
    required this.task,
    required this.claimedByMe,
    required this.me,
  });

  final CareTask task;
  final bool claimedByMe;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The notifier is read inside each callback (not at build) so a
    // display-only render — e.g. a golden — never instantiates it.
    if (task.isOpen) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _PrimaryAction(
          key: TasksScreen.claimButtonKey(task.id),
          label: 'Claim',
          icon: Icons.pan_tool_alt_outlined,
          onPressed: () =>
              ref.read(careTasksProvider.notifier).claim(task.id, me),
        ),
      );
    }

    if (task.isClaimed && claimedByMe) {
      return Row(
        children: <Widget>[
          _PrimaryAction(
            key: TasksScreen.completeButtonKey(task.id),
            label: 'Complete',
            icon: Icons.check,
            onPressed: () =>
                ref.read(careTasksProvider.notifier).complete(task.id),
          ),
          const SizedBox(width: 12),
          _SecondaryAction(
            key: TasksScreen.unclaimButtonKey(task.id),
            label: 'Unclaim',
            onPressed: () =>
                ref.read(careTasksProvider.notifier).unclaim(task.id),
          ),
        ],
      );
    }

    // Done, or claimed by another caregiver — no actions for me.
    return const SizedBox.shrink();
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: label,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20, color: Colors.white),
        label: Text(
          label,
          style: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: context.cb.cta,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        ),
      ),
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: label,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: context.cb.link,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        child: Text(
          label,
          style: textTheme.labelLarge?.copyWith(color: context.cb.link),
        ),
      ),
    );
  }
}

class _DueChip extends StatelessWidget {
  const _DueChip({required this.due});

  final DateTime due;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.schedule, size: 16, color: context.cb.primarySoft),
        const SizedBox(width: 4),
        Text(
          formatDue(due),
          style: textTheme.bodyMedium?.copyWith(
            color: context.cb.primarySoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _AssigneeChip extends StatelessWidget {
  const _AssigneeChip({required this.assignee, required this.isMe});

  final Caregiver? assignee;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String name = assignee?.displayName ?? (isMe ? 'You' : 'Assigned');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _MiniAvatar(name: name, avatarPath: assignee?.avatarPath),
        const SizedBox(width: 6),
        Text(
          name,
          style: textTheme.bodyMedium?.copyWith(
            color: context.cb.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  const _MiniAvatar({required this.name, this.avatarPath});

  final String name;
  final String? avatarPath;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String? path = avatarPath;
    final bool hasPhoto = path != null && File(path).existsSync();
    return CircleAvatar(
      radius: 13,
      backgroundColor: context.cb.primarySoft.withValues(alpha: 0.14),
      backgroundImage: hasPhoto ? FileImage(File(path)) : null,
      child: hasPhoto
          ? null
          : Text(
              _initials(name),
              style: textTheme.bodyMedium?.copyWith(
                color: context.cb.primary,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.segment});

  final CareTaskStatus segment;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: TasksScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.task_alt_outlined,
            size: 56,
            color: context.cb.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            _emptyMessage(segment),
            style: textTheme.bodyLarge?.copyWith(color: context.cb.text),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create-task sheet
// ---------------------------------------------------------------------------

/// Bottom sheet that creates *or edits* a task (TASKS.md Phase 14.30).
/// Collects a title (required), an optional body + due time, and an optional
/// assignee drawn from the care circle. Save writes through the [CareTasks]
/// notifier — which refreshes the board — then pops. When [existing] is
/// passed the fields seed from it and the save replaces it in place (same id,
/// preserving the claim/complete lifecycle) via the notifier's upsert path.
class _CreateTaskSheet extends ConsumerStatefulWidget {
  const _CreateTaskSheet({this.existing});

  /// The task being edited, or null when creating a new one.
  final CareTask? existing;

  @override
  ConsumerState<_CreateTaskSheet> createState() => _CreateTaskSheetState();
}

class _CreateTaskSheetState extends ConsumerState<_CreateTaskSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?.title ?? '');
  late final TextEditingController _body =
      TextEditingController(text: widget.existing?.body ?? '');
  late DateTime? _dueAt = widget.existing?.dueAt;
  late String? _assigneeId = widget.existing?.assigneeCaregiverId;
  String? _titleError;
  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final DateTime now = ref.read(careTasksClockProvider)();
    final DateTime base = _dueAt ?? now;
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (!mounted) return;
    setState(() {
      _dueAt = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? base.hour,
        time?.minute ?? base.minute,
      );
    });
  }

  Future<void> _save() async {
    if (_submitting) return;
    final String title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = 'Give the task a title.');
      return;
    }
    setState(() {
      _submitting = true;
      _titleError = null;
    });

    final String body = _body.text.trim();
    final CareTask? existing = widget.existing;
    // A new task is filed under the active loved one's id (was the
    // `careTasksPatientId` const) so it follows whichever person is
    // selected (multi-patient, Issue #6). This is the patient the task is
    // *for* — distinct from `currentCaregiverId`, the person who later
    // claims it. The edit path leaves the existing task's patientId alone.
    // With one patient on file [activePatientIdProvider] resolves to that
    // sole id, identical to the old const.
    final String patientId = existing != null
        ? existing.patientId
        : await ref.read(activePatientIdProvider.future);
    final CareTask task = existing != null
        // Edit: keep the id + lifecycle stamps so a claimed/done task stays
        // in its lane after an edit; only the editable fields change.
        ? existing.copyWith(
            title: title,
            body: body.isEmpty ? null : body,
            dueAt: _dueAt,
            assigneeCaregiverId: _assigneeId,
          )
        : CareTask(
            id: ref.read(taskIdFactoryProvider)(),
            title: title,
            body: body.isEmpty ? null : body,
            dueAt: _dueAt,
            assigneeCaregiverId: _assigneeId,
            patientId: patientId,
          );
    await ref.read(careTasksProvider.notifier).addTask(task);

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AsyncValue<List<Caregiver>> caregivers =
        ref.watch(assignableCaregiversProvider);

    return Padding(
      key: TasksScreen.createSheetKey,
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _isEditing ? 'Edit task' : 'New task',
              style: textTheme.titleLarge?.copyWith(
                color: context.cb.primary,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: TasksScreen.titleFieldKey,
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Title',
                errorText: _titleError,
                errorMaxLines: 2,
              ),
            ),
            // A keyed error finder for tests, mirrored on the field above.
            if (_titleError != null)
              Padding(
                key: TasksScreen.titleErrorKey,
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _titleError!,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: context.cb.error),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              key: TasksScreen.bodyFieldKey,
              controller: _body,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Details (optional)',
              ),
            ),
            const SizedBox(height: 20),
            _DuePickerRow(
              due: _dueAt,
              onPick: _pickDue,
              onClear: () => setState(() => _dueAt = null),
            ),
            const SizedBox(height: 20),
            Text(
              'Assign to (optional)',
              style: textTheme.bodyLarge?.copyWith(
                color: context.cb.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            caregivers.when(
              loading: () => const SizedBox.shrink(),
              error: (Object e, StackTrace _) => const SizedBox.shrink(),
              data: (List<Caregiver> list) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _AssigneeChoice(
                    key: TasksScreen.assigneeNoneKey,
                    label: 'No one yet',
                    selected: _assigneeId == null,
                    onTap: () => setState(() => _assigneeId = null),
                  ),
                  for (final Caregiver c in list)
                    _AssigneeChoice(
                      key: TasksScreen.assigneeOptionKey(c.id),
                      label: c.displayName,
                      selected: _assigneeId == c.id,
                      onTap: () => setState(() => _assigneeId = c.id),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              key: TasksScreen.saveButtonKey,
              onPressed: _submitting ? null : _save,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: context.cb.cta,
                foregroundColor: Colors.white,
              ),
              child: Text(
                _submitting
                    ? 'Saving…'
                    : (_isEditing ? 'Save changes' : 'Add task'),
                style: textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DuePickerRow extends StatelessWidget {
  const _DuePickerRow({
    required this.due,
    required this.onPick,
    required this.onClear,
  });

  final DateTime? due;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            button: true,
            label: due == null
                ? 'Set a due time'
                : 'Due ${formatDue(due!)}. Change due time.',
            child: OutlinedButton.icon(
              key: TasksScreen.dueButtonKey,
              onPressed: onPick,
              icon: Icon(Icons.event_outlined, color: context.cb.link),
              label: Text(
                due == null ? 'Set due time' : formatDue(due!),
                style:
                    textTheme.labelLarge?.copyWith(color: context.cb.link),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: context.cb.primarySoft),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ),
        if (due != null)
          Semantics(
            button: true,
            label: 'Clear due time',
            child: IconButton(
              key: TasksScreen.dueClearKey,
              icon: const Icon(Icons.close),
              color: context.cb.primarySoft,
              tooltip: 'Clear due time',
              onPressed: onClear,
            ),
          ),
      ],
    );
  }
}

class _AssigneeChoice extends StatelessWidget {
  const _AssigneeChoice({
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
        selected ? context.cb.cta : context.cb.primarySoft;
    final Color fill = selected
        ? context.cb.cta.withValues(alpha: 0.12)
        : Colors.transparent;
    final Color fg = selected ? context.cb.cta : context.cb.text;
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
          "We couldn't load the tasks.\n$message",
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

String _segmentLabel(CareTaskStatus status) {
  switch (status) {
    case CareTaskStatus.open:
      return 'Open';
    case CareTaskStatus.claimed:
      return 'Claimed';
    case CareTaskStatus.done:
      return 'Done';
  }
}

String _emptyMessage(CareTaskStatus status) {
  switch (status) {
    case CareTaskStatus.open:
      return 'No open tasks right now. Tap Add task to share something '
          'with your care circle.';
    case CareTaskStatus.claimed:
      return 'Nothing is claimed yet. Claim an open task to take it on.';
    case CareTaskStatus.done:
      return 'No tasks are finished yet. Completed tasks land here.';
  }
}

/// Up to two uppercase initials from [name]; falls back to `?` for an empty
/// name. Mirrors the care-circle roster helper.
String _initials(String name) {
  final List<String> parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((String p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

const List<String> _monthsShort = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Jun 3, 2:30 PM" — the due time shown on a card + the create sheet.
String formatDue(DateTime due) {
  final String month = _monthsShort[due.month - 1];
  final int rawHour = due.hour % 12;
  final int hour = rawHour == 0 ? 12 : rawHour;
  final String minute = due.minute.toString().padLeft(2, '0');
  final String suffix = due.hour < 12 ? 'AM' : 'PM';
  return '$month ${due.day}, $hour:$minute $suffix';
}
