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

    test('derives battery state and approximate percentage from protocol value', () {
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
}
