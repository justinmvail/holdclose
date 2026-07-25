// Driver for integration_test/screenshots_test.dart — writes each
// binding.takeScreenshot(name) to screenshots/<name>.png at the repo root.
//
//   flutter drive --driver=test_driver/screenshot_driver.dart \
//     --target=integration_test/screenshots_test.dart \
//     --dart-define=DEMO_MODE=true -d <simulator-id>
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot:
        (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      final File file = File('screenshots/$name.png');
      await file.create(recursive: true);
      await file.writeAsBytes(bytes);
      // ignore: avoid_print
      print('WROTE screenshots/$name.png (${bytes.length} bytes)');
      return true;
    },
  );
}
