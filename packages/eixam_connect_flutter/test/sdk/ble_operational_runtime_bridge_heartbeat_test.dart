import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_cluster_heartbeat_packet.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/ble_operational_runtime_bridge.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  group('BleOperationalRuntimeBridge heartbeat', () {
    late StreamController<BleIncomingEvent> bleEvents;
    late StreamController<RealtimeConnectionState> connectionStates;
    late StreamController<RealtimeEvent> realtimeEvents;
    late FakeTelemetryRepository telemetryRepository;
    late FakeSosRepository sosRepository;
    late DeviceSosController deviceSosController;
    late BleOperationalRuntimeBridge bridge;
    EixamSession? currentSession;

    setUp(() {
      bleEvents = StreamController<BleIncomingEvent>.broadcast();
      connectionStates = StreamController<RealtimeConnectionState>.broadcast();
      realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      telemetryRepository = FakeTelemetryRepository();
      sosRepository = FakeSosRepository();
      deviceSosController = DeviceSosController();
      currentSession = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
        canonicalExternalUserId: 'partner/user 42',
      );
      bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => currentSession,
      );
      bridge.start();
      connectionStates.add(RealtimeConnectionState.connected);
    });

    tearDown(() async {
      await bridge.dispose();
      await bleEvents.close();
      await connectionStates.close();
      await realtimeEvents.close();
      await sosRepository.dispose();
    });

    test('publishes cluster heartbeat events through the telemetry repository',
        () async {
      final packet = EixamClusterHeartbeatPacket.tryParse(
        const <int>[
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
      )!;

      bleEvents.add(
        BleIncomingEvent(
          deviceId: 'ble-demo-r1',
          canonicalHardwareId: 'CF:82:00:00:00:01',
          type: BleIncomingEventType.clusterHeartbeat,
          channel: EixamBleChannel.tel,
          payload: packet.rawBytes,
          payloadHex: packet.rawHex,
          source: DeviceSosTransitionSource.device,
          receivedAt: DateTime.utc(2026, 4, 22, 10, 15),
          meshPort: 260,
          clusterHeartbeatPacket: packet,
        ),
      );

      await Future<void>.delayed(Duration.zero);

      expect(telemetryRepository.publishedPayloads, hasLength(1));
      final payload = telemetryRepository.publishedPayloads.single;
      expect(payload.kind, 'HEARTBEAT');
      expect(payload.nodeId, 0x12345678);
      expect(payload.clusterId, 0xABCD);
      expect(payload.aggId, 0x89ABCDEF);
      expect(payload.score, 0x9A);
      expect(payload.memberCount, 5);
      expect(payload.aggSpreadingFactor, 7);
      expect(payload.deviceId, 'CF:82:00:00:00:01');
      expect(payload.latitude, 0);
      expect(payload.longitude, 0);
      expect(payload.altitude, 0);
      expect(
        bridge.currentDiagnostics.lastBleTelemetryEventSummary,
        contains('heartbeat'),
      );
    });

    test(
        'mqtt telemetry envelope preserves heartbeat metadata for backend ingest',
        () {
      final envelope = SdkMqttContract.buildTelemetryEnvelope(
        session: const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          sdkUserId: 'sdk-user-42',
          canonicalExternalUserId: 'partner/user 42',
        ),
        payload: SdkTelemetryPayload(
          timestamp: DateTime.utc(2026, 4, 22, 10, 15),
          latitude: 0,
          longitude: 0,
          altitude: 0,
          kind: 'HEARTBEAT',
          nodeId: 0x12345678,
          clusterId: 0xABCD,
          aggId: 0x89ABCDEF,
          score: 0x9A,
          memberCount: 5,
          aggSpreadingFactor: 7,
          deviceId: 'CF:82:00:00:00:01',
        ),
      );

      final decoded = jsonDecode(envelope.payload) as Map<String, dynamic>;
      expect(envelope.topic, 'tel/sdk-user-42/data');
      expect(decoded['kind'], 'HEARTBEAT');
      expect(decoded['nodeId'], 0x12345678);
      expect(decoded['clusterId'], 0xABCD);
      expect(decoded['aggId'], 0x89ABCDEF);
      expect(decoded['score'], 0x9A);
      expect(decoded['memberCount'], 5);
      expect(decoded['aggSpreadingFactor'], 7);
      expect(decoded['deviceId'], 'CF:82:00:00:00:01');
    });
  });
}
