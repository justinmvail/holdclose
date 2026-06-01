import 'package:flutter/material.dart';

import '../../seed/learn_content.dart';
import '../../theme.dart';
import '../../widgets/path_header.dart';

/// Video detail at `/community/learn/videos/:id` (BUILD_SPEC.md §5.16,
/// TASKS.md Phase 14.37).
///
/// Real video hosting is deferred to a later phase — this screen renders a
/// **soft placeholder** body over the seeded [LearnVideo] metadata: the
/// thumbnail panel, title, run length, blurb, and a calm "coming soon"
/// note. A [PathHeader] (`Home › Community › Learn`, back to Learn) sits on
/// top per the §4.1 path-header invariant.
class LearnVideoDetailScreen extends StatelessWidget {
  const LearnVideoDetailScreen({super.key, required this.videoId});

  /// Video id pulled from `/community/learn/videos/:id`.
  final String videoId;

  static const Key scrollKey = Key('learn-video-detail-scroll');
  static const Key placeholderKey = Key('learn-video-detail-placeholder');
  static const Key missingKey = Key('learn-video-detail-missing');

  @override
  Widget build(BuildContext context) {
    final LearnVideo? video = learnVideoById(videoId);
    return Scaffold(
      backgroundColor: careblazersColors.background,
      body: SafeArea(
        child: video == null
            ? const _MissingView()
            : _DetailBody(video: video),
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.video});

  final LearnVideo video;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      key: LearnVideoDetailScreen.scrollKey,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const PathHeader(
            breadcrumbs: <PathHeaderCrumb>[
              PathHeaderCrumb(label: 'Home', route: '/'),
              PathHeaderCrumb(label: 'Community', route: '/community'),
              PathHeaderCrumb(label: 'Learn'),
            ],
            title: 'Video',
            backLabel: 'Back to Learn',
            leadingIcon: Icons.play_circle_outline,
          ),
          const SizedBox(height: 20),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: careblazersColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Icon(
                  Icons.play_circle_outline,
                  size: 64,
                  color: careblazersColors.background,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            video.title,
            style: textTheme.headlineLarge?.copyWith(
              color: careblazersColors.primary,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Icon(
                Icons.schedule,
                size: 18,
                color: careblazersColors.primarySoft,
              ),
              const SizedBox(width: 4),
              Text(
                video.durationLabel,
                style: textTheme.bodyMedium?.copyWith(
                  color: careblazersColors.primarySoft,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            video.blurb,
            style: textTheme.bodyLarge?.copyWith(
              color: careblazersColors.text,
            ),
          ),
          const SizedBox(height: 28),
          const _ComingSoonNote(),
        ],
      ),
    );
  }
}

class _ComingSoonNote extends StatelessWidget {
  const _ComingSoonNote();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      key: LearnVideoDetailScreen.placeholderKey,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: careblazersColors.surfaceWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.video_library_outlined,
            size: 40,
            color: careblazersColors.primarySoft,
          ),
          const SizedBox(height: 12),
          Text(
            'This video is on its way',
            style: textTheme.titleLarge?.copyWith(
              color: careblazersColors.primary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            "We're preparing this lesson so it plays right here in the app. "
            'Until then, the decoder is one tap away whenever you need a '
            'script for the moment.',
            style: textTheme.bodyMedium?.copyWith(
              color: careblazersColors.text,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _MissingView extends StatelessWidget {
  const _MissingView();

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: PathHeader(
            breadcrumbs: <PathHeaderCrumb>[
              PathHeaderCrumb(label: 'Home', route: '/'),
              PathHeaderCrumb(label: 'Community', route: '/community'),
              PathHeaderCrumb(label: 'Learn'),
            ],
            title: 'Video',
            backLabel: 'Back to Learn',
            leadingIcon: Icons.play_circle_outline,
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              key: LearnVideoDetailScreen.missingKey,
              padding: const EdgeInsets.all(24),
              child: Text(
                'This video is no longer available.',
                style: textTheme.bodyLarge?.copyWith(
                  color: careblazersColors.text,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
