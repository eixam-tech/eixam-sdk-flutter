import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats the housing serial from the lower 24 node-id bits', () {
    expect(EixamHardwareLabel.housingSerial(0xE4BF425B), 'N6BF425B');
    expect(EixamHardwareLabel.housingSerial(0x0000000A), 'N600000A');
  });

  test('recognizes current and legacy advertised names', () {
    expect(EixamHardwareLabel.looksLikeAdvertisedName('N6BF425B'), isTrue);
    expect(
      EixamHardwareLabel.looksLikeAdvertisedName('EIXAM_E4BF425B'),
      isTrue,
    );
    expect(EixamHardwareLabel.looksLikeAdvertisedName('N6BF425'), isFalse);
    expect(EixamHardwareLabel.looksLikeAdvertisedName('other'), isFalse);
  });
}
