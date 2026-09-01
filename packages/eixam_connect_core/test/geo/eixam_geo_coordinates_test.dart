import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('EixamGeoCoordinates', () {
    test('rejects Null Island even inside the globe', () {
      expect(EixamGeoCoordinates.isNullIsland(0, 0), isTrue);
      expect(EixamGeoCoordinates.isValidFix(0, 0), isFalse);
      expect(EixamGeoCoordinates.isValidFix(42.5, 1.5), isTrue);
      expect(EixamGeoCoordinates.isValidFix(-90, -180), isTrue);
    });
  });
}
