import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../models/caregiver.dart';
import '../../models/expense.dart';
import '../../providers/active_patient_provider.dart';
import '../../providers/care_tasks_provider.dart' show currentCaregiverIdProvider;
import '../../providers/expenses_provider.dart';
import '../../providers/photo_attacher_provider.dart';
import '../../theme.dart';
import '../../widgets/form/form_error_view.dart';
import '../../widgets/form/format.dart';
import '../../widgets/form/id_factory.dart';
import '../../widgets/path_header.dart';

part 'expenses_screen.g.dart';

/// Mints the unique id a new expense needs. Overridable for tests + the
/// demo tour so the minted ids are deterministic; same shape as the task /
/// invite / appointment form id factories.
typedef ExpenseIdFactory = String Function();

String _defaultExpenseIdFactory() => mintId('expense');

/// Id factory the create form uses. Tests override this with a monotonic
/// counter so the minted ids are stable across runs.
@Riverpod(keepAlive: true)
ExpenseIdFactory expenseIdFactory(Ref ref) => _defaultExpenseIdFactory;

/// Care Circle → Expenses at `/team/expenses` (TASKS.md Phase 14.33,
/// BUILD_SPEC.md §5.14).
///
/// A [PathHeader] (`Home › Care Circle › Expenses`, back to Care Circle) over a
/// sticky current-month total card and a list of expenses grouped by month.
/// Each row shows the amount, a kind chip, the description, and the paying
/// caregiver's initials. The FAB opens a create form (amount + kind +
/// description + paid date + payer picker + optional receipt path).
///
/// The grouped view comes from [expensesViewProvider]; the screen watches
/// it and routes mutations through the [Expenses] notifier.
class ExpensesScreen extends ConsumerWidget {
  const ExpensesScreen({super.key});

  static const Key fabKey = Key('expenses-fab');
  static const Key listKey = Key('expenses-list');
  static const Key emptyStateKey = Key('expenses-empty');
  static const Key monthlyTotalCardKey = Key('expenses-monthly-total');

  /// Stable per-section + per-row keys derived from ids so tests target a
  /// node rather than a copy string.
  static Key monthHeaderKey(String monthKey) =>
      Key('expenses-month-$monthKey');
  static Key rowKey(String expenseId) => Key('expenses-row-$expenseId');

  // Delete-confirmation dialog (a long-press on an expense row).
  static const Key deleteDialogKey = Key('expenses-delete-dialog');
  static const Key deleteConfirmKey = Key('expenses-delete-confirm');
  static const Key deleteCancelKey = Key('expenses-delete-cancel');

  // Create-expense sheet.
  static const Key createSheetKey = Key('expenses-create-sheet');
  static const Key amountFieldKey = Key('expenses-create-amount');
  static const Key amountErrorKey = Key('expenses-create-amount-error');
  static const Key descriptionFieldKey = Key('expenses-create-description');
  static const Key descriptionErrorKey = Key('expenses-create-description-error');
  static const Key paidDateButtonKey = Key('expenses-create-date');
  static const Key receiptButtonKey = Key('expenses-create-receipt');
  static const Key receiptThumbnailKey = Key('expenses-create-receipt-thumb');
  static const Key saveButtonKey = Key('expenses-create-save');

  static Key kindOptionKey(ExpenseKind kind) =>
      Key('expenses-create-kind-${kind.name}');
  static Key payerOptionKey(String payerId) =>
      Key('expenses-create-payer-$payerId');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ExpenseMonthGroup>> async =
        ref.watch(expensesViewProvider);
    final String me = ref.watch(currentCaregiverIdProvider);
    final DateTime now = ref.watch(expensesClockProvider)();
    final String currentMonthKey = monthKeyOf(now);

