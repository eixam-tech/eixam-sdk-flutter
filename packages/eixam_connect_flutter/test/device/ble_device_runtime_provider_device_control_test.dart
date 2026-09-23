import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_adapter_state.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_notification.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import '../support/device/mock_ble_client.dart';
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

    test('preferred availability scan matches the known hardware identity',
        () async {
      final observed = await runtimeProvider.isPreferredDeviceAdvertising(
        preferredDevice: PreferredDevice(
          deviceId: MockBleClient.demoDeviceId,
          displayName: 'EIXAM R1 Demo',
          lastConnectedAt: DateTime.utc(2026, 9, 23),
        ),
        currentStatus: buildDeviceStatus(
          deviceId: MockBleClient.demoDeviceId,
          canonicalHardwareId: MockBleClient.demoCanonicalHardwareId,
          paired: true,
          connected: false,
        ),
        scanTimeout: const Duration(milliseconds: 10),
      );

      expect(observed, isTrue);
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

    test('pairing resolves node id and device health immediately', () async {
      final status = await _pairDemoDevice(runtimeProvider);

      expect(status.nodeId, 0x1234);
      expect(status.activated, isFalse);
      expect(status.provisioningStatus, DeviceProvisioningStatus.provisioned);
      expect(status.lifecycleState, DeviceLifecycleState.paired);
      expect(status.batteryPercent, 88);
      expect(status.effectiveBatteryState, DeviceBatteryLevel.ok);
      expect(status.approximateBatteryPercentage, 88);
      expect(status.batterySource, DeviceBatterySource.deviceStatus);
      expect(status.signalQuality, isNotNull);
    });

    test(
      'pair hydrates runtime status, firmware and signal concurrently',
      () async {
        await runtimeProvider.dispose();
        await bleClient.dispose();
        final overlapping = _OverlappingHydrationBleClient();
        bleClient = overlapping;
        await overlapping.initialize();
        runtimeProvider = BleDeviceRuntimeProvider(bleClient: overlapping);

        final status = await _pairDemoDevice(runtimeProvider);

        expect(status.nodeId, 0x1234);
        expect(status.firmwareVersion, '2.7.21-mock');
        expect(status.signalQuality, isNotNull);
        expect(
          overlapping.startedAt.keys.toSet(),
          containsAll(<String>['status', 'firmware', 'rssi']),
        );
        final starts = overlapping.startedAt.values.toList()..sort();
        expect(
          starts.last.difference(starts.first),
          lessThan(_OverlappingHydrationBleClient.overlapDelay),
        );
      },
    );

    test('provisioned firmware does not implicitly activate the product',
        () async {
      final status = await _pairDemoDevice(runtimeProvider);

      expect(status.provisioningStatus, DeviceProvisioningStatus.provisioned);
      expect(status.activated, isFalse);
      expect(status.isReadyForSafety, isFalse);
    });

    test('tx enabled does not imply firmware provisioning', () async {
      bleClient.runtimeStatusPayload[6] = 0x04;

      final status = await _pairDemoDevice(runtimeProvider);

      expect(status.provisioningStatus, DeviceProvisioningStatus.unprovisioned);
      expect(status.activated, isFalse);
    });

    test('fresh 0x23 updates the authoritative provisioning status stream',
        () async {
      await _pairDemoDevice(runtimeProvider);
      bleClient.runtimeStatusPayload[6] = 0x04;
      final nextStatus = runtimeProvider.watchRuntimeStatus().firstWhere(
            (status) =>
                status.provisioningStatus ==
                DeviceProvisioningStatus.unprovisioned,
          );

      await runtimeProvider.requestDeviceRuntimeStatus();

      expect(
        (await nextStatus).provisioningStatus,
        DeviceProvisioningStatus.unprovisioned,
      );
    });

    test('missing authoritative 0x23 leaves provisioning unknown', () async {
      bleClient.runtimeStatusPayload = const <int>[0x99];

      final status = await _pairDemoDevice(runtimeProvider);

      expect(status.provisioningStatus, DeviceProvisioningStatus.unknown);
      expect(status.activated, isFalse);
    });

    test('manual refresh preserves zero and clears protocol unknown', () async {
      var status = await _pairDemoDevice(runtimeProvider);
      bleClient.runtimeStatusPayload[11] = 0;

      status = await runtimeProvider.refresh(status);

      expect(status.batteryPercent, 0);
      expect(status.effectiveBatteryState, DeviceBatteryLevel.critical);
      expect(status.approximateBatteryPercentage, 0);
      expect(status.batterySource, DeviceBatterySource.deviceStatus);

      bleClient.runtimeStatusPayload[11] = 0xFF;
      status = await runtimeProvider.refresh(status);

      expect(status.batteryPercent, isNull);
      expect(status.batteryLevel, isNull);
      expect(status.effectiveBatteryState, isNull);
      expect(status.approximateBatteryPercentage, isNull);
      expect(status.batterySource, DeviceBatterySource.unknown);
    });

    test('manual refresh hydrates a migrated device missing its node id',
        () async {
      await _pairDemoDevice(runtimeProvider);
      bleClient.runtimeStatusPayload[6] = 0x00;
      final migratedStatus = buildDeviceStatus(
        deviceId: MockBleClient.demoDeviceId,
        nodeId: null,
        canonicalHardwareId: MockBleClient.demoCanonicalHardwareId,
        activated: false,
        connected: true,
        provisioningStatus: DeviceProvisioningStatus.unknown,
        firmwareVersion: '2.7.54.2e69695',
        lifecycleState: DeviceLifecycleState.paired,
      );

      final refreshed = await runtimeProvider.refresh(migratedStatus);

      expect(refreshed.connected, isTrue);
      expect(refreshed.nodeId, 0x1234);
      expect(
        refreshed.provisioningStatus,
        DeviceProvisioningStatus.unprovisioned,
      );
    });

    test('overlapping 0x23 callers join the in-flight reply', () async {
      await _pairDemoDevice(runtimeProvider);
      bleClient.runtimeStatusReplyDelay = const Duration(milliseconds: 80);
      final before = bleClient.writtenCommands
          .where((command) => command.opcode == 0x23)
          .length;

      final first = runtimeProvider.requestDeviceRuntimeStatus();
      final second = runtimeProvider.requestDeviceRuntimeStatus();
      final results = await Future.wait(<Future<DeviceRuntimeStatus>>[
        first,
        second,
      ]);

      expect(results[0].nodeId, results[1].nodeId);
      expect(
        bleClient.writtenCommands
            .where((command) => command.opcode == 0x23)
            .length,
        before + 1,
      );
    });

    test('handles malformed runtime status responses safely', () async {
      await _pairDemoDevice(runtimeProvider);
      bleClient.runtimeStatusPayload = <int>[0xE9, 0x78, 0x02, 0x02];

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

    test('unpair removes the phone Bluetooth association', () async {
      await _pairDemoDevice(runtimeProvider);

      final status = await runtimeProvider.unpair(
        buildDeviceStatus(
          deviceId: MockBleClient.demoDeviceId,
          paired: true,
          activated: true,
          connected: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );

      expect(status.paired, isFalse);
      expect(status.connected, isFalse);
      expect(
        bleClient.removedSystemAssociations,
        contains(MockBleClient.demoDeviceId),
      );
    });

    test('suspend disconnects while preserving the phone association',
        () async {
      final pairedStatus = await _pairDemoDevice(runtimeProvider);

      final status = await runtimeProvider.suspendConnection(pairedStatus);

      expect(status.deviceId, MockBleClient.demoDeviceId);
      expect(status.paired, isTrue);
      expect(status.connected, isFalse);
      expect(status.lifecycleState, DeviceLifecycleState.paired);
      expect(
        await bleClient.isConnected(MockBleClient.demoDeviceId),
        isFalse,
      );
      expect(bleClient.systemAssociationAvailable, isTrue);
      expect(bleClient.removedSystemAssociations, isEmpty);
    });

    test('suspend is idempotent when the paired device is already offline',
        () async {
      final currentStatus = buildDeviceStatus(
        deviceId: MockBleClient.demoDeviceId,
        paired: true,
        activated: true,
        connected: false,
        lifecycleState: DeviceLifecycleState.paired,
      );

      final first = await runtimeProvider.suspendConnection(currentStatus);
      final second = await runtimeProvider.suspendConnection(first);

      expect(second.deviceId, MockBleClient.demoDeviceId);
      expect(second.paired, isTrue);
      expect(second.activated, isTrue);
      expect(second.connected, isFalse);
      expect(bleClient.systemAssociationAvailable, isTrue);
      expect(bleClient.removedSystemAssociations, isEmpty);
    });

    test('unpair removes a saved phone Bluetooth association while offline',
        () async {
      final status = await runtimeProvider.unpair(
        buildDeviceStatus(
          deviceId: MockBleClient.demoDeviceId,
          paired: true,
          activated: true,
          connected: false,
          lifecycleState: DeviceLifecycleState.paired,
        ),
      );

      expect(status.paired, isFalse);
      expect(
        bleClient.removedSystemAssociations,
        contains(MockBleClient.demoDeviceId),
      );
    });

    test('unexpected disconnect is not exposed as provisioning error',
        () async {
      final pairedStatus = await _pairDemoDevice(runtimeProvider);
      expect(pairedStatus.provisioningError, isNull);
      final emittedStatuses = <DeviceStatus>[];
      final subscription =
          runtimeProvider.watchRuntimeStatus().listen(emittedStatuses.add);

      try {
        await bleClient.setAdapterState(BleAdapterState.poweredOff);
        await Future<void>.delayed(Duration.zero);

        expect(emittedStatuses, isNotEmpty);
        expect(emittedStatuses.last.connected, isFalse);
        expect(emittedStatuses.last.provisioningError, isNull);
      } finally {
        await subscription.cancel();
      }
    });

    test('disconnect status is published before notification cleanup',
        () async {
      await _pairDemoDevice(runtimeProvider);
      final emittedStatuses = <DeviceStatus>[];
      final subscription =
          runtimeProvider.watchRuntimeStatus().listen(emittedStatuses.add);

      try {
        await bleClient.setAdapterState(BleAdapterState.poweredOff);
        await Future<void>.delayed(Duration.zero);

        final lifecycleEvents = BleDebugRegistry.instance.currentState.events
            .map((event) => event.message)
            .where((message) => message.startsWith('BLE_RECONNECT_LIFECYCLE'))
            .toList();
        final publishedIndex = lifecycleEvents.indexOf(
          'BLE_RECONNECT_LIFECYCLE disconnect_status_published=true',
        );
        final cleanupIndex = lifecycleEvents.indexOf(
          'BLE_RECONNECT_LIFECYCLE notification_cleanup_completed=true',
        );
        expect(emittedStatuses.last.connected, isFalse);
        expect(publishedIndex, greaterThanOrEqualTo(0));
        expect(cleanupIndex, greaterThan(publishedIndex));
      } finally {
        await subscription.cancel();
      }
    });

    test(
      'reconnect restores readiness and retains the remote-terminal 0x04 writer',
      () async {
        await runtimeProvider.dispose();
        await bleClient.dispose();
        final controlledBleClient = _DelayedOldNotificationCleanupBleClient();
        bleClient = controlledBleClient;
        await bleClient.initialize();
        runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);

        final readyStatus = await _pairDemoDevice(runtimeProvider);
        var debugState = BleDebugRegistry.instance.currentState;
        expect(readyStatus.connected, isTrue);
        expect(debugState.commandWriterReady, isTrue);
        expect(debugState.telNotifySubscribed, isTrue);
        expect(debugState.sosNotifySubscribed, isTrue);

        final emittedStatuses = <DeviceStatus>[];
        final statusSubscription =
            runtimeProvider.watchRuntimeStatus().listen(emittedStatuses.add);
        try {
          controlledBleClient.emitUnexpectedDisconnect();
          await controlledBleClient.oldCleanupStarted.future;

          expect(emittedStatuses.last.connected, isFalse);
          expect(controlledBleClient.oldCleanupFinished.isCompleted, isFalse);
          debugState = BleDebugRegistry.instance.currentState;
          expect(debugState.commandWriterReady, isFalse);
          expect(debugState.telNotifySubscribed, isFalse);
          expect(debugState.sosNotifySubscribed, isFalse);

          final reconnectedStatus = await runtimeProvider.reconnect(
            currentStatus: emittedStatuses.last,
            preferredDevice: PreferredDevice(
              deviceId: MockBleClient.demoDeviceId,
              displayName: 'EIXAM R1 Demo',
              lastConnectedAt: DateTime.utc(2026, 8, 26),
            ),
          );

          expect(controlledBleClient.oldCleanupFinished.isCompleted, isFalse);
          expect(reconnectedStatus.connected, isTrue);
          expect(
            await controlledBleClient.isConnected(MockBleClient.demoDeviceId),
            isTrue,
          );
          debugState = BleDebugRegistry.instance.currentState;
          expect(debugState.commandWriterReady, isTrue);
          expect(debugState.telNotifySubscribed, isTrue);
          expect(debugState.sosNotifySubscribed, isTrue);

          controlledBleClient.finishOldCleanup();
          await controlledBleClient.oldCleanupFinished.future;

          expect(reconnectedStatus.connected, isTrue);
          expect(
            await controlledBleClient.isConnected(MockBleClient.demoDeviceId),
            isTrue,
          );
          debugState = BleDebugRegistry.instance.currentState;
          expect(debugState.commandWriterReady, isTrue);
          expect(debugState.telNotifySubscribed, isTrue);
          expect(debugState.sosNotifySubscribed, isTrue);
          expect(controlledBleClient.activeNotificationGeneration, 2);
          expect(
              controlledBleClient.cancelledNotificationGenerations, <int>[1]);

          // The SDK remote-terminal path reaches this attached writer after
          // selecting EixamDeviceCommand.sosCancel(). Reconnect cleanup must
          // not detach or replace the generation-2 command route.
          await runtimeProvider.deviceSosController.sendAttachedCommand(
            EixamDeviceCommand.sosCancel(forceCmdCharacteristic: true),
          );
          expect(controlledBleClient.writtenCommands.last.bytes, <int>[0x04]);
          expect(
            controlledBleClient.writtenCommands.last.usesCmdCharacteristic,
            isTrue,
          );
        } finally {
          controlledBleClient.finishOldCleanup();
          await statusSubscription.cancel();
        }
      },
    );

    test('BLE ownership transitions are not exposed as provisioning errors',
        () async {
      await _pairDemoDevice(runtimeProvider);

      final released = await runtimeProvider.suspendOwnership(
        reason: 'native protection mode',
      );
      expect(await bleClient.isConnected(MockBleClient.demoDeviceId), isFalse);
      final restored = await runtimeProvider.resumeOwnership(
        reason: 'app foreground',
      );

      expect(released?.provisioningError, isNull);
      expect(restored?.provisioningError, isNull);
    });

    test('native ownership guard prevents Flutter GATT creation', () async {
      await expectLater(
        runtimeProvider.reconnect(
          currentStatus: buildDeviceStatus(
            deviceId: MockBleClient.demoDeviceId,
            paired: true,
            activated: true,
            connected: false,
            lifecycleState: DeviceLifecycleState.paired,
          ),
          preferredDevice: PreferredDevice(
            deviceId: MockBleClient.demoDeviceId,
            displayName: 'EIXAM R1 Demo',
            lastConnectedAt: DateTime.utc(2026, 9, 21),
          ),
          canCreateGatt: () => false,
        ),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_FLUTTER_BLE_OWNERSHIP_SUPPRESSED',
          ),
        ),
      );

      expect(await bleClient.isConnected(MockBleClient.demoDeviceId), isFalse);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) => event.message.contains(
            'SOS_FLUTTER_RECONNECT_SUPPRESSED reason=native_owner',
          ),
        ),
        isTrue,
      );
    });

    test('reconnect rejects known device when phone Bluetooth bond is missing',
        () async {
      bleClient.systemAssociationAvailable = false;

      await expectLater(
        runtimeProvider.reconnect(
          currentStatus: buildDeviceStatus(
            deviceId: MockBleClient.demoDeviceId,
            paired: true,
            activated: true,
            connected: false,
            lifecycleState: DeviceLifecycleState.paired,
          ),
          preferredDevice: PreferredDevice(
            deviceId: MockBleClient.demoDeviceId,
            displayName: 'EIXAM R1 Demo',
            lastConnectedAt: DateTime.utc(2026, 5, 7),
          ),
        ),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_MOBILE_BOND_REQUIRED',
          ),
        ),
      );

      expect(await bleClient.isConnected(MockBleClient.demoDeviceId), isFalse);
    });

    test('reconnect preserves typed iOS pairing information removed error',
        () async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
      bleClient = _FailingConnectMockBleClient(
        const DeviceException.bleIosPairingInformationRemoved(),
      );
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);

      await expectLater(
        runtimeProvider.reconnect(
          currentStatus: buildDeviceStatus(
            deviceId: MockBleClient.demoDeviceId,
            paired: true,
            activated: true,
            connected: false,
            lifecycleState: DeviceLifecycleState.paired,
          ),
          preferredDevice: PreferredDevice(
            deviceId: MockBleClient.demoDeviceId,
            displayName: 'EIXAM R1 Demo',
            lastConnectedAt: DateTime.utc(2026, 5, 7),
          ),
        ),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            DeviceException.bleIosPairingInformationRemovedCode,
          ),
        ),
      );

      expect(await bleClient.isConnected(MockBleClient.demoDeviceId), isFalse);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains(
          'BLE_RECONNECT_STOPPED reason=mobile_bond_missing '
          'device_identity_present=true',
        ),
      );
    });

    test('iOS reconnect resolves logical preferred id through unique scan',
        () async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
      bleClient = _IosReconnectMockBleClient(
        scanResults: <BleScanResult>[
          _iosScanResult(
            deviceId: _IosReconnectMockBleClient.resolvedRemoteId,
            name: 'EIXAM R1 Demo',
          ),
        ],
      );
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(
        bleClient: bleClient,
        isIosPlatform: () => true,
      );

      final status = await runtimeProvider.reconnect(
        currentStatus: buildDeviceStatus(
          deviceId: 'EA04',
          canonicalHardwareId: 'EA04',
          paired: true,
          activated: true,
          connected: false,
          lifecycleState: DeviceLifecycleState.paired,
        ),
        preferredDevice: PreferredDevice(
          deviceId: 'EA04',
          displayName: 'EIXAM R1 Demo',
          lastConnectedAt: DateTime.utc(2026, 5, 7),
        ),
        attemptId: 'attempt-ios-1',
      );

      final iosClient = bleClient as _IosReconnectMockBleClient;
      expect(iosClient.scanCallCount, 1);
      expect(iosClient.connectCalls, <String>[
        _IosReconnectMockBleClient.resolvedRemoteId,
      ]);
      expect(status.connected, isTrue);
      expect(status.deviceId, _IosReconnectMockBleClient.resolvedRemoteId);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains(
          'IOS_RECONNECT_SCAN_RESOLVE_DONE '
          'reason=known_identity_match attempt_present=true '
          'remoteId=1111...1111',
        ),
      );
    });

    test('iOS reconnect fails closed when scan candidates are ambiguous',
        () async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
      bleClient = _IosReconnectMockBleClient(
        scanResults: <BleScanResult>[
          _iosScanResult(
            deviceId: _IosReconnectMockBleClient.resolvedRemoteId,
            name: 'EIXAM R1 Demo',
            canonicalHardwareId: null,
          ),
          _iosScanResult(
            deviceId: '22222222-2222-2222-2222-222222222222',
            name: 'EIXAM R1 Other',
            canonicalHardwareId: null,
          ),
        ],
      );
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(
        bleClient: bleClient,
        isIosPlatform: () => true,
      );

      await expectLater(
        runtimeProvider.reconnect(
          currentStatus: buildDeviceStatus(
            deviceId: 'EA04',
            canonicalHardwareId: 'EA04',
            paired: true,
            activated: true,
            connected: false,
            lifecycleState: DeviceLifecycleState.paired,
          ),
          preferredDevice: PreferredDevice(
            deviceId: 'EA04',
            displayName: 'Stored EIXAM Device',
            lastConnectedAt: DateTime.utc(2026, 5, 7),
          ),
          attemptId: 'attempt-ios-ambiguous',
        ),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_INVALID_BLE_REMOTE_ID',
          ),
        ),
      );

      final iosClient = bleClient as _IosReconnectMockBleClient;
      expect(iosClient.scanCallCount, 1);
      expect(iosClient.connectCalls, isEmpty);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains(
          'IOS_RECONNECT_SCAN_RESOLVE_FAILED '
          'reason=no_unique_eixam_candidate '
          'attempt_present=true',
        ),
      );
    });
  });
}

