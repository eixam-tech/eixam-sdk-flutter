import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/mock_ble_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';

void main() {
  group('BleDeviceRuntimeProvider device control', () {
    late MockBleClient bleClient;
    late BleDeviceRuntimeProvider runtimeProvider;

    setUp(() async {
      BleDebugRegistry.instance.reset();
      bleClient = MockBleClient();
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
    });

    tearDown(() async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
    });

    test('sets notification volume through the command channel', () async {
      await _pairDemoDevice(runtimeProvider);

      await runtimeProvider.setNotificationVolume(55);

      expect(bleClient.writtenCommands.last.bytes, <int>[0x11, 55]);
      expect(bleClient.writtenCommands.last.usesCmdCharacteristic, isTrue);
    });

    test('sets SOS volume through the command channel', () async {
      await _pairDemoDevice(runtimeProvider);

      await runtimeProvider.setSosVolume(77);

      expect(bleClient.writtenCommands.last.bytes, <int>[0x12, 77]);
      expect(bleClient.writtenCommands.last.usesCmdCharacteristic, isTrue);
    });

    test('rejects invalid volume values clearly', () async {
      await _pairDemoDevice(runtimeProvider);

      await expectLater(
        Future<void>.sync(() => runtimeProvider.setNotificationVolume(101)),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_INVALID_VOLUME',
          ),
        ),
      );
    });

    test('rejects command APIs when no command-capable device is connected',
        () async {
      await expectLater(
        runtimeProvider.rebootDevice(),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_COMMAND_NOT_READY',
          ),
        ),
      );
    });

    test('parses a valid runtime status response', () async {
      await _pairDemoDevice(runtimeProvider);

      final status = await runtimeProvider.requestDeviceRuntimeStatus();

      expect(status.region, 2);
      expect(status.modemPreset, 3);
      expect(status.meshSpreadingFactor, 7);
      expect(status.isProvisioned, isTrue);
      expect(status.usePreset, isTrue);
      expect(status.txEnabled, isTrue);
      expect(status.inetOk, isTrue);
      expect(status.positionConfirmed, isTrue);
      expect(status.nodeId, 0x1234);
      expect(status.batteryPercent, 88);
      expect(status.telIntervalSeconds, 60);
    });

    test('handles malformed runtime status responses safely', () async {
      await _pairDemoDevice(runtimeProvider);
      bleClient.runtimeStatusPayload = <int>[0xE9, 0x78, 0x01, 0x02];

      await expectLater(
        runtimeProvider.requestDeviceRuntimeStatus(
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_STATUS_TIMEOUT',
          ),
        ),
      );
    });

    test('reboot sends the expected command', () async {
      await _pairDemoDevice(runtimeProvider);

      await runtimeProvider.rebootDevice();

      expect(bleClient.writtenCommands.last.bytes, <int>[0x22]);
      expect(bleClient.writtenCommands.last.usesCmdCharacteristic, isTrue);
    });
  });
}

Future<void> _pairDemoDevice(BleDeviceRuntimeProvider runtimeProvider) async {
  BleDebugRegistry.instance
      .update(selectedDeviceId: MockBleClient.demoDeviceId);
  await runtimeProvider.pair(
    currentStatus: buildDeviceStatus(
      paired: false,
      activated: false,
      connected: false,
      lifecycleState: DeviceLifecycleState.unpaired,
    ),
    pairingCode: '1234',
  );
}
