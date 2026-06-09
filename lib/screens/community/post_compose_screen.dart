import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/forum.dart';
import '../../providers/community_feed_provider.dart';
import '../../providers/guidelines_acknowledged_provider.dart';
import '../../routing/router.dart' show CareblazersRoutes;
import '../../seed/community_guidelines.dart';
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/form_validation.dart';
import '../../widgets/path_header.dart';
import 'community_guidelines_screen.dart';

/// Caps mirror BUILD_SPEC.md §13's Worker-side validation (Phase 13.5
/// `posts.ts`). The client enforces them inline so the counter rejects
/// the keystroke before the user ever sees a 400 — same UX as a paper
/// form clipping at the page boundary.
const int postComposeTitleMaxChars = 200;
const int postComposeBodyMaxChars = 4000;

/// New-post compose screen at `/community/compose` (BUILD_SPEC.md §13 /
/// Phase 13.12).
///
/// Layout:
///   * Two stacked TextFormFields — title (single line, 200 cap) and
///     body (multi-line, 4000 cap), each with a live counter that
///     turns warm when the user is within 40 chars of the cap.
///   * A "Read community guidelines" link that pushes
///     [CommunityGuidelinesScreen] without dismissing the draft.
///   * A primary submit button. First press by a caregiver who hasn't
///     acknowledged the guidelines opens the [_FirstPostAckSheet]; the
///     draft survives the modal so they don't retype on accept.
///
/// On success the screen pops back to the community feed with a
/// SnackBar; on crisis-flag the SnackBar carries the hotline banner
/// the post detail screen also uses. Errors stay inline so the body
/// text isn't lost to a tap-out.
class PostComposeScreen extends ConsumerStatefulWidget {
  const PostComposeScreen({super.key, this.editPost});

  /// When non-null the screen is in EDIT mode: the fields prefill from this
  /// post, the title field locks (the Worker's `PATCH /posts/:id` only
  /// accepts a new body), and Submit calls [ForumApiClient.updatePost]
  /// instead of `createPost`, popping back to the post on success. Null is
  /// the original new-post compose flow.
  final ForumPost? editPost;

  static const Key titleFieldKey = Key('post-compose-title');
  static const Key bodyFieldKey = Key('post-compose-body');
  static const Key titleCounterKey = Key('post-compose-title-counter');
  static const Key bodyCounterKey = Key('post-compose-body-counter');
  static const Key guidelinesLinkKey = Key('post-compose-guidelines-link');
  static const Key submitButtonKey = Key('post-compose-submit');
  static const Key errorBannerKey = Key('post-compose-error');
  static const Key ackSheetKey = Key('post-compose-ack-sheet');
  static const Key ackAcceptKey = Key('post-compose-ack-accept');
  static const Key ackCancelKey = Key('post-compose-ack-cancel');

  @override
  ConsumerState<PostComposeScreen> createState() => _PostComposeScreenState();
}

