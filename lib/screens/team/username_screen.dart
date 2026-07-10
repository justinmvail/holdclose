import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/forum.dart';
import '../../providers/my_forum_profile_provider.dart';
import '../../services/forum_api_client.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Live availability state of the handle the caregiver is typing.
enum _Availability { idle, checking, available, taken, invalid }

/// Pick-your-`@username` screen (care-circle connect, 2026-06-06) at
/// `/team/circle/username`, reached from the People roster.
///
/// A lowercasing text field with a debounced availability check
/// (`GET /profiles/username-available`) showing available / taken /
/// invalid, and a Save that PATCHes `username` (handling the 409
/// `username_taken` race). The caller's current handle — if any — shows
/// at the top so they can see what they already hold.
class UsernameScreen extends ConsumerStatefulWidget {
  const UsernameScreen({super.key});

  static const Key fieldKey = Key('username-field');
  static const Key statusKey = Key('username-status');
  static const Key saveKey = Key('username-save');
  static const Key currentKey = Key('username-current');

  @override
  ConsumerState<UsernameScreen> createState() => _UsernameScreenState();
}

class _UsernameScreenState extends ConsumerState<UsernameScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  _Availability _availability = _Availability.idle;
  bool _saving = false;
  String? _error;

  /// The handle the last availability check ran against — guards against
  /// a stale in-flight response clobbering a newer keystroke's state.
  String _pending = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    final String handle = raw.toLowerCase();
    if (handle != raw) {
      _controller.value = _controller.value.copyWith(
        text: handle,
        selection: TextSelection.collapsed(offset: handle.length),
      );
    }
    _debounce?.cancel();
    setState(() {
      _error = null;
      _availability = handle.isEmpty ? _Availability.idle : _Availability.checking;
    });
    if (handle.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_check(handle));
    });
  }

  Future<void> _check(String handle) async {
    _pending = handle;
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      final ({bool valid, bool available}) result =
          await client.usernameAvailable(handle);
      if (!mounted || _pending != handle) return;
      setState(() {
        _availability = !result.valid
            ? _Availability.invalid
            : result.available
                ? _Availability.available
                : _Availability.taken;
      });
    } on ForumApiException {
      if (!mounted || _pending != handle) return;
      setState(() => _availability = _Availability.invalid);
    }
  }

  Future<void> _save() async {
    if (_saving || _availability != _Availability.available) return;
    final String handle = _controller.text.toLowerCase().trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ForumApiClient client = ref.read(forumApiClientProvider);
    try {
      await client.updateMyProfile(username: handle);
      await ref.read(myForumProfileProvider.notifier).refresh();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Your username is @$handle.')),
      );
      _leave();
    } on ForumApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (e.error == 'username_taken') {
          _availability = _Availability.taken;
          _error = 'That username was just taken. Try another.';
        } else if (e.error == 'invalid_username') {
          _availability = _Availability.invalid;
          _error = 'That username isn\'t allowed.';
        } else if (e.error == 'profanity_blocked') {
          _availability = _Availability.invalid;
          _error = 'Please choose a different username.';
        } else {
          _error = 'We couldn\'t save that. Please try again.';
        }
      });
    }
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
    final AsyncValue<ForumProfile> profile =
        ref.watch(myForumProfileProvider);
    final String? current = profile.maybeWhen(
      data: (ForumProfile p) => p.username,
      orElse: () => null,
    );

    return Scaffold(
      backgroundColor: context.hc.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: <Widget>[
            const PathHeader(
              breadcrumbs: <PathHeaderCrumb>[
                PathHeaderCrumb(label: 'Home', route: '/'),
                PathHeaderCrumb(label: 'Care Circle', route: '/team'),
                PathHeaderCrumb(label: 'Care Circle', route: '/team/circle'),
                PathHeaderCrumb(label: 'Username'),
              ],
              title: 'Set your @username',
              backLabel: 'Back to Care Circle',
              leadingIcon: Icons.alternate_email,
            ),
            const SizedBox(height: 8),
            Text(
              'Pick a username so other caregivers can find and connect with '
              'you. Letters, numbers, and underscores; 3 to 20 characters.',
              style: textTheme.bodyLarge?.copyWith(color: context.hc.text),
            ),
            const SizedBox(height: 20),
            if (current != null) ...<Widget>[
              Container(
                key: UsernameScreen.currentKey,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: context.hc.surfaceWarm,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.check_circle_outline,
                        color: context.hc.link),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Your username is @$current',
                        style: textTheme.bodyLarge?.copyWith(
                          color: context.hc.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
            TextField(
              key: UsernameScreen.fieldKey,
              controller: _controller,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(20),
              ],
              onChanged: _onChanged,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                prefixText: '@',
                labelText: 'Username',
                hintText: 'sarah_h',
              ),
            ),
            const SizedBox(height: 10),
            _StatusLine(availability: _availability),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: textTheme.bodyMedium?.copyWith(color: context.hc.cta),
              ),
            ],
            const SizedBox(height: 28),
            Semantics(
              button: true,
              label: 'Save your username.',
              child: ElevatedButton(
                key: UsernameScreen.saveKey,
                onPressed: (_saving || _availability != _Availability.available)
                    ? null
                    : _save,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  backgroundColor: context.hc.ctaFilled,
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  _saving ? 'Saving…' : 'Save username',
                  style: textTheme.labelLarge?.copyWith(color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.availability});

  final _Availability availability;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final (IconData icon, Color color, String label) spec = switch (availability) {
      _Availability.idle => (Icons.info_outline, context.hc.primarySoft, ''),
      _Availability.checking => (
          Icons.hourglass_empty,
          context.hc.primarySoft,
          'Checking…'
        ),
      _Availability.available => (
          Icons.check_circle,
          context.hc.link,
          'Available'
        ),
      _Availability.taken => (
          Icons.cancel_outlined,
          context.hc.cta,
          'Taken'
        ),
      _Availability.invalid => (
          Icons.error_outline,
          context.hc.cta,
          'Not a valid username'
        ),
    };
    if (spec.$3.isEmpty) return const SizedBox.shrink();
    return Row(
      key: UsernameScreen.statusKey,
      children: <Widget>[
        Icon(spec.$1, size: 18, color: spec.$2),
        const SizedBox(width: 8),
        Text(
          spec.$3,
          style: textTheme.bodyMedium?.copyWith(
            color: spec.$2,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
