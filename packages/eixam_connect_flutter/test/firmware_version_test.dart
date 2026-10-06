import 'package:eixam_connect_flutter/src/firmware_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

void main() {
  test('normal policy preserves every existing compatibility result', () {
    for (final actual in <String?>[
      null,
      '',
      'unknown',
      '68',
      'v68',
      '2.7.68',
      '2.7.68.c853ac1',
      '2.7.68.abcdef0',
      '2.7.67.abcdef0',
    ]) {
      expect(
        firmwareIdentityMatches(actual, '2.7.68.c853ac1'),
        eixamFirmwareVersionsMatch(actual, '2.7.68.c853ac1'),
      );
    }
  });
  test('exact candidate has no version aliases or normalization', () {
    const expected = '2.7.68.c853ac1';
    expect(
      firmwareIdentityMatches(
        expected,
        expected,
        policy: FirmwareVerificationPolicy.exactCandidate,
      ),
      isTrue,
    );
    for (final actual in <String?>[
      null,
      '',
      'unknown',
      '68',
      '2.7.68',
      '2.7.68.abcdef0',
      '2.7.67.c853ac1',
      'v2.7.68.c853ac1',
      ' 2.7.68.c853ac1',
      '2.7.68.C853AC1',
    ]) {
      expect(
        firmwareIdentityMatches(
          actual,
          expected,
          policy: FirmwareVerificationPolicy.exactCandidate,
        ),
        isFalse,
        reason: '$actual',
      );
    }
    expect(
      firmwareIdentityMatches(
        'unknown',
        'unknown',
        policy: FirmwareVerificationPolicy.exactCandidate,
      ),
      isFalse,
    );
  });

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