class _PostComposeScreenState extends ConsumerState<PostComposeScreen> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _submitting = false;
  String? _errorMessage;

  /// True when the screen was opened to edit an existing post.
  bool get _isEdit => widget.editPost != null;

  @override
  void initState() {
    super.initState();
    // Edit mode: prefill from the post being edited so the caregiver tweaks
    // the existing text rather than retyping it.
    final ForumPost? editing = widget.editPost;
    if (editing != null) {
      _titleController.text = editing.title;
      _bodyController.text = editing.body;
    }
    _titleController.addListener(_onTextChanged);
    _bodyController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _titleController.removeListener(_onTextChanged);
    _bodyController.removeListener(_onTextChanged);
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _submit() async {
    if (_submitting) return;
    // Validate on press (the button is always tappable) and highlight +
    // scroll to the first empty field so the caregiver sees exactly what's
    // missing — never a silently disabled "Post" with no explanation.
    if (!validateAndScrollToFirstError(_formKey)) return;

    final String title = _titleController.text.trim();
    final String body = _bodyController.text.trim();
    // The title is locked in edit mode (the Worker only updates the body),
    // so an edit just needs a non-empty body; a new post needs both.
    if (body.isEmpty || (!_isEdit && title.isEmpty)) return;

    if (_isEdit) {
      await _submitEdit(body);
      return;
    }

    final bool acknowledged = await ref
        .read(guidelinesAcknowledgedProvider.future);
    if (!mounted) return;
    if (!acknowledged) {
      final bool? accepted = await _showAckSheet();
      if (!mounted || accepted != true) return;
      await ref
          .read(guidelinesAcknowledgedProvider.notifier)
          .markAcknowledged();
      if (!mounted) return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final ForumApiClient client = ref.read(forumApiClientProvider);
      final ForumCreatePostResponse resp = await client.createPost(
        title: title,
        body: body,
      );
      if (!mounted) return;
      // Surface the new post on the feed without a manual pull-to-refresh.
      // refresh() is best-effort — if the round-trip fails, the SnackBar
      // still fires so the caregiver knows the post landed.
      unawaited(ref.read(communityFeedProvider.notifier).refresh());
      if (resp.crisisResources != null) {
        _showCrisisBanner(resp.crisisResources!);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Posted.')),
        );
      }
      context.goNamed(CareblazersRoutes.community);
    } on ForumApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = _humanizeError(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = "Couldn't post — check your connection and try again.";
      });
    }
  }

  /// Edit-mode submit: PATCH the post body, refresh the feed so its preview
  /// updates, then pop back to the post detail (the detail re-fetches on
  /// return). No guidelines ack — the caregiver is editing content they
  /// already published.
  Future<void> _submitEdit(String body) async {
    final ForumPost editing = widget.editPost!;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final ForumApiClient client = ref.read(forumApiClientProvider);
      await client.updatePost(postId: editing.id, body: body);
      if (!mounted) return;
      unawaited(ref.read(communityFeedProvider.notifier).refresh());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Post updated.')),
      );
      // Pop back to the detail screen the edit was launched from.
      if (context.canPop()) {
        context.pop();
      } else {
        context.goNamed(CareblazersRoutes.community);
      }
    } on ForumApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = _humanizeError(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage =
            "Couldn't save the edit — check your connection and try again.";
      });
    }
  }

  Future<bool?> _showAckSheet() {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cb.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) => const _FirstPostAckSheet(),
    );
  }

  void _showCrisisBanner(ForumCrisisResources resources) {
    final String hotlines = resources.hotlines
        .map((ForumCrisisHotline h) => '${h.label}: ${h.number}')
        .join(' · ');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: context.cb.accentDeep,
        duration: const Duration(seconds: 8),
        content: Text(
          'You are not alone. $hotlines',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  String _humanizeError(ForumApiException e) {
    if (e.statusCode == 401 || e.tokenExpired) {
      return 'Session expired — sign in again to post.';
    }
    if (e.statusCode == 413 || e.error.contains('too_long')) {
      return 'Post is too long. Trim it and try again.';
    }
    if (e.statusCode == 429) {
      return "You've posted recently. Give it a minute, then try again.";
    }
    if (e.statusCode >= 500) {
      return 'Server hiccup. We logged it — try again in a bit.';
    }
    return "Couldn't post — ${e.error}";
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String submitIdle = _isEdit ? 'Save' : 'Post';
    final String submitBusy = _isEdit ? 'Saving…' : 'Posting…';
    // The button stays tappable even with empty fields — pressing it runs
    // validation and surfaces the inline "Add a title" / "Add some detail"
    // errors. It only goes inert mid-submit so a double-tap can't double-post.
    final Widget submitAction = TextButton(
      key: PostComposeScreen.submitButtonKey,
      onPressed: _submitting ? null : _submit,
      child: Text(
        _submitting ? submitBusy : submitIdle,
        style: textTheme.labelLarge?.copyWith(
          color: _submitting
              ? context.cb.text.withValues(alpha: 0.3)
              : context.cb.cta,
        ),
      ),
    );
    return Scaffold(
      backgroundColor: context.cb.background,
      // The title + Back live in the body PathHeader; this minimal bar only
      // suppresses the auto back-arrow (the PathHeader owns the labeled Back
      // control, and its trailing slot carries the Post action).
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: context.cb.background,
        elevation: 0,
        actions: const <Widget>[],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                PathHeader(
                  breadcrumbs: <PathHeaderCrumb>[
                    const PathHeaderCrumb(label: 'Home', route: '/'),
                    const PathHeaderCrumb(
                        label: 'Community', route: '/community'),
                    PathHeaderCrumb(label: _isEdit ? 'Edit post' : 'New post'),
                  ],
                  title: _isEdit ? 'Edit post' : 'New post',
                  backLabel: 'Back to Community',
                  leadingIcon: Icons.edit_outlined,
                  trailing: submitAction,
                ),
                const SizedBox(height: 20),
                if (_errorMessage != null) ...<Widget>[
                  _ErrorBanner(message: _errorMessage!),
                  const SizedBox(height: 16),
                ],
                _LabeledField(
                  label: 'Title',
                  child: TextFormField(
                    key: PostComposeScreen.titleFieldKey,
                    controller: _titleController,
                    // The title can't change on an edit — the Worker's
                    // `PATCH /posts/:id` only updates the body. Lock it so the
                    // caregiver isn't misled into editing a field that won't
                    // save.
                    readOnly: _isEdit,
                    enabled: !_isEdit,
                    maxLength: postComposeTitleMaxChars,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    decoration: const InputDecoration(
                      hintText: "What's on your mind tonight?",
                      counterText: '',
                    ),
                    validator: _validateTitle,
                    textInputAction: TextInputAction.next,
                  ),
                ),
                if (_isEdit)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      "The title stays as posted — edit the body below.",
                      style: textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        color: context.cb.text.withValues(alpha: 0.55),
                      ),
                    ),
                  )
                else
                  _CounterRow(
                    counterKey: PostComposeScreen.titleCounterKey,
                    current: _titleController.text.characters.length,
                    cap: postComposeTitleMaxChars,
                  ),
                const SizedBox(height: 24),
                _LabeledField(
                  label: 'Body',
                  child: TextFormField(
                    key: PostComposeScreen.bodyFieldKey,
                    controller: _bodyController,
                    maxLength: postComposeBodyMaxChars,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    decoration: const InputDecoration(
                      hintText:
                          "Tell us the moment, what worked, what didn't.",
                      counterText: '',
                    ),
                    validator: _validateBody,
                    minLines: 8,
                    maxLines: 16,
                  ),
                ),
                _CounterRow(
                  counterKey: PostComposeScreen.bodyCounterKey,
                  current: _bodyController.text.characters.length,
                  cap: postComposeBodyMaxChars,
                ),
                const SizedBox(height: 24),
                _GuidelinesLink(
                  onPressed: () =>
                      context.pushNamed(CareblazersRoutes.communityGuidelines),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String? _validateTitle(String? value) {
    final String trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) {
      return 'Add a title — even a few words helps.';
    }
    return null;
  }

  static String? _validateBody(String? value) {
    final String trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) {
      return 'Add some detail — tell us the moment.';
    }
    return null;
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: textTheme.labelLarge?.copyWith(
            color: context.cb.primary,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _CounterRow extends StatelessWidget {
  const _CounterRow({
    required this.counterKey,
    required this.current,
    required this.cap,
  });

  final Key counterKey;
  final int current;
  final int cap;

  @override
  Widget build(BuildContext context) {
    final int remaining = cap - current;
    final bool warn = remaining <= 40;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          Text(
            key: counterKey,
            '$current / $cap',
            style: textTheme.bodyMedium?.copyWith(
              fontSize: 13,
              color: warn
                  ? context.cb.accentDeep
                  : context.cb.text.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuidelinesLink extends StatelessWidget {
  const _GuidelinesLink({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: PostComposeScreen.guidelinesLinkKey,
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(Icons.menu_book_outlined,
                size: 20, color: context.cb.link),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Read community guidelines',
                style: textTheme.bodyMedium?.copyWith(
                  color: context.cb.link,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: PostComposeScreen.errorBannerKey,
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.cb.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.cb.error.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: context.cb.error, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: textTheme.bodyMedium?.copyWith(
                color: context.cb.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FirstPostAckSheet extends StatelessWidget {
  const _FirstPostAckSheet();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    return Container(
      key: PostComposeScreen.ackSheetKey,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + safeBottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.cb.text.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Before your first post',
            style: textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            firstPostAcknowledgement,
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          const Flexible(
            child: SingleChildScrollView(
              child: CommunityGuidelinesScreen.embedded(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  key: PostComposeScreen.ackCancelKey,
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Not yet'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  key: PostComposeScreen.ackAcceptKey,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.cb.cta,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text("I've read them"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
