import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceStatus', () {
    test('isReadyForSafety requires paired, activated, and connected', () {
      const ready = DeviceStatus(
        deviceId: 'device-1',
        paired: true,
        activated: true,
        connected: true,
      );
      const notReady = DeviceStatus(
        deviceId: 'device-1',
        paired: true,
        activated: false,
        connected: true,
      );

      expect(ready.isReadyForSafety, isTrue);
      expect(notReady.isReadyForSafety, isFalse);
    });

    test('derives battery state and approximate percentage from protocol value',
        () {
      const status = DeviceStatus(
        deviceId: 'device-1',
        paired: true,
        activated: true,
        connected: true,
        batteryLevel: 2,
      );

      expect(status.effectiveBatteryState, DeviceBatteryLevel.medium);
      expect(status.approximateBatteryPercentage, 65);
    });

    test('preserves exact battery percentage including zero', () {
      const status = DeviceStatus(
        deviceId: 'device-1',
        paired: true,
        activated: true,
        connected: true,
        batteryPercent: 0,
        batteryLevel: 3,
        batteryState: DeviceBatteryLevel.ok,
      );

      expect(status.batteryPercent, 0);
      expect(status.effectiveBatteryState, DeviceBatteryLevel.critical);
      expect(status.approximateBatteryPercentage, 0);
    });

    test('copyWith can explicitly clear battery data', () {
      const status = DeviceStatus(
        deviceId: 'device-1',
        paired: true,
        activated: true,
        connected: true,
        batteryPercent: 88,
        batteryLevel: 3,
        batteryState: DeviceBatteryLevel.ok,
        batterySource: DeviceBatterySource.deviceStatus,
      );

      final cleared = status.copyWith(
        batteryPercent: null,
        batteryLevel: null,
        batteryState: null,
        batterySource: DeviceBatterySource.unknown,
      );

      expect(cleared.batteryPercent, isNull);
      expect(cleared.batteryLevel, isNull);
      expect(cleared.effectiveBatteryState, isNull);
      expect(cleared.approximateBatteryPercentage, isNull);
      expect(cleared.batterySource, DeviceBatterySource.unknown);
    });

    test('copyWith can clear provisioning errors explicitly', () {
      const failed = DeviceStatus(
        deviceId: 'device-1',
        paired: true,
        activated: false,
        connected: false,
        lifecycleState: DeviceLifecycleState.error,
        provisioningError: 'Activation failed',
      );

      final recovered = failed.copyWith(
        lifecycleState: DeviceLifecycleState.ready,
        clearProvisioningError: true,
      );

      expect(recovered.lifecycleState, DeviceLifecycleState.ready);
      expect(recovered.provisioningError, isNull);
    });
  });

  group('DeviceBatteryLevel.fromPercentage', () {
    const cases = <int, DeviceBatteryLevel>{
      0: DeviceBatteryLevel.critical,
      9: DeviceBatteryLevel.critical,
      10: DeviceBatteryLevel.low,
      29: DeviceBatteryLevel.low,
      30: DeviceBatteryLevel.medium,
      59: DeviceBatteryLevel.medium,
      60: DeviceBatteryLevel.ok,
      100: DeviceBatteryLevel.ok,
    };

    for (final entry in cases.entries) {
      test('${entry.key}% maps to ${entry.value.name}', () {
        expect(DeviceBatteryLevel.fromPercentage(entry.key), entry.value);
      });
    }

    test('rejects missing and out-of-range percentages', () {
      expect(DeviceBatteryLevel.fromPercentage(null), isNull);
      expect(DeviceBatteryLevel.fromPercentage(-1), isNull);
      expect(DeviceBatteryLevel.fromPercentage(101), isNull);
      expect(DeviceBatteryLevel.fromPercentage(255), isNull);
    });
  });
}