    return Scaffold(
      backgroundColor: context.hc.background,
      floatingActionButton:
          _AddExpenseFab(onPressed: () => _openCreateSheet(context)),
      body: SafeArea(
        child: async.when(
          loading: () => const SizedBox.shrink(),
          error: (Object e, StackTrace _) => FormErrorView(
              message: "We couldn't load the expenses.\n$e"),
          data: (List<ExpenseMonthGroup> groups) {
            final int currentTotal = groups
                .where((ExpenseMonthGroup g) => g.monthKey == currentMonthKey)
                .fold<int>(0, (int sum, ExpenseMonthGroup g) => sum + g.totalCents);
            final String currency = _ledgerCurrency(groups);

            return Column(
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
                          PathHeaderCrumb(label: 'Expenses'),
                        ],
                        title: 'Expenses',
                        backLabel: 'Back to Care Circle',
                        leadingIcon: Icons.account_balance_wallet_outlined,
                      ),
                      const SizedBox(height: 12),
                      _MonthlyTotalCard(
                        monthKey: currentMonthKey,
                        totalCents: currentTotal,
                        currency: currency,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: groups.isEmpty
                      ? const _EmptyState()
                      : _Ledger(groups: groups, me: me),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _openCreateSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.hc.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) => const _CreateExpenseSheet(),
    );
  }
}

class _AddExpenseFab extends StatelessWidget {
  const _AddExpenseFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Add expense. Open the new-expense form.',
      child: FloatingActionButton.extended(
        key: ExpensesScreen.fabKey,
        heroTag: 'expenses-add-fab',
        onPressed: onPressed,
        backgroundColor: context.hc.cta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Add expense',
          style: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

/// Sticky card at the top of the ledger showing the current month's total
/// (BUILD_SPEC.md §5.14).
class _MonthlyTotalCard extends StatelessWidget {
  const _MonthlyTotalCard({
    required this.monthKey,
    required this.totalCents,
    required this.currency,
  });

  final String monthKey;
  final int totalCents;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: ExpensesScreen.monthlyTotalCardKey,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: context.hc.primary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Spent in ${monthLabel(monthKey)}',
            style: textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.82),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            formatMoney(totalCents, currency),
            style: textTheme.displayLarge?.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _Ledger extends StatelessWidget {
  const _Ledger({required this.groups, required this.me});

  final List<ExpenseMonthGroup> groups;
  final String me;

  @override
  Widget build(BuildContext context) {
    // Builder form so the (unbounded) ledger builds month sections
    // lazily; render order and widgets are unchanged.
    return ListView.builder(
      key: ExpensesScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: groups.length,
      itemBuilder: (BuildContext context, int i) =>
          _MonthSection(group: groups[i], me: me),
    );
  }
}

class _MonthSection extends StatelessWidget {
  const _MonthSection({required this.group, required this.me});

  final ExpenseMonthGroup group;
  final String me;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String currency =
        group.rows.isEmpty ? 'USD' : group.rows.first.expense.currency;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          key: ExpensesScreen.monthHeaderKey(group.monthKey),
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  monthLabel(group.monthKey),
                  style: textTheme.titleLarge
                      ?.copyWith(color: context.hc.primary),
                ),
              ),
              Text(
                formatMoney(group.totalCents, currency),
                style: textTheme.titleLarge?.copyWith(
                  color: context.hc.primarySoft,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        for (final ExpenseRow row in group.rows)
          _ExpenseTile(row: row, me: me),
      ],
    );
  }
}

class _ExpenseTile extends ConsumerWidget {
  const _ExpenseTile({required this.row, required this.me});

