import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('TrackingPosition', () {
    test('isStale is false for recent positions', () {
      final position = TrackingPosition(
        latitude: 41.0,
        longitude: 2.0,
        timestamp: DateTime.now().subtract(const Duration(seconds: 30)),
      );

      expect(position.isStale, isFalse);
    });

    test('isStale is true when the position is older than two minutes', () {
      final position = TrackingPosition(
        latitude: 41.0,
        longitude: 2.0,
        timestamp: DateTime.now().subtract(const Duration(minutes: 3)),
      );

      expect(position.isStale, isTrue);
      expect(position.age, greaterThan(const Duration(minutes: 2)));
    });
  });
}
