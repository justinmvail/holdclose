// Guards the Android manifest against permissions that block Play submission.
//
// READ_MEDIA_IMAGES / READ_MEDIA_VIDEO are rejected by Google Play policy for
// apps targeting API 33+ unless the system photo picker is technically
// insufficient — which it isn't for us (image_picker uses the OS picker /
// ACTION_GET_CONTENT, which needs no broad media permission). Version code 52
// was blocked from every track for exactly this. If a future change adds one of
// these back, this test fails BEFORE another Play submission is wasted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');

  test('main AndroidManifest exists', () {
    expect(manifest.existsSync(), isTrue,
        reason: 'android/app/src/main/AndroidManifest.xml not found');
  });

  test('does not request Play-restricted broad media permissions', () {
    final xml = manifest.readAsStringSync();
    for (final perm in const [
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.READ_MEDIA_VIDEO',
    ]) {
      expect(
        xml.contains(perm),
        isFalse,
        reason: '$perm is banned by Play policy for API 33+ targets; '
            'image_picker uses the system photo picker and does not need it. '
            'Adding it back re-breaks Play submission across all tracks.',
      );
    }
  });
}
