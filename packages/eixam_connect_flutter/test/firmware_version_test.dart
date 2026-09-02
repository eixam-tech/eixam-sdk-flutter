import 'package:eixam_connect_flutter/src/firmware_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches portal short builds with GATT semver', () {
    expect(eixamFirmwareVersionsMatch('2.7.50', '50'), isTrue);
    expect(eixamFirmwareVersionsMatch('2.7.50.4ef9d04', '50'), isTrue);
    expect(eixamFirmwareVersionsMatch('v50', '2.7.50'), isTrue);
    expect(eixamFirmwareVersionsMatch('2.7.45', '50'), isFalse);
    expect(
      eixamFirmwareVersionsMatch('2.7.50.aaa1111', '2.7.50.bbb2222'),
      isFalse,
    );
  });

  test('orders mixed short builds against semver patch', () {
    expect(compareEixamFirmwareVersions('2.7.45', '50'), lessThan(0));
    expect(compareEixamFirmwareVersions('45', '50'), lessThan(0));
    expect(compareEixamFirmwareVersions('2.7.50', '50'), 0);
    expect(compareEixamFirmwareVersions('2.7.50', '2.7.45'), greaterThan(0));
  });
}
