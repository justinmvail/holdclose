import 'package:holdclose/providers/link_launcher_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinkLauncher', () {
    test('RecordingLinkLauncher tracks every URL passed to launch', () async {
      final RecordingLinkLauncher rec = RecordingLinkLauncher();

      final Uri first =
          Uri.parse('https://holdclose.com/care-collective');
      final Uri second = Uri.parse('mailto:hello@holdclose.com');

      expect(await rec.launch(first), isTrue);
      expect(await rec.launch(second), isTrue);

      expect(rec.launched, <Uri>[first, second]);
    });

    test('RealLinkLauncher is a const-constructible LinkLauncher', () {
      // The riverpod selector defaults to const RealLinkLauncher();
      // assert const-ness so a careless refactor doesn't turn the
      // default impl into a per-rebuild allocation.
      const LinkLauncher launcher = RealLinkLauncher();
      expect(launcher, isA<LinkLauncher>());
    });
  });
}
