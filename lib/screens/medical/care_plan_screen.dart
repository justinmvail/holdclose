import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/care_plan_section.dart';
import '../../providers/care_plan_provider.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Which stage the Care Plan screen's segmented control is filtering by
/// (BUILD_SPEC.md §5.13, TASKS.md Phase 14.19).
///
/// [all] shows every section. A specific-stage filter shows sections
/// tagged for that stage AND sections tagged [CareStage.anyStage] — the
/// "any stage" guidance applies in every stage by definition, so it must
/// stay visible whichever stage the caregiver is looking at (there's no
/// "Any" segment to surface it on its own).
enum CarePlanStageFilter { all, early, middle, late }

/// The slots, top-to-bottom, the way the daily routine reads. Mirrors the
/// declaration order in [CarePlanSlot] but pinned here so the screen's
/// grouping never depends on enum-declaration accidents.
const List<CarePlanSlot> _slotOrder = <CarePlanSlot>[
  CarePlanSlot.morning,
  CarePlanSlot.afternoon,
  CarePlanSlot.evening,
  CarePlanSlot.night,
  CarePlanSlot.asNeeded,
];

/// Care Plan screen at `/medical/care-plan` (BUILD_SPEC.md §5.13, TASKS.md
/// Phase 14.19).
///
/// A [PathHeader] (`Home › Medical › Care Plan`, back to Medical) sits
/// above a segmented control (All / Early / Middle / Late) that filters
/// which sections show. The body groups the visible sections by [slot]
/// (Morning → Afternoon → Evening → Night → As needed) and renders each
/// section as a card with its title, the markdown [CarePlanSection.body],
/// and a stage chip. Long-press a card to reorder within its slot; tap a
/// card to edit it (pushed form); the FAB adds a new section.
///
/// The screen reads through the [carePlanProvider] notifier and never
/// touches the database directly — a save / edit / delete / reorder from
/// the form (or the reorder gesture here) reflects without a manual
/// invalidate. This is an organisational routine, not a clinical plan:
/// nothing here diagnoses, prescribes, or stages the condition.
class CarePlanScreen extends ConsumerStatefulWidget {
  const CarePlanScreen({super.key});

  static const Key listKey = Key('care-plan-list');
  static const Key emptyStateKey = Key('care-plan-empty');
  static const Key emptyCtaKey = Key('care-plan-empty-cta');
  static const Key noMatchKey = Key('care-plan-no-match');
  static const Key fabKey = Key('care-plan-fab');
  static const Key segmentedKey = Key('care-plan-stage-filter');

  /// Stable per-slot header + list keys so tests assert grouping by slot
  /// rather than by visible copy.
  static Key slotHeaderKey(CarePlanSlot slot) =>
      Key('care-plan-slot-header-${slot.name}');
  static Key slotListKey(CarePlanSlot slot) =>
      Key('care-plan-slot-list-${slot.name}');

  /// Stable per-card key derived from the section id. Tests tap by id so a
  /// copy edit doesn't break them; the [ReorderableListView] also needs a
  /// key per child.
  static Key cardKey(String sectionId) => Key('care-plan-card-$sectionId');

  @override
  ConsumerState<CarePlanScreen> createState() => _CarePlanScreenState();
}

class _CarePlanScreenState extends ConsumerState<CarePlanScreen> {
  CarePlanStageFilter _filter = CarePlanStageFilter.all;

