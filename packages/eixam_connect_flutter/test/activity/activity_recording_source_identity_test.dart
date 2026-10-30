import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/activity/activity_recording_source_identity.dart';
import 'package:eixam_connect_flutter/src/device/canonical_hardware_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy MAC normalization remains unchanged and namespace disjoint', () {
    for (final value in ['AA:BB:CC:DD:EE:01', ' aa:bb:cc:dd:ee:01 ']) {
      final parsed = ActivityRecordingSourceIdentity.parse(value)!;
      expect(parsed.value, normalizeCanonicalHardwareId(value));
      expect(parsed.nodeId, isNull);
    }
    expect(normalizeCanonicalHardwareId('node:42'), isNull);
  });

  for (final node in [1, 42, 2147483648, 4294967294]) {
    test('registered node $node has one canonical roundtrip', () {
      final source = ActivityRecordingSourceIdentity.parse('node:$node')!;
      expect(source.nodeId, node);
      expect(source.value, 'node:$node');
      expect(
        ActivityRecordingSourceIdentity.parse(source.value)!.value,
        source.value,
      );
      expect(
        ActivityRecordingSourceIdentity.forNode(node)!.value,
        source.value,
      );
    });
  }

  for (final raw in [
    '',
    '42',
    'node:',
    'node:0',
    'node:-1',
    'node:+1',
    'node:01',
    'node:4294967295',
    'node:4294967296',
    'node:99999999999999999999',
    'node:0x2a',
    'node:4.2',
    'node:4e2',
    'node: 42',
    ' node:42',
    'node:42 ',
    'node:42\n',
    'node:42\r',
    'node:42\u0000',
    'node:４２',
    'NODE:42',
    'node:AA:BB:CC:DD:EE:01',
    'mac:AA:BB:CC:DD:EE:01',
    'AA-BB-CC-DD-EE-01',
    '12345678-1234-1234-1234-123456789abc',
  ]) {
    test(
      'malformed or ambiguous Recording identity ${raw.codeUnits} fails',
      () {
        expect(ActivityRecordingSourceIdentity.parse(raw), isNull);
      },
    );
  }

  test(
    'node match requires exact provisioned node without canonical hardware',
    () {
      final source = ActivityRecordingSourceIdentity.parse('node:42')!;
      const status = DeviceStatus(
        deviceId: 'ios-peripheral-uuid',
        nodeId: 42,
        paired: true,
        activated: false,
        connected: true,
        provisioningStatus: DeviceProvisioningStatus.provisioned,
      );
      expect(source.matchesDevice(status), isTrue);
      expect(source.matchesDevice(status.copyWith(nodeId: 43)), isFalse);
      for (final provision in [
        DeviceProvisioningStatus.unknown,
        DeviceProvisioningStatus.unprovisioned,
      ]) {
        expect(
          source.matchesDevice(status.copyWith(provisioningStatus: provision)),
          isFalse,
        );
      }
      for (final node in [null, -1, 0, 4294967295, 4294967296]) {
        expect(ActivityRecordingSourceIdentity.forNode(node), isNull);
      }
    },
  );
}
