import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_payload_classifier.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/device/mock_ble_client.dart';

const double _decoded12ByteRemoteRelayLatitude = -38.8117790222168;
const double _decoded12ByteRemoteRelayLongitude = 72.09365844726562;

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
      final nextEvent = runtimeProvider.watchIncomingEvents().firstWhere(
            (event) => event.type == BleIncomingEventType.sosMeshPacket,
          );

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

    test('relay origin decision table preserves own, relay, and fallback cases',
        () {
      final classifier = const BleIncomingPayloadClassifier();
      final payload = _sosPayloadForNode(0x1234);
      final payloadHex = EixamBleProtocol.hex(payload);

      BleIncomingPayloadClassification classify({
        required int? connectedNodeId,
        required BleIncomingPayloadKind fallbackKind,
      }) {
        return classifier.classifySosPayload(
          payload: payload,
          payloadHex: payloadHex,
          receivedAt: DateTime.utc(2026, 6, 29, 8),
          source: DeviceSosTransitionSource.device,
          channel: EixamBleChannel.sos,
          connectedBleTagNodeId: connectedNodeId,
          fallbackOnUnknownConnectedNode: BleIncomingPayloadClassification(
            kind: fallbackKind,
          ),
        );
      }

      final own = classify(
        connectedNodeId: 0x1234,
        fallbackKind: BleIncomingPayloadKind.remoteRelaySos,
      );
      final relay = classify(
        connectedNodeId: 0x5678,
        fallbackKind: BleIncomingPayloadKind.unknownOriginSos,
      );
      final unknownFallback = classify(
        connectedNodeId: null,
        fallbackKind: BleIncomingPayloadKind.unknownOriginSos,
      );
      final remoteFallback = classify(
        connectedNodeId: null,
        fallbackKind: BleIncomingPayloadKind.remoteRelaySos,
      );

      expect(own.kind, BleIncomingPayloadKind.ownDeviceSos);
      expect(own.remoteRelaySosSnapshot, isNull);
      expect(relay.kind, BleIncomingPayloadKind.remoteRelaySos);
      expect(relay.remoteRelaySosSnapshot?.relayNodeId, 0x5678);
      expect(unknownFallback.kind, BleIncomingPayloadKind.unknownOriginSos);
      expect(unknownFallback.remoteRelaySosSnapshot, isNull);
      expect(remoteFallback.kind, BleIncomingPayloadKind.remoteRelaySos);
      expect(remoteFallback.remoteRelaySosSnapshot?.originatorNodeId, 0x1234);
      expect(remoteFallback.remoteRelaySosSnapshot?.relayNodeId, isNull);
    });

    test(
        'recovers connected node identity before holding a device-originated SOS',
        () async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
      BleDebugRegistry.instance.reset();

      bleClient = MockBleClient()..runtimeStatusPayload = const <int>[0x99];
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
      await _pairDemoDevice(runtimeProvider);

      expect(
        (await runtimeProvider.getRuntimeIdentitySnapshot(
          buildDeviceStatus(connected: true),
        ))
            .connectedBleNodeId,
        isNull,
      );

      bleClient.runtimeStatusPayload = <int>[
        0xE9,
        0x78,
        0x02,
        0x02,
        0x03,
        0x07,
        0x1F,
        0x34,
        0x12,
        0x00,
        0x00,
        88,
        0x3C,
        0x00,
      ];
      final nextEvent = runtimeProvider.watchIncomingEvents().firstWhere(
            (event) => event.type == BleIncomingEventType.sosMeshPacket,
          );
      final nextSosStatus = runtimeProvider.deviceSosController
          .watchStatus()
          .firstWhere((status) => status.state == DeviceSosState.preConfirm);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.sos,
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
      final status = await nextSosStatus.timeout(
        const Duration(seconds: 2),
      );
      expect(event.type, BleIncomingEventType.sosMeshPacket);
      expect(event.classification.kind, BleIncomingPayloadKind.ownDeviceSos);
      expect(status.nodeId, 0x1234);
      expect(status.packetId, 0);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) =>
              event.message.contains('SOS unknown origin reclassified') &&
              event.message.contains('role=ownDeviceSos'),
        ),
        isTrue,
      );
    });

    test(
        'unresolved active relay SOS falls back to remote relay instead of ignored unknown',
        () async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
      BleDebugRegistry.instance.reset();

      bleClient = MockBleClient()..runtimeStatusPayload = const <int>[0x99];
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
      await _pairDemoDevice(runtimeProvider);

      expect(
        (await runtimeProvider.getRuntimeIdentitySnapshot(
          buildDeviceStatus(connected: true),
        ))
            .connectedBleNodeId,
        isNull,
      );

      final nextEvent = runtimeProvider.watchIncomingEvents().firstWhere(
            (event) => event.type == BleIncomingEventType.sosMeshPacket,
          );

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.sos,
        payload: _sosPayloadForNode(0x12345678),
      );

      final event = await nextEvent.timeout(const Duration(seconds: 3));
      expect(event.classification.kind, BleIncomingPayloadKind.remoteRelaySos);
      expect(event.remoteRelaySosSnapshot, isNotNull);
      expect(event.remoteRelaySosSnapshot!.originatorNodeId, 0x12345678);
      expect(event.remoteRelaySosSnapshot!.relayNodeId, isNull);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
      expect(
        BleDebugRegistry.instance.currentState.lastDecodedIncomingEventType,
        BleIncomingEventType.sosMeshPacket.name,
      );
      expect(
        BleDebugRegistry.instance.currentState.lastDecodeOutcome,
        BleIncomingEventType.sosMeshPacket.name,
      );
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) =>
              event.message.contains('SOS unknown origin fallback') &&
              event.message.contains('role=remoteRelaySos'),
        ),
        isTrue,
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
      expect(event.remoteRelaySosSnapshot!.location, isNotNull);
      expect(event.remoteRelaySosSnapshot!.location!.latitude,
          closeTo(_decoded12ByteRemoteRelayLatitude, 0.000001));
      expect(event.remoteRelaySosSnapshot!.location!.longitude,
          closeTo(_decoded12ByteRemoteRelayLongitude, 0.000001));
      expect(event.remoteRelaySosSnapshot!.location!.altitude, 800);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
    });

    test('classifies a 12-byte SOS notify as remote relay with packet location',
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
      final snapshot = event.remoteRelaySosSnapshot;
      expect(event.type, BleIncomingEventType.sosMeshPacket);
      expect(event.classification.kind, BleIncomingPayloadKind.remoteRelaySos);
      expect(snapshot, isNotNull);
      expect(snapshot!.originatorNodeId, 0x12345678);
      expect(snapshot.relayNodeId, 0x1234);
      expect(snapshot.location, isNotNull);
      expect(snapshot.location!.latitude,
          closeTo(_decoded12ByteRemoteRelayLatitude, 0.000001));
      expect(snapshot.location!.longitude,
          closeTo(_decoded12ByteRemoteRelayLongitude, 0.000001));
      expect(snapshot.location!.altitude, 800);
    });

    test(
        'classifies a D2 embedded 12-byte SOS as remote relay with packet location',
        () async {
      await runtimeProvider.requestDeviceRuntimeStatus();
      final nextEvent = _nextIncomingEvent(runtimeProvider);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.tel,
        payload: const <int>[
          0xD2,
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
          0xF6,
          0xC4,
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
          0x87,
          0x25,
        ],
      );

      final event = await nextEvent;
      expect(event.type, BleIncomingEventType.telRelayRx);
      expect(event.classification.kind, BleIncomingPayloadKind.remoteRelaySos);
      expect(event.remoteRelaySosSnapshot, isNotNull);
      expect(
          event.remoteRelaySosSnapshot!.source, RemoteRelaySosSource.d2Relay);
      expect(event.remoteRelaySosSnapshot!.originatorNodeId, 0x12345678);
      expect(event.remoteRelaySosSnapshot!.relayNodeId, 0x1234);
      expect(event.remoteRelaySosSnapshot!.location, isNotNull);
      expect(
        event.remoteRelaySosSnapshot!.payloadHex,
        '78 56 34 12 48 cd 1b 34 44 28 00 40',
      );
      expect(event.remoteRelaySosSnapshot!.location!.latitude,
          closeTo(_decoded12ByteRemoteRelayLatitude, 0.000001));
      expect(event.remoteRelaySosSnapshot!.location!.longitude,
          closeTo(_decoded12ByteRemoteRelayLongitude, 0.000001));
      expect(event.remoteRelaySosSnapshot!.location!.altitude, 800);
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
        'classifies an SOS notify E1 02 for another node as a remote cancel event',
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
      expect(event.classification.kind, BleIncomingPayloadKind.sosCancel);
      expect(event.remoteRelaySosSnapshot, isNotNull);
      expect(event.remoteRelaySosSnapshot!.kind, RemoteRelaySosKind.cancel);
      expect(event.remoteRelaySosSnapshot!.originatorNodeId, 0x12345678);
      expect(event.remoteRelaySosSnapshot!.relayNodeId, 0x1234);
      expect(
        (await runtimeProvider.deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
    });

    test(
        'recovers connected node identity before holding a device cancel event',
        () async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
      BleDebugRegistry.instance.reset();

      bleClient = MockBleClient()..runtimeStatusPayload = const <int>[0x99];
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
      await _pairDemoDevice(runtimeProvider);

      bleClient.runtimeStatusPayload = <int>[
        0xE9,
        0x78,
        0x02,
        0x02,
        0x03,
        0x07,
        0x1F,
        0x34,
        0x12,
        0x00,
        0x00,
        88,
        0x3C,
        0x00,
      ];
      final nextEvent = runtimeProvider.watchIncomingEvents().firstWhere(
            (event) => event.type == BleIncomingEventType.sosDeviceEvent,
          );
      final nextSosStatus = runtimeProvider.deviceSosController
          .watchStatus()
          .firstWhere((status) => status.lastOpcode == 0xE1);

      bleClient.emitNotification(
        MockBleClient.demoDeviceId,
        channel: EixamBleChannel.sos,
        payload: const <int>[0xE1, 0x02, 0x34, 0x12, 0x00, 0x00],
      );

      final event = await nextEvent;
      final status = await nextSosStatus.timeout(
        const Duration(seconds: 2),
      );
      expect(event.classification.kind, BleIncomingPayloadKind.sosCancel);
      expect(event.remoteRelaySosSnapshot, isNull);
      expect(status.state, DeviceSosState.inactive);
      expect(status.nodeId, 0x1234);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) =>
              event.message.contains(
                'SOS event unknown origin reclassified',
              ) &&
              event.message.contains('role=ownDeviceEvent'),
        ),
        isTrue,
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

    test('reassembles a maximum 386-byte D3 payload into one typed batch',
        () async {
      final logicalPayload = _maximumLiveBatchPayload();
      final nextEvent = runtimeProvider.watchIncomingEvents().firstWhere(
            (event) => event.type == BleIncomingEventType.telLivePositionBatch,
          );

      for (var offset = 0; offset < logicalPayload.length; offset += 15) {
        final end = offset + 15 < logicalPayload.length
            ? offset + 15
            : logicalPayload.length;
        bleClient.emitNotification(
          MockBleClient.demoDeviceId,
          channel: EixamBleChannel.tel,
          payload: <int>[
            0xD0,
            logicalPayload.length & 0xFF,
            logicalPayload.length >> 8,
            offset & 0xFF,
            offset >> 8,
            ...logicalPayload.sublist(offset, end),
          ],
        );
      }

      final event = await nextEvent.timeout(const Duration(seconds: 2));
      expect(event.aggregatePayload, hasLength(386));
      expect(event.telLiveBatchPacket!.batch.samples, hasLength(24));
      expect(event.telLiveBatchPacket!.batch.samples.last.packetId, 7);
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

List<int> _sosPayloadForNode(int nodeId) {
  return <int>[
    nodeId & 0xFF,
    (nodeId >> 8) & 0xFF,
    (nodeId >> 16) & 0xFF,
    (nodeId >> 24) & 0xFF,
    0x00,
    0x40,
    0x09,
  ];
}

List<int> _maximumLiveBatchPayload() {
  final payload = <int>[0xD3, 24];
  for (var index = 0; index < 24; index++) {
    final timestamp = 1786102500 + index;
    payload.addAll(<int>[
      timestamp & 0xFF,
      (timestamp >> 8) & 0xFF,
      (timestamp >> 16) & 0xFF,
      (timestamp >> 24) & 0xFF,
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
      0x80 | (index % 16),
      0x25,
    ]);
  }
  return payload;
}