  void _setFilter(CarePlanStageFilter filter) {
    if (filter == _filter) return;
    setState(() => _filter = filter);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<CarePlanSection>> async =
        ref.watch(carePlanProvider);

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
                  PathHeaderCrumb(label: 'Care Plan'),
                ],
                title: 'Care Plan',
                backLabel: 'Back to Medical',
                leadingIcon: Icons.assignment_outlined,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _StageFilterControl(
                selected: _filter,
                onChanged: _setFilter,
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const SizedBox.shrink(),
                error: (Object e, StackTrace _) => _ErrorView(message: '$e'),
                data: (List<CarePlanSection> sections) {
                  if (sections.isEmpty) return const _EmptyState();
                  final List<CarePlanSection> visible = sections
                      .where((CarePlanSection s) =>
                          _matchesFilter(s, _filter))
                      .toList();
                  if (visible.isEmpty) return const _NoMatch();
                  return _GroupedList(sections: visible);
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: async.maybeWhen(
        data: (List<CarePlanSection> sections) {
          if (sections.isEmpty) return null;
          return _AddSectionFab(
            onPressed: () => context.push('/medical/care-plan/new'),
          );
        },
        orElse: () => null,
      ),
    );
  }
}

/// True when [section] should be visible under [filter]. See
/// [CarePlanStageFilter] for the any-stage rule.
bool _matchesFilter(CarePlanSection section, CarePlanStageFilter filter) {
  switch (filter) {
    case CarePlanStageFilter.all:
      return true;
    case CarePlanStageFilter.early:
      return section.appliesInStage == CareStage.early ||
          section.appliesInStage == CareStage.anyStage;
    case CarePlanStageFilter.middle:
      return section.appliesInStage == CareStage.middle ||
          section.appliesInStage == CareStage.anyStage;
    case CarePlanStageFilter.late:
      return section.appliesInStage == CareStage.late ||
          section.appliesInStage == CareStage.anyStage;
  }
}

/// Standard [ReorderableListView] index fix-up applied as a pure function
/// so the reorder wiring can be unit-tested without a flaky drag gesture.
/// Returns [ids] with the element at [oldIndex] moved to [newIndex] using
/// the framework's "decrement newIndex when moving down" convention.
List<String> carePlanReorderedIds(
  List<String> ids,
  int oldIndex,
  int newIndex,
) {
  final List<String> next = List<String>.of(ids);
  int target = newIndex;
  if (target > oldIndex) target -= 1;
  final String moved = next.removeAt(oldIndex);
  next.insert(target, moved);
  return next;
}

class _StageFilterControl extends StatelessWidget {
  const _StageFilterControl({required this.selected, required this.onChanged});

  final CarePlanStageFilter selected;
  final ValueChanged<CarePlanStageFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<CarePlanStageFilter>(
      key: CarePlanScreen.segmentedKey,
      showSelectedIcon: false,
      segments: const <ButtonSegment<CarePlanStageFilter>>[
        ButtonSegment<CarePlanStageFilter>(
          value: CarePlanStageFilter.all,
          label: Text('All'),
        ),
        ButtonSegment<CarePlanStageFilter>(
          value: CarePlanStageFilter.early,
          label: Text('Early'),
        ),
        ButtonSegment<CarePlanStageFilter>(
          value: CarePlanStageFilter.middle,
          label: Text('Middle'),
        ),
        ButtonSegment<CarePlanStageFilter>(
          value: CarePlanStageFilter.late,
          label: Text('Late'),
        ),
      ],
      selected: <CarePlanStageFilter>{selected},
      onSelectionChanged: (Set<CarePlanStageFilter> s) => onChanged(s.first),
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _GroupedList extends ConsumerWidget {
  const _GroupedList({required this.sections});

  /// Already filtered to the visible stage; still spans every slot.
  final List<CarePlanSection> sections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Widget> children = <Widget>[];
    for (final CarePlanSlot slot in _slotOrder) {
      final List<CarePlanSection> slotSections = sections
          .where((CarePlanSection s) => s.slot == slot)
          .toList()
        ..sort((CarePlanSection a, CarePlanSection b) =>
            a.order.compareTo(b.order));
      if (slotSections.isEmpty) continue;
      children.add(_SlotHeader(slot: slot));
      children.add(_SlotSections(slot: slot, sections: slotSections));
    }
    return ListView(
      key: CarePlanScreen.listKey,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: children,
    );
  }
}

class _SlotHeader extends StatelessWidget {
  const _SlotHeader({required this.slot});