Future<DeviceStatus> _pairDemoDevice(
  BleDeviceRuntimeProvider runtimeProvider,
) async {
  BleDebugRegistry.instance
      .update(selectedDeviceId: MockBleClient.demoDeviceId);
  return runtimeProvider.pair(
    currentStatus: buildDeviceStatus(
      paired: false,
      activated: false,
      connected: false,
      lifecycleState: DeviceLifecycleState.unpaired,
    ),
    pairingCode: '1234',
  );
}

BleScanResult _iosScanResult({
  required String deviceId,
  required String name,
  String? canonicalHardwareId = 'EA04',
}) {
  return BleScanResult(
    deviceId: deviceId,
    canonicalHardwareId: canonicalHardwareId,
    name: name,
    rssi: -48,
    connectable: true,
    advertisedServiceUuids: const <String>[EixamBleProtocol.serviceUuid],
    discoveredAt: DateTime.utc(2026, 5, 7),
  );
}

final class _IosReconnectMockBleClient extends MockBleClient {
  _IosReconnectMockBleClient({required this.scanResults});

  static const resolvedRemoteId = '11111111-1111-1111-1111-111111111111';

  final List<BleScanResult> scanResults;
  final List<String> connectCalls = <String>[];
  int scanCallCount = 0;

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    scanCallCount++;
    return scanResults;
  }

  @override
  Future<void> connect(String deviceId) async {
    connectCalls.add(deviceId);
    await super.connect(MockBleClient.demoDeviceId);
  }

  @override
  Future<void> disconnect(String deviceId) {
    return super.disconnect(MockBleClient.demoDeviceId);
  }

  @override
  Future<bool> isConnected(String deviceId) {
    return super.isConnected(MockBleClient.demoDeviceId);
  }

  @override
  Stream<bool> watchConnection(String deviceId) {
    return super.watchConnection(MockBleClient.demoDeviceId);
  }

  @override
  Future<Stream<EixamBleNotification>> subscribeEixamNotifications(
    String deviceId,
  ) {
    return super.subscribeEixamNotifications(MockBleClient.demoDeviceId);
  }

  @override
  Future<void> writeDeviceCommand(String deviceId, EixamDeviceCommand command) {
    return super.writeDeviceCommand(MockBleClient.demoDeviceId, command);
  }

  @override
  Future<bool> isEixamCompatible(String deviceId) async => true;

  @override
  Future<int?> readBatteryLevel(String deviceId) {
    return super.readBatteryLevel(MockBleClient.demoDeviceId);
  }

  @override
  Future<int?> readSignalQuality(String deviceId) {
    return super.readSignalQuality(MockBleClient.demoDeviceId);
  }

  @override
  Future<String?> readFirmwareVersion(String deviceId) {
    return super.readFirmwareVersion(MockBleClient.demoDeviceId);
  }
}

