import 'package:careblazers/services/forum_api_client.dart';
import 'package:careblazers/theme.dart';
import 'package:careblazers/widgets/network_error_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the shared offline / network-error surface (#19) that
/// the community feed + post detail render on an unreachable backend, and
/// for the two copy helpers ([isTransportError] / [networkErrorDetail]) the
/// screens use to pick caregiver-facing wording.

Future<void> _pump(
  WidgetTester tester, {
  required String headline,
  required String detail,
  required Future<void> Function() onRetry,
  Key? retryButtonKey,
  String retryLabel = 'Try again',
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        textTheme: ThemeData.light().textTheme,
        scaffoldBackgroundColor: careblazersColors.background,
      ),
      home: Scaffold(
        body: NetworkErrorView(
          headline: headline,
          detail: detail,
          onRetry: onRetry,
          retryButtonKey: retryButtonKey,
          retryLabel: retryLabel,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('NetworkErrorView', () {
    testWidgets('renders the headline, detail, cloud-off glyph, and button',
        (WidgetTester tester) async {
      await _pump(
        tester,
        headline: "We couldn't reach the community.",
        detail: 'Check your connection and try again.',
        onRetry: () async {},
      );

      expect(find.text("We couldn't reach the community."), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Try again'), findsOneWidget);
    });

    testWidgets('tapping the button invokes onRetry',
        (WidgetTester tester) async {
      int retries = 0;
      await _pump(
        tester,
        headline: 'Headline',
        detail: 'Detail',
        retryButtonKey: const Key('test-retry'),
        onRetry: () async {
          retries++;
        },
      );

      await tester.tap(find.byKey(const Key('test-retry')));
      await tester.pumpAndSettle();
      expect(retries, 1);
    });

    testWidgets('honors a custom retry label', (WidgetTester tester) async {
      await _pump(
        tester,
        headline: 'Headline',
        detail: 'Detail',
        retryLabel: 'Reconnect',
        onRetry: () async {},
      );

      expect(find.widgetWithText(ElevatedButton, 'Reconnect'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('the retry button uses the brand CTA color',
        (WidgetTester tester) async {
      await _pump(
        tester,
        headline: 'Headline',
        detail: 'Detail',
        onRetry: () async {},
      );

      final ElevatedButton button =
          tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      final Color? bg = button.style?.backgroundColor
          ?.resolve(<WidgetState>{});
      expect(bg, careblazersColors.cta);
    });
  });

  group('isTransportError', () {
    test('true only for a ForumApiException with statusCode 0', () {
      expect(
        isTransportError(
            ForumApiException(statusCode: 0, error: 'transport_error')),
        isTrue,
      );
      expect(
        isTransportError(ForumApiException(statusCode: 500, error: 'boom')),
        isFalse,
      );
      expect(
        isTransportError(ForumApiException(statusCode: 404, error: 'gone')),
        isFalse,
      );
      expect(isTransportError(Exception('generic')), isFalse);
      expect(isTransportError(null), isFalse);
    });
  });

  group('networkErrorDetail', () {
    test('transport failure → "check your connection" nudge', () {
      expect(
        networkErrorDetail(
            ForumApiException(statusCode: 0, error: 'transport_error')),
        'Check your connection and try again.',
      );
    });

    test('non-transport failure → neutral fallback (no raw exception)', () {
      final String detail =
          networkErrorDetail(ForumApiException(statusCode: 500, error: 'boom'));
      expect(detail, 'Something went wrong. Try again in a moment.');
      // The raw error string never leaks to the caregiver.
      expect(detail.contains('boom'), isFalse);
      expect(detail.contains('500'), isFalse);
    });

    test('null error → neutral fallback', () {
      expect(
        networkErrorDetail(null),
        'Something went wrong. Try again in a moment.',
      );
    });
  });
}