  final CarePlanSlot slot;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: CarePlanScreen.slotHeaderKey(slot),
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        _slotLabel(slot),
        style: textTheme.titleLarge?.copyWith(
          color: careblazersColors.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The reorderable run of cards within one slot. Long-press a card to
/// start the drag; the reorder is constrained to this slot's list, so a
/// section can never jump slots by dragging (changing slot is an edit, in
/// the form). Shrink-wrapped + non-scrolling so it nests inside the outer
/// [ListView].
class _SlotSections extends ConsumerWidget {
  const _SlotSections({required this.slot, required this.sections});

  final CarePlanSlot slot;
  final List<CarePlanSection> sections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView.builder(
      key: CarePlanScreen.slotListKey(slot),
      shrinkWrap: true,
      primary: false,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: true,
      itemCount: sections.length,
      onReorder: (int oldIndex, int newIndex) {
        final List<String> ids =
            sections.map((CarePlanSection s) => s.id).toList();
        final List<String> reordered =
            carePlanReorderedIds(ids, oldIndex, newIndex);
        ref.read(carePlanProvider.notifier).reorder(slot, reordered);
      },
      itemBuilder: (BuildContext context, int index) {
        final CarePlanSection section = sections[index];
        return _SectionCard(
          key: CarePlanScreen.cardKey(section.id),
          section: section,
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({super.key, required this.section});

  final CarePlanSection section;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: '${section.title}. ${_stageLabel(section.appliesInStage)}. '
            'Double-tap to edit. Long-press to reorder.',
        child: Material(
          color: careblazersColors.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () =>
                context.push('/medical/care-plan/${section.id}/edit'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          section.title,
                          style: textTheme.titleLarge?.copyWith(
                            color: careblazersColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _StageChip(stage: section.appliesInStage),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _MarkdownBody(data: section.body),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StageChip extends StatelessWidget {
  const _StageChip({required this.stage});

  final CareStage stage;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color color = _stageColor(stage);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _stageLabel(stage),
        style: textTheme.bodyMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AddSectionFab extends StatelessWidget {
  const _AddSectionFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add a section. Open the new care-plan section form.',
      child: FloatingActionButton.extended(
        key: CarePlanScreen.fabKey,
        onPressed: onPressed,
        backgroundColor: careblazersColors.cta,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(
          'Add section',
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Colors.white),
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
      key: CarePlanScreen.emptyStateKey,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.assignment_outlined,
            size: 56,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'No care plan yet.',
            style: textTheme.headlineMedium?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "Capture what works for your loved one's day — the morning "
            'routine, what calms the evenings, the little things that help. '
            'Group it by time of day and tag the stage it fits.',
            style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'Add a section. Open the new care-plan section form.',
            child: ElevatedButton.icon(
              key: CarePlanScreen.emptyCtaKey,
              onPressed: () => context.push('/medical/care-plan/new'),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                'Add a section',
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

class _NoMatch extends StatelessWidget {
  const _NoMatch();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      key: CarePlanScreen.noMatchKey,
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            Icons.filter_alt_off_outlined,
            size: 48,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 16),
          Text(
            'Nothing tagged for this stage yet.',
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Switch back to All to see every section, or add one for this '
            'stage.',
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.primarySoft,
            ),
            textAlign: TextAlign.center,
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
          "We couldn't load the care plan.\n$message",
          style: textTheme.bodyLarge?.copyWith(color: careblazersColors.text),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Minimal markdown rendering
// ---------------------------------------------------------------------------

/// Renders the small subset of markdown the care-plan body uses — headings
/// (`#`/`##`/`###`), bullet lines (`- ` / `* `), and inline `**bold**` /
/// `_italic_` — into brand-styled text. No package dependency: the body
/// is short caregiver-authored prose, not arbitrary documents, so a tiny
/// line-oriented renderer covers it without pulling `flutter_markdown`.
class _MarkdownBody extends StatelessWidget {
  const _MarkdownBody({required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final TextStyle bodyStyle = (textTheme.bodyLarge ?? const TextStyle())
        .copyWith(color: careblazersColors.text);
    final List<Widget> blocks = <Widget>[];

    final List<String> lines = data.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final String raw = lines[i];
      final String line = raw.trimRight();
      final String trimmed = line.trimLeft();
      if (trimmed.isEmpty) {
        if (blocks.isNotEmpty) blocks.add(const SizedBox(height: 8));
        continue;
      }

      // Headings.
      final RegExpMatch? heading =
          RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        final int level = heading.group(1)!.length;
        final TextStyle headingStyle = (level == 1
                ? textTheme.titleLarge
                : textTheme.bodyLarge)
            ?.copyWith(
              color: careblazersColors.primary,
              fontWeight: FontWeight.w700,
            ) ??
            bodyStyle;
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text.rich(_inlineSpans(heading.group(2)!, headingStyle)),
        ));
        continue;
      }

      // Bullets.
      final RegExpMatch? bullet =
          RegExp(r'^[-*]\s+(.*)$').firstMatch(trimmed);
      if (bullet != null) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('•  ', style: bodyStyle),
              Expanded(
                child: Text.rich(_inlineSpans(bullet.group(1)!, bodyStyle)),
              ),
            ],
          ),
        ));
        continue;
      }

      // Paragraph.
      blocks.add(Text.rich(_inlineSpans(trimmed, bodyStyle)));
    }

    if (blocks.isEmpty) {
      return Text(data, style: bodyStyle);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }
}

/// Tokenise [text] into bold/italic spans. `**` toggles bold, `_` toggles
/// italic; unbalanced markers just leave the toggle on for the remainder
/// (acceptable for short prose). All spans inherit [base].
TextSpan _inlineSpans(String text, TextStyle base) {
  final List<TextSpan> spans = <TextSpan>[];
  final StringBuffer buffer = StringBuffer();
  bool bold = false;
  bool italic = false;

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(
      text: buffer.toString(),
      style: base.copyWith(
        fontWeight: bold ? FontWeight.w700 : base.fontWeight,
        fontStyle: italic ? FontStyle.italic : base.fontStyle,
      ),
    ));
    buffer.clear();
  }

  int i = 0;
  while (i < text.length) {
    if (i + 1 < text.length && text[i] == '*' && text[i + 1] == '*') {
      flush();
      bold = !bold;
      i += 2;
      continue;
    }
    if (text[i] == '_') {
      flush();
      italic = !italic;
      i += 1;
      continue;
    }
    buffer.write(text[i]);
    i++;
  }
  flush();
  return TextSpan(children: spans);
}

// ---------------------------------------------------------------------------
// Labels + colors
// ---------------------------------------------------------------------------

String _slotLabel(CarePlanSlot slot) {
  switch (slot) {
    case CarePlanSlot.morning:
      return 'Morning';
    case CarePlanSlot.afternoon:
      return 'Afternoon';
    case CarePlanSlot.evening:
      return 'Evening';
    case CarePlanSlot.night:
      return 'Night';
    case CarePlanSlot.asNeeded:
      return 'As needed';
  }
}

String _stageLabel(CareStage stage) {
  switch (stage) {
    case CareStage.early:
      return 'Early';
    case CareStage.middle:
      return 'Middle';
    case CareStage.late:
      return 'Late';
    case CareStage.anyStage:
      return 'Any stage';
  }
}

Color _stageColor(CareStage stage) {
  switch (stage) {
    case CareStage.early:
      return careblazersColors.success;
    case CareStage.middle:
      return careblazersColors.link;
    case CareStage.late:
      return careblazersColors.accentDeep;
    case CareStage.anyStage:
      return careblazersColors.primarySoft;
  }
}