final class _FailingConnectMockBleClient extends MockBleClient {
  _FailingConnectMockBleClient(this.error);

  final Object error;

  @override
  Future<void> connect(String deviceId) async {
    throw error;
  }
}

final class _DelayedOldNotificationCleanupBleClient extends MockBleClient {
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast(sync: true);
  final Completer<void> _oldCleanupGate = Completer<void>();
  final Completer<void> oldCleanupStarted = Completer<void>();
  final Completer<void> oldCleanupFinished = Completer<void>();
  final List<StreamController<EixamBleNotification>> _notificationControllers =
      <StreamController<EixamBleNotification>>[];
  final List<int> cancelledNotificationGenerations = <int>[];

  int activeNotificationGeneration = 0;

  void emitUnexpectedDisconnect() => _connectionController.add(false);

  void finishOldCleanup() {
    if (!_oldCleanupGate.isCompleted) _oldCleanupGate.complete();
  }

  @override
  Stream<bool> watchConnection(String deviceId) => _connectionController.stream;

  @override
  Future<Stream<EixamBleNotification>> subscribeEixamNotifications(
    String deviceId,
  ) async {
    final generation = ++activeNotificationGeneration;
    final controller = StreamController<EixamBleNotification>.broadcast(
      sync: true,
      onCancel: () async {
        if (generation == 1) {
          if (!oldCleanupStarted.isCompleted) oldCleanupStarted.complete();
          await _oldCleanupGate.future;
          if (!oldCleanupFinished.isCompleted) oldCleanupFinished.complete();
        }
        cancelledNotificationGenerations.add(generation);
      },
    );
    _notificationControllers.add(controller);
    BleDebugRegistry.instance.update(
      telNotifySubscribed: true,
      sosNotifySubscribed: true,
    );
    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    finishOldCleanup();
    for (final controller in _notificationControllers) {
      await controller.close();
    }
    await _connectionController.close();
    await super.dispose();
  }
}

final class _OverlappingHydrationBleClient extends MockBleClient {
  static const Duration overlapDelay = Duration(milliseconds: 40);

  final Map<String, DateTime> startedAt = <String, DateTime>{};

  Future<T> _overlap<T>(
    String name,
    Future<T> Function() action,
  ) async {
    startedAt[name] = DateTime.now();
    await Future<void>.delayed(overlapDelay);
    return action();
  }

  @override
  Future<void> writeDeviceCommand(
    String deviceId,
    EixamDeviceCommand command,
  ) {
    if (command.opcode != 0x23) {
      return super.writeDeviceCommand(deviceId, command);
    }
    return _overlap(
      'status',
      () => super.writeDeviceCommand(deviceId, command),
    );
  }

  @override
  Future<String?> readFirmwareVersion(String deviceId) {
    return _overlap('firmware', () => super.readFirmwareVersion(deviceId));
  }

  @override
  Future<int?> readSignalQuality(String deviceId) {
    return _overlap('rssi', () => super.readSignalQuality(deviceId));
  }
}
