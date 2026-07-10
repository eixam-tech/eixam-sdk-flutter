import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/repositories/platform_permissions_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_adapter_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../support/device/mock_ble_client.dart';

void main() {
  group('PlatformPermissionsRepository', () {
    test('iOS poweredOn adapter overrides stale denied Bluetooth snapshot',
        () async {
      final bleClient = MockBleClient();
      await bleClient.initialize();
      await bleClient.setAdapterState(BleAdapterState.poweredOn);
      final repository = _buildRepository(
        bleClient: bleClient,
        isIos: true,
        bluetoothStatuses: <ph.PermissionStatus>[ph.PermissionStatus.denied],
        bluetoothServiceEnabled: false,
      );

      final state = await repository.getPermissionState();

      expect(state.bluetooth, SdkPermissionStatus.granted);
      expect(state.bluetoothEnabled, isTrue);
      expect(state.canUseBluetooth, isTrue);
      await bleClient.dispose();
    });

    test('iOS poweredOff adapter reports permission allowed but not ready',
        () async {
      final bleClient = MockBleClient();
      await bleClient.initialize();
      await bleClient.setAdapterState(BleAdapterState.poweredOff);
      final repository = _buildRepository(
        bleClient: bleClient,
        isIos: true,
        bluetoothStatuses: <ph.PermissionStatus>[ph.PermissionStatus.denied],
        bluetoothServiceEnabled: false,
      );

      final state = await repository.getPermissionState();

      expect(state.bluetooth, SdkPermissionStatus.granted);
      expect(state.bluetoothEnabled, isFalse);
      expect(state.canUseBluetooth, isFalse);
      await bleClient.dispose();
    });

    test('Android keeps permission-handler Bluetooth snapshot unchanged',
        () async {
      final bleClient = MockBleClient();
      await bleClient.initialize();
      await bleClient.setAdapterState(BleAdapterState.poweredOn);
      final repository = _buildRepository(
        bleClient: bleClient,
        isIos: false,
        bluetoothStatuses: <ph.PermissionStatus>[ph.PermissionStatus.denied],
        bluetoothServiceEnabled: false,
      );

      final state = await repository.getPermissionState();

      expect(state.bluetooth, SdkPermissionStatus.denied);
      expect(state.bluetoothEnabled, isFalse);
      expect(state.canUseBluetooth, isFalse);
      await bleClient.dispose();
    });
  });
}

PlatformPermissionsRepository _buildRepository({
  required MockBleClient bleClient,
  required bool isIos,
  required List<ph.PermissionStatus> bluetoothStatuses,
  required bool bluetoothServiceEnabled,
}) {
  return PlatformPermissionsRepository(
    bleClient: bleClient,
    locationServiceEnabledProvider: () async => true,
    locationPermissionProvider: () async => LocationPermission.whileInUse,
    notificationPermissionProvider: () async => ph.PermissionStatus.granted,
    bluetoothStatusesProvider: () async => bluetoothStatuses,
    bluetoothServiceEnabledProvider: () async => bluetoothServiceEnabled,
    isAndroidPlatform: () => !isIos,
    isIosPlatform: () => isIos,
  );
}
