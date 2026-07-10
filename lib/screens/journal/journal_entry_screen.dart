import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/journal_entry.dart';
import '../../providers/journal_entries_provider.dart';
import '../../providers/photo_attacher_provider.dart';
import '../../providers/storage_provider.dart';
import '../../providers/voice_note_recorder_provider.dart';
import '../../theme.dart';
import '../../widgets/form/format.dart';
import '../../widgets/path_header.dart';

/// Journal entry detail (BUILD_SPEC.md §5.6).
///
/// Reads via [journalEntryByIdProvider] so a save round-trips through
/// the same drift watch the journal list reads from — no manual
/// invalidate. Local form state (notes, voice path, photo path) hydrates
/// once on first non-null emission so subsequent re-emits from the
/// storage stream don't clobber the in-flight editor.
class JournalEntryScreen extends ConsumerStatefulWidget {
  const JournalEntryScreen({super.key, required this.entryId});

  final String entryId;

  static const Key kebabMenuKey = Key('journal-entry-kebab-menu');
  static const Key deleteMenuItemKey = Key('journal-entry-delete-menu-item');
  static const Key deleteConfirmKey = Key('journal-entry-delete-confirm');
  static const Key deleteCancelKey = Key('journal-entry-delete-cancel');
  static const Key notesFieldKey = Key('journal-entry-notes-field');
  static const Key saveButtonKey = Key('journal-entry-save');
  static const Key recordButtonKey = Key('journal-entry-record');
  static const Key playVoiceButtonKey = Key('journal-entry-play-voice');
  static const Key voiceChipKey = Key('journal-entry-voice-chip');
  static const Key photoButtonKey = Key('journal-entry-photo');
  static const Key photoThumbnailKey = Key('journal-entry-photo-thumb');
  static const Key situationSectionKey = Key('journal-entry-situation');
  static const Key attemptsSectionKey = Key('journal-entry-attempts');
  static const Key notFoundKey = Key('journal-entry-not-found');

  @override
  ConsumerState<JournalEntryScreen> createState() =>
      _JournalEntryScreenState();
}

class _JournalEntryScreenState extends ConsumerState<JournalEntryScreen> {
  final TextEditingController _notesController = TextEditingController();
  String? _voiceNotePath;
  String? _photoPath;
  bool _hydrated = false;
  bool _recording = false;

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _hydrateFrom(JournalEntry entry) {
    if (_hydrated) return;
    _hydrated = true;
    _notesController.text = entry.notes ?? '';
    _voiceNotePath = entry.voiceNotePath;
    _photoPath = entry.photoPath;
  }

  Future<void> _save(JournalEntry source) async {
    final StorageProvider storage = ref.read(storageProvider);
    final String trimmed = _notesController.text;
    final JournalEntry updated = source.copyWith(
      notes: trimmed.isEmpty ? null : trimmed,
      voiceNotePath: _voiceNotePath,
      photoPath: _photoPath,
    );
    await storage.updateJournalEntry(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved.')),
    );
  }

  Future<void> _toggleRecording() async {
    final VoiceNoteRecorder recorder = ref.read(voiceNoteRecorderProvider);
    if (_recording) {
      final String? path = await recorder.stop();
      if (!mounted) return;
      setState(() {
        _recording = false;
        if (path != null) _voiceNotePath = path;
      });
    } else {
      await recorder.start();
      if (!mounted) return;
      setState(() => _recording = true);
    }
  }

  Future<void> _playVoice() async {
    final String? path = _voiceNotePath;
    if (path == null) return;
    final VoiceNoteRecorder recorder = ref.read(voiceNoteRecorderProvider);
    await recorder.play(path);
  }

  Future<void> _pickPhoto() async {
    final PhotoAttacher picker = ref.read(photoAttacherProvider);
    final String? path = await picker.pickPhoto();
    if (!mounted) return;
    if (path != null) {
      setState(() => _photoPath = path);
    }
  }