  final ExpenseRow row;
  final String me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Expense expense = row.expense;
    final bool isMe = expense.paidByCaregiverId == me;
    final String payerName =
        row.payer?.displayName ?? (isMe ? 'You' : 'Unknown');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: '${expense.description}, '
            '${formatMoney(expense.amountCents, expense.currency)}. '
            'Tap to edit, long-press to delete.',
        child: GestureDetector(
          onTap: () => _openEditSheet(context),
          onLongPress: () => _confirmAndDelete(context, ref),
          child: Container(
            key: ExpensesScreen.rowKey(expense.id),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: context.hc.surfaceWarm,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        expense.description,
                        style: textTheme.bodyLarge?.copyWith(
                          color: context.hc.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          _KindChip(kind: expense.kind),
                          _PayerChip(
                            name: payerName,
                            avatarPath: row.payer?.avatarPath,
                          ),
                          if (expense.receiptPath != null &&
                              expense.receiptPath!.trim().isNotEmpty)
                            _ReceiptChip(),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  formatMoney(expense.amountCents, expense.currency),
                  style: textTheme.bodyLarge?.copyWith(
                    color: context.hc.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Reopen the create sheet seeded with this expense so a save replaces it
  /// in place (same id) through [Expenses.updateExpense].
  Future<void> _openEditSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.hc.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) =>
          _CreateExpenseSheet(existing: row.expense),
    );
  }

  /// Confirm, then drop the expense through the [Expenses] notifier (which
  /// refreshes the ledger). No-op on cancel. Mirrors the medication list's
  /// long-press soft-delete dialog.
  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final Expense expense = row.expense;
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            key: ExpensesScreen.deleteDialogKey,
            title: const Text('Delete expense?'),
            content: Text(
              '"${expense.description}" '
              '(${formatMoney(expense.amountCents, expense.currency)}) '
              "will be removed from the ledger. This can't be undone.",
            ),
            actions: <Widget>[
              TextButton(
                key: ExpensesScreen.deleteCancelKey,
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: ExpensesScreen.deleteConfirmKey,
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(
                  'Delete',
                  style: TextStyle(color: context.hc.accentDeep),
                ),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    await ref.read(expensesProvider.notifier).removeExpense(expense.id);
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});

  final ExpenseKind kind;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: context.hc.primarySoft.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(kindIcon(kind), size: 15, color: context.hc.primarySoft),
          const SizedBox(width: 5),
          Text(
            kindLabel(kind),
            style: textTheme.bodyMedium?.copyWith(
              color: context.hc.primarySoft,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _PayerChip extends StatelessWidget {
  const _PayerChip({required this.name, this.avatarPath});

  final String name;
  final String? avatarPath;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _MiniAvatar(name: name, avatarPath: avatarPath),
        const SizedBox(width: 6),
        Text(
          name,
          style: textTheme.bodyMedium?.copyWith(
            color: context.hc.text,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ReceiptChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.receipt_long_outlined,
            size: 15, color: context.hc.link),
        const SizedBox(width: 4),
        Text(
          'Receipt',
          style: textTheme.bodyMedium?.copyWith(
            color: context.hc.link,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MiniAvatar extends StatefulWidget {
  const _MiniAvatar({required this.name, this.avatarPath});

  final String name;
  final String? avatarPath;

  @override
  State<_MiniAvatar> createState() => _MiniAvatarState();
}

class _MiniAvatarState extends State<_MiniAvatar> {
  /// Whether [_MiniAvatar.avatarPath] points at a real file — resolved
  /// once per path (initState / path change) instead of stat-ing the
  /// filesystem on every build.
  bool _hasPhoto = false;

  @override
  void initState() {
    super.initState();
    _resolvePhoto();
  }

  @override
  void didUpdateWidget(_MiniAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatarPath != widget.avatarPath) _resolvePhoto();
  }

  void _resolvePhoto() {
    final String? path = widget.avatarPath;
    _hasPhoto = path != null && File(path).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String? path = widget.avatarPath;
    final bool hasPhoto = _hasPhoto;
    return CircleAvatar(
      radius: 12,
      backgroundColor: context.hc.primarySoft.withValues(alpha: 0.14),
      backgroundImage: hasPhoto ? FileImage(File(path!)) : null,
      child: hasPhoto
          ? null
          : Text(
              initials(widget.name),
              style: textTheme.bodyMedium?.copyWith(
                color: context.hc.primary,
                fontWeight: FontWeight.w700,
                fontSize: 10,
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
      key: ExpensesScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.account_balance_wallet_outlined,
            size: 56,
            color: context.hc.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'No expenses logged yet. Tap Add expense to start tracking '
            'what the care circle spends.',
            style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create-expense sheet
// ---------------------------------------------------------------------------

/// Bottom sheet that creates *or edits* an expense (TASKS.md Phase 14.33).
/// Collects an amount (required, parsed from dollars to cents), a kind, a
/// description (required), a paid date, a payer drawn from the care circle
/// (or "You"), and an optional receipt path. Save writes through the
/// [Expenses] notifier — which refreshes the ledger — then pops. When
/// [existing] is passed the fields seed from it and the save replaces it in
/// place (same id) via [Expenses.updateExpense].
class _CreateExpenseSheet extends ConsumerStatefulWidget {
  const _CreateExpenseSheet({this.existing});

  /// The expense being edited, or null when creating a new one.
  final Expense? existing;

  @override
  ConsumerState<_CreateExpenseSheet> createState() =>
      _CreateExpenseSheetState();
}

class _CreateExpenseSheetState extends ConsumerState<_CreateExpenseSheet> {
  late final TextEditingController _amount = TextEditingController(
      text: widget.existing == null
          ? ''
          : _dollarsFromCents(widget.existing!.amountCents));
  late final TextEditingController _description =
      TextEditingController(text: widget.existing?.description ?? '');
  late ExpenseKind _kind = widget.existing?.kind ?? ExpenseKind.meds;
  late DateTime? _paidAt = widget.existing?.paidAt;
  late String? _payerId = widget.existing?.paidByCaregiverId;

  /// On-disk pointer to the attached receipt image, or null when none is
  /// attached. Seeded from the edited expense; updated by [_pickReceipt].
  late String? _receiptPath = widget.existing?.receiptPath;
  String? _amountError;
  String? _descriptionError;
  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  /// Present the OS picker (camera + library) through the shared
  /// [photoAttacherProvider] — the same seam the journal entry's photo
  /// attach uses — and store the chosen path. No-op if the user cancels.
  Future<void> _pickReceipt() async {
    final PhotoAttacher picker = ref.read(photoAttacherProvider);
    final String? path = await picker.pickPhoto();
    if (!mounted || path == null) return;
    setState(() => _receiptPath = path);
  }

  DateTime get _effectivePaidAt =>
      _paidAt ?? ref.read(expensesClockProvider)();

  String get _effectivePayerId =>
      _payerId ?? ref.read(currentCaregiverIdProvider);

  Future<void> _pickDate() async {
    final DateTime now = ref.read(expensesClockProvider)();
    final DateTime base = _effectivePaidAt;
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (date == null || !mounted) return;
    setState(() => _paidAt = DateTime(date.year, date.month, date.day));
  }

  Future<void> _save() async {
    if (_submitting) return;
    final int? cents = parseAmountCents(_amount.text);
    final String description = _description.text.trim();

    String? amountError;
    String? descriptionError;
    if (cents == null || cents <= 0) {
      amountError = 'Enter an amount greater than zero.';
    }
    if (description.isEmpty) {
      descriptionError = 'Add a short description.';
    }
    if (amountError != null || descriptionError != null) {
      setState(() {
        _amountError = amountError;
        _descriptionError = descriptionError;
      });
      return;
    }

    setState(() {
      _submitting = true;
      _amountError = null;
      _descriptionError = null;
    });

    final String? receipt = _receiptPath?.trim();
    final Expense? existing = widget.existing;
    if (existing != null) {
      // Edit: keep the id (and currency) so the upsert replaces the same row.
      final Expense updated = existing.copyWith(
        amountCents: cents!,
        description: description,
        paidByCaregiverId: _effectivePayerId,
        paidAt: _effectivePaidAt,
        kind: _kind,
        receiptPath: (receipt == null || receipt.isEmpty) ? null : receipt,
      );
      await ref.read(expensesProvider.notifier).updateExpense(updated);
    } else {
      // A new expense is filed under the active loved one's id (was the
      // `expensesPatientId` const) so it follows whichever person is
      // selected (multi-patient, Issue #6). With one patient on file
      // [activePatientIdProvider] resolves to that sole id, identical to the
      // old const.
      final String patientId = await ref.read(activePatientIdProvider.future);
      final Expense expense = Expense(
        id: ref.read(expenseIdFactoryProvider)(),
        amountCents: cents!,
        description: description,
        paidByCaregiverId: _effectivePayerId,
        paidAt: _effectivePaidAt,
        kind: _kind,
        receiptPath: (receipt == null || receipt.isEmpty) ? null : receipt,
        patientId: patientId,
      );
      await ref.read(expensesProvider.notifier).addExpense(expense);
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final AsyncValue<List<Caregiver>> caregivers =
        ref.watch(expensePayerCandidatesProvider);
    final String me = ref.watch(currentCaregiverIdProvider);

    return Padding(
      key: ExpensesScreen.createSheetKey,
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
              _isEditing ? 'Edit expense' : 'New expense',
              style: textTheme.titleLarge
                  ?.copyWith(color: context.hc.primary),
            ),
            const SizedBox(height: 20),
            TextField(
              key: ExpensesScreen.amountFieldKey,
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: r'$ ',
                errorText: _amountError,
                errorMaxLines: 2,
              ),
            ),
            if (_amountError != null)
              Padding(
                key: ExpensesScreen.amountErrorKey,
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _amountError!,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: context.hc.error),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              key: ExpensesScreen.descriptionFieldKey,
              controller: _description,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Description',
                errorText: _descriptionError,
                errorMaxLines: 2,
              ),
            ),
            if (_descriptionError != null)
              Padding(
                key: ExpensesScreen.descriptionErrorKey,
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _descriptionError!,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: context.hc.error),
                ),
              ),
            const SizedBox(height: 20),
            Text(
              'Kind',
              style: textTheme.bodyLarge?.copyWith(
                color: context.hc.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final ExpenseKind kind in ExpenseKind.values)
                  _ChoicePill(
                    key: ExpensesScreen.kindOptionKey(kind),
                    label: kindLabel(kind),
                    selected: _kind == kind,
                    onTap: () => setState(() => _kind = kind),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _PaidDateRow(
              paidAt: _effectivePaidAt,
              onPick: _pickDate,
            ),
            const SizedBox(height: 20),
            Text(
              'Paid by',
              style: textTheme.bodyLarge?.copyWith(
                color: context.hc.primary,
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
                  _ChoicePill(
                    key: ExpensesScreen.payerOptionKey(me),
                    label: 'You',
                    selected: _effectivePayerId == me,
                    onTap: () => setState(() => _payerId = me),
                  ),
                  for (final Caregiver c in list)
                    if (c.id != me)
                      _ChoicePill(
                        key: ExpensesScreen.payerOptionKey(c.id),
                        label: c.displayName,
                        selected: _effectivePayerId == c.id,
                        onTap: () => setState(() => _payerId = c.id),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Receipt (optional)',
              style: textTheme.bodyLarge?.copyWith(
                color: context.hc.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            _ReceiptRow(path: _receiptPath, onPick: _pickReceipt),
            const SizedBox(height: 28),
            ElevatedButton(
              key: ExpensesScreen.saveButtonKey,
              onPressed: _submitting ? null : _save,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: context.hc.cta,
                foregroundColor: Colors.white,
              ),
              child: Text(
                _submitting
                    ? 'Saving…'
                    : (_isEditing ? 'Save changes' : 'Add expense'),
                style: textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Render integer [cents] as a plain editable dollar string for the amount
/// field when seeding the edit sheet — "1299" → "12.99", "1000" → "10.00".
/// No currency symbol or grouping (the field strips those anyway).
String _dollarsFromCents(int cents) {
  final int dollars = cents ~/ 100;
  final String fraction = (cents % 100).toString().padLeft(2, '0');
  return '$dollars.$fraction';
}

class _PaidDateRow extends StatelessWidget {
  const _PaidDateRow({required this.paidAt, required this.onPick});

  final DateTime paidAt;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Paid on ${formatMonthDayYear(paidAt)}. Change the paid date.',
      child: OutlinedButton.icon(
        key: ExpensesScreen.paidDateButtonKey,
        onPressed: onPick,
        icon: Icon(Icons.event_outlined, color: context.hc.link),
        label: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Paid ${formatMonthDayYear(paidAt)}',
            style: textTheme.labelLarge?.copyWith(color: context.hc.link),
          ),
        ),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: context.hc.primarySoft),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        ),
      ),
    );
  }
}

/// Pick-or-replace affordance for the grocery / care receipt photo. Mirrors
/// the journal entry's `_PhotoRow`: an outlined "Attach receipt" /
/// "Replace receipt" button next to a thumbnail once a path is set. The
/// underlying picker is the shared [photoAttacherProvider] seam.
class _ReceiptRow extends StatefulWidget {
  const _ReceiptRow({required this.path, required this.onPick});

  final String? path;
  final VoidCallback onPick;

  @override
  State<_ReceiptRow> createState() => _ReceiptRowState();
}

class _ReceiptRowState extends State<_ReceiptRow> {
  /// Whether [_ReceiptRow.path] points at a real file — resolved once
  /// per path (initState / attach / replace) instead of stat-ing the
  /// filesystem on every build.
  bool _hasPhoto = false;

  @override
  void initState() {
    super.initState();
    _resolvePhoto();
  }

  @override
  void didUpdateWidget(_ReceiptRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _resolvePhoto();
  }

  void _resolvePhoto() {
    final String? path = widget.path;
    _hasPhoto = path != null && File(path).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String? path = widget.path;
    final bool hasPhoto = _hasPhoto;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        OutlinedButton.icon(
          key: ExpensesScreen.receiptButtonKey,
          onPressed: widget.onPick,
          icon: Icon(
            Icons.photo_camera_outlined,
            color: context.hc.primary,
          ),
          label: Text(
            path == null ? 'Attach receipt' : 'Replace receipt',
            style: textTheme.labelLarge?.copyWith(color: context.hc.primary),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.hc.primary),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        if (path != null) ...<Widget>[
          const SizedBox(width: 12),
          Container(
            key: ExpensesScreen.receiptThumbnailKey,
            width: 56,
            height: 56,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: context.hc.surfaceWarm,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: context.hc.primarySoft.withValues(alpha: 0.3),
              ),
            ),
            child: hasPhoto
                ? Image.file(File(path), fit: BoxFit.cover)
                : Icon(
                    Icons.receipt_long_outlined,
                    color: context.hc.primarySoft,
                  ),
          ),
        ],
      ],
    );
  }
}

class _ChoicePill extends StatelessWidget {
  const _ChoicePill({
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
        selected ? context.hc.cta : context.hc.primarySoft;
    final Color fill = selected
        ? context.hc.cta.withValues(alpha: 0.12)
        : Colors.transparent;
    final Color fg = selected ? context.hc.cta : context.hc.text;
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The `YYYY-MM` key for [date] — the bucket the ledger groups by.
String monthKeyOf(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}';

const List<String> _monthsLong = <String>[
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "June 2026" from a `YYYY-MM` key. Falls back to the raw key if it can't
/// be parsed (defensive — every stored key is well-formed).
String monthLabel(String monthKey) {
  final List<String> parts = monthKey.split('-');
  if (parts.length != 2) return monthKey;
  final int? year = int.tryParse(parts[0]);
  final int? month = int.tryParse(parts[1]);
  if (year == null || month == null || month < 1 || month > 12) {
    return monthKey;
  }
  return '${_monthsLong[month - 1]} $year';
}

/// Format integer [cents] as money in [currency]. USD renders with a `$`
/// and thousands separators ("$1,234.56"); any other currency prefixes its
/// code ("EUR 12.34"). Negative inputs aren't expected, so this assumes a
/// non-negative amount.
String formatMoney(int cents, String currency) {
  final int dollars = cents ~/ 100;
  final int remainder = cents % 100;
  final String grouped = _withThousands(dollars);
  final String fraction = remainder.toString().padLeft(2, '0');
  if (currency == 'USD') {
    return '\$$grouped.$fraction';
  }
  return '$currency $grouped.$fraction';
}

String _withThousands(int value) {
  final String digits = value.toString();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// Parse a user-typed dollar amount ("12", "12.5", "1,234.56") into integer
/// cents. Returns null when the text isn't a parseable non-negative number.
int? parseAmountCents(String raw) {
  final String cleaned = raw.replaceAll(',', '').replaceAll(r'$', '').trim();
  if (cleaned.isEmpty) return null;
  final double? dollars = double.tryParse(cleaned);
  if (dollars == null || dollars.isNaN || dollars.isInfinite || dollars < 0) {
    return null;
  }
  return (dollars * 100).round();
}

/// The currency to show on the sticky total — the most recent expense's, or
/// USD when the ledger is empty.
String _ledgerCurrency(List<ExpenseMonthGroup> groups) {
  for (final ExpenseMonthGroup g in groups) {
    if (g.rows.isNotEmpty) return g.rows.first.expense.currency;
  }
  return 'USD';
}

/// Human label for an [ExpenseKind] chip.
String kindLabel(ExpenseKind kind) {
  switch (kind) {
    case ExpenseKind.meds:
      return 'Meds';
    case ExpenseKind.groceries:
      return 'Groceries';
    case ExpenseKind.transport:
      return 'Transport';
    case ExpenseKind.equipment:
      return 'Equipment';
    case ExpenseKind.aide:
      return 'Aide';
    case ExpenseKind.other:
      return 'Other';
  }
}

/// Glyph for an [ExpenseKind] chip.
IconData kindIcon(ExpenseKind kind) {
  switch (kind) {
    case ExpenseKind.meds:
      return Icons.medication_outlined;
    case ExpenseKind.groceries:
      return Icons.local_grocery_store_outlined;
    case ExpenseKind.transport:
      return Icons.directions_car_outlined;
    case ExpenseKind.equipment:
      return Icons.medical_services_outlined;
    case ExpenseKind.aide:
      return Icons.volunteer_activism_outlined;
    case ExpenseKind.other:
      return Icons.receipt_outlined;
  }
}

/// Up to two uppercase initials from [name]; falls back to `?` for an empty
/// name. Mirrors the task-board + care-circle roster helper.
String initials(String name) {
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
