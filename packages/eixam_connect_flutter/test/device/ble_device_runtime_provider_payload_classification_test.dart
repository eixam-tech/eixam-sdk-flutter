import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/mock_ble_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';

void main() {
  group('BleDeviceRuntimeProvider payload classification', () {
    late MockBleClient bleClient;
    late BleDeviceRuntimeProvider runtimeProvider;

    setUp(() async {
      BleDebugRegistry.instance.reset();
      bleClient = MockBleClient();
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
      await _pairDemoDevice(runtimeProvider);
    });

    tearDown(() async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
    });

    test('classifies a 12-byte TEL notify as SOS when SOS decode is valid',
        () async {
      await runtimeProvider.requestDeviceRuntimeStatus();
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.tel,
        payload: const <int>[
          0x34,
          0x12,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x40,
        ],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.sosMeshPacket);
      expect(event.classification.kind, BleIncomingPayloadKind.ownDeviceSos);
      expect(event.sosPacket?.nodeId, 0x1234);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        isNot(DeviceSosState.inactive),
      );
    });

    test(
        'classifies valid SOS notify with unknown connected node as unknown origin and keeps local SOS inactive',
        () async {
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.sos,
        payload: const <int>[
          0x78,
          0x56,
          0x34,
          0x12,
          0x00,
          0x40,
          0x09,
        ],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.sosMeshPacket);
      expect(
          event.classification.kind, BleIncomingPayloadKind.unknownOriginSos);
      expect(event.sosPacket?.nodeId, 0x12345678);
      expect(event.remoteRelaySosSnapshot, isNull);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
    });

    test(
        'classifies valid TEL SOS with unknown connected node as unknown origin instead of TEL or own SOS',
        () async {
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.tel,
        payload: const <int>[
          0x78,
          0x56,
          0x34,
          0x12,
          0x48,
          0xCD,
          0x1B,
          0x34,
          0x44,
          0x28,
          0x00,
          0x40,
        ],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.unknownProtocolPacket);
      expect(
          event.classification.kind, BleIncomingPayloadKind.unknownOriginSos);
      expect(event.telPacket, isNull);
      expect(event.sosPacket, isNull);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
    });

    test(
        'classifies a 12-byte TEL SOS from another node as remote relay and keeps local SOS inactive',
        () async {
      await runtimeProvider.requestDeviceRuntimeStatus();
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.tel,
        payload: const <int>[
          0x78,
          0x56,
          0x34,
          0x12,
          0x48,
          0xCD,
          0x1B,
          0x34,
          0x44,
          0x28,
          0x00,
          0x40,
        ],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.sosMeshPacket);
      expect(event.classification.kind, BleIncomingPayloadKind.remoteRelaySos);
      expect(event.remoteRelaySosSnapshot, isNotNull);
      expect(event.remoteRelaySosSnapshot!.originatorNodeId, 0x12345678);
      expect(event.remoteRelaySosSnapshot!.relayNodeId, 0x1234);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
    });

    test(
        'classifies a 7-byte SOS notify from another node as remote relay without location',
        () async {
      await runtimeProvider.requestDeviceRuntimeStatus();
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.sos,
        payload: const <int>[
          0x78,
          0x56,
          0x34,
          0x12,
          0x00,
          0x40,
          0x09,
        ],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.sosMeshPacket);
      expect(event.classification.kind, BleIncomingPayloadKind.remoteRelaySos);
      expect(event.remoteRelaySosSnapshot, isNotNull);
      expect(event.remoteRelaySosSnapshot!.location, isNull);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
    });

    test(
        'classifies an SOS notify E1 02 for another node as a remote clear event',
        () async {
      await runtimeProvider.requestDeviceRuntimeStatus();
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.sos,
        payload: const <int>[0xE1, 0x02, 0x78, 0x56, 0x34, 0x12],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.sosDeviceEvent);
      expect(event.classification.kind, BleIncomingPayloadKind.sosClear);
      expect(event.remoteRelaySosSnapshot, isNotNull);
      expect(event.remoteRelaySosSnapshot!.kind, RemoteRelaySosKind.clear);
      expect(event.remoteRelaySosSnapshot!.originatorNodeId, 0x12345678);
      expect(event.remoteRelaySosSnapshot!.relayNodeId, 0x1234);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
    });

    test('classifies a 12-byte TEL notify as TEL when SOS decode is not valid',
        () async {
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.tel,
        payload: const <int>[
          0x78,
          0x56,
          0x34,
          0x12,
          0x01,
          0x02,
          0x03,
          0x04,
          0x05,
          0x06,
          0x87,
          0x25,
        ],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.telPosition);
      expect(event.telPacket?.nodeId, 0x12345678);
    });

    test('classifies a port 260 12-byte TEL notify as cluster heartbeat',
        () async {
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.tel,
        meshPort: 260,
        payload: const <int>[
          0x78,
          0x56,
          0x34,
          0x12,
          0x9A,
          0xCD,
          0xAB,
          0xEF,
          0xCD,
          0xAB,
          0x89,
          0x57,
        ],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.clusterHeartbeat);
      expect(event.meshPort, 260);
      expect(event.clusterHeartbeatPacket?.nodeId, 0x12345678);
      expect(event.clusterHeartbeatPacket?.clusterId, 0xABCD);
      expect(event.clusterHeartbeatPacket?.aggId, 0x89ABCDEF);
      expect(event.clusterHeartbeatPacket?.memberCount, 5);
      expect(event.clusterHeartbeatPacket?.aggSpreadingFactor, 7);
    });

    test('ignores unknown TEL payloads safely', () async {
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.tel,
        payload: const <int>[0x99, 0x88, 0x77],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.unknownProtocolPacket);
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

Future<BleIncomingEvent> _nextIncomingEvent(
  BleDeviceRuntimeProvider runtimeProvider,
) {
  return runtimeProvider.watchIncomingEvents().first;
}