  Future<void> _confirmDelete() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete this entry?'),
        content: const Text(
          "You can't undo this. This entry and any notes, voice "
          'memo, or photo will be removed.',
        ),
        actions: <Widget>[
          TextButton(
            key: JournalEntryScreen.deleteCancelKey,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: JournalEntryScreen.deleteConfirmKey,
            style: TextButton.styleFrom(
              foregroundColor: context.hc.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final StorageProvider storage = ref.read(storageProvider);
    await storage.deleteJournalEntry(widget.entryId);
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/journal');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<JournalEntry?> entryAsync =
        ref.watch(journalEntryByIdProvider(widget.entryId));

    return entryAsync.when(
      loading: () => Scaffold(
        backgroundColor: context.hc.background,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: const <Widget>[
              _EntryPathHeader(),
            ],
          ),
        ),
      ),
      error: (Object error, StackTrace _) => Scaffold(
        backgroundColor: context.hc.background,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: <Widget>[
              const _EntryPathHeader(),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  "We couldn't load this entry.\n$error",
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
      data: (JournalEntry? entry) {
        if (entry == null) {
          return Scaffold(
            backgroundColor: context.hc.background,
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: <Widget>[
                  const _EntryPathHeader(),
                  const SizedBox(height: 24),
                  Center(
                    key: JournalEntryScreen.notFoundKey,
                    child: Text(
                      "This entry isn't here anymore.",
                      style: Theme.of(context).textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        _hydrateFrom(entry);
        return _buildContent(context, entry);
      },
    );
  }

  Widget _buildContent(BuildContext context, JournalEntry entry) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: context.hc.background,
      appBar: AppBar(
        // The title + labeled Back control live in the body PathHeader;
        // this bar only hosts the kebab action (and suppresses the auto
        // back-arrow).
        automaticallyImplyLeading: false,
        backgroundColor: context.hc.background,
        elevation: 0,
        actions: <Widget>[
          PopupMenuButton<String>(
            key: JournalEntryScreen.kebabMenuKey,
            icon: const Icon(Icons.more_vert),
            tooltip: 'More actions',
            onSelected: (String value) {
              if (value == 'delete') unawaited(_confirmDelete());
            },
            itemBuilder: (BuildContext _) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                key: JournalEntryScreen.deleteMenuItemKey,
                value: 'delete',
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.delete_outline,
                      color: context.hc.error,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Delete',
                      style: TextStyle(color: context.hc.error),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: <Widget>[
            _EntryPathHeader(title: _formatHeaderDateTime(entry.createdAt)),
            const SizedBox(height: 20),
            if (_clean(entry.situationText) case final String situation) ...<Widget>[
              const _SectionHeader(label: 'What happened'),
              const SizedBox(height: 8),
              _ReadOnlyBlock(
                blockKey: JournalEntryScreen.situationSectionKey,
                text: situation,
              ),
              const SizedBox(height: 24),
            ],
            if (_clean(entry.attemptsText) case final String attempts) ...<Widget>[
              const _SectionHeader(label: 'What you tried'),
              const SizedBox(height: 8),
              _ReadOnlyBlock(
                blockKey: JournalEntryScreen.attemptsSectionKey,
                text: attempts,
              ),
              const SizedBox(height: 24),
            ],
            const _SectionHeader(label: 'Notes'),
            const SizedBox(height: 8),
            TextField(
              key: JournalEntryScreen.notesFieldKey,
              controller: _notesController,
              textCapitalization: TextCapitalization.sentences,
              minLines: 3,
              maxLines: 6,
              style: textTheme.bodyLarge?.copyWith(
                color: context.hc.text,
              ),
              decoration: InputDecoration(
                hintText: 'What happened? What helped?',
                filled: true,
                fillColor: context.hc.surfaceWarm,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 24),
            const _SectionHeader(label: 'Voice note'),
            const SizedBox(height: 8),
            _VoiceNoteRow(
              path: _voiceNotePath,
              recording: _recording,
              onToggleRecord: _toggleRecording,
              onPlay: _playVoice,
            ),
            const SizedBox(height: 24),
            const _SectionHeader(label: 'Photo'),
            const SizedBox(height: 8),
            _PhotoRow(path: _photoPath, onPick: _pickPhoto),
            const SizedBox(height: 32),
            ElevatedButton(
              key: JournalEntryScreen.saveButtonKey,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.hc.ctaFilled,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: () => _save(entry),
              child: Text(
                'Save',
                style: textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section pieces
// ---------------------------------------------------------------------------

/// Shared [PathHeader] for every async branch of the entry detail. The
/// `Home › Medical › Journal › Entry` trail runs through the Medical hub
/// (Journal is a top-level route reached from the Medical hub's Journal
/// tile). The [title] is the formatted entry date/time on the data path
/// and a plain "Entry" on the loading / error / not-found branches.
class _EntryPathHeader extends StatelessWidget {
  const _EntryPathHeader({this.title = 'Entry'});

  final String title;

  @override
  Widget build(BuildContext context) {
    return PathHeader(
      breadcrumbs: const <PathHeaderCrumb>[
        PathHeaderCrumb(label: 'Home', route: '/'),
        PathHeaderCrumb(label: 'Care', route: '/medical'),
        PathHeaderCrumb(label: 'Journal', route: '/journal'),
        PathHeaderCrumb(label: 'Entry'),
      ],
      title: title,
      backLabel: 'Back to Journal',
      leadingIcon: Icons.book_outlined,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Text(
      label,
      style: textTheme.titleLarge?.copyWith(
        color: context.hc.primary,
      ),
    );
  }
}

/// Read-only display of a caregiver-authored field (the situation or the
/// attempts text) on the entry detail screen.
class _ReadOnlyBlock extends StatelessWidget {
  const _ReadOnlyBlock({required this.blockKey, required this.text});

  final Key blockKey;
  final String text;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: blockKey,
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.hc.surfaceWarm,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        style: textTheme.bodyLarge?.copyWith(
          color: context.hc.text,
        ),
      ),
    );
  }
}

class _VoiceNoteRow extends StatelessWidget {
  const _VoiceNoteRow({
    required this.path,
    required this.recording,
    required this.onToggleRecord,
    required this.onPlay,
  });

  final String? path;
  final bool recording;
  final VoidCallback onToggleRecord;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        OutlinedButton.icon(
          key: JournalEntryScreen.recordButtonKey,
          onPressed: onToggleRecord,
          icon: Icon(
            recording ? Icons.stop_circle_outlined : Icons.mic_none,
            color: recording
                ? context.hc.accentDeep
                : context.hc.primary,
          ),
          label: Text(
            recording ? 'Stop recording' : 'Record voice note',
            style: textTheme.labelLarge?.copyWith(
              color: recording
                  ? context.hc.accentDeep
                  : context.hc.primary,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(
              color: recording
                  ? context.hc.accentDeep
                  : context.hc.primary,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        if (path != null) ...<Widget>[
          const SizedBox(width: 12),
          IconButton(
            key: JournalEntryScreen.playVoiceButtonKey,
            icon: Icon(Icons.play_arrow, color: context.hc.cta),
            tooltip: 'Play voice note',
            onPressed: onPlay,
          ),
          Flexible(
            child: Padding(
              key: JournalEntryScreen.voiceChipKey,
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '🔊 attached',
                style: textTheme.bodyMedium?.copyWith(
                  color: context.hc.primarySoft,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PhotoRow extends StatelessWidget {
  const _PhotoRow({required this.path, required this.onPick});

  final String? path;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        OutlinedButton.icon(
          key: JournalEntryScreen.photoButtonKey,
          onPressed: onPick,
          icon: Icon(
            Icons.photo_camera_outlined,
            color: context.hc.primary,
          ),
          label: Text(
            path == null ? 'Attach photo' : 'Replace photo',
            style: textTheme.labelLarge?.copyWith(
              color: context.hc.primary,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: context.hc.primary),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        if (path != null) ...<Widget>[
          const SizedBox(width: 12),
          Container(
            key: JournalEntryScreen.photoThumbnailKey,
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: context.hc.surfaceWarm,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: context.hc.primarySoft.withValues(alpha: 0.3),
              ),
            ),
            child: Icon(
              Icons.image_outlined,
              color: context.hc.primarySoft,
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _formatHeaderDateTime(DateTime t) =>
    '${monthAbbreviations[t.month - 1]} ${t.day} · ${formatClock12h(t)}';

/// Trimmed text, or null when the field is null/blank — lets the detail
/// body use a `case final String` pattern to drop empty sections.
String? _clean(String? raw) {
  final String? trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
