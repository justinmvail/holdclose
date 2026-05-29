import 'package:careblazers/providers/share_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Sharer', () {
    test('RecordingSharer captures every text + subject passed in', () async {
      final RecordingSharer rec = RecordingSharer();

      await rec.share('first body', subject: 'first subject');
      await rec.share('second body');

      expect(rec.shared, hasLength(2));
      expect(rec.shared[0].text, 'first body');
      expect(rec.shared[0].subject, 'first subject');
      expect(rec.shared[1].text, 'second body');
      expect(rec.shared[1].subject, isNull);
    });

    test('RealSharer is a const-constructible Sharer', () {
      // The riverpod selector defaults to const RealSharer(); assert
      // const-ness so a careless refactor doesn't turn the default
      // impl into a per-rebuild allocation.
      const Sharer sharer = RealSharer();
      expect(sharer, isA<Sharer>());
    });
  });
}
