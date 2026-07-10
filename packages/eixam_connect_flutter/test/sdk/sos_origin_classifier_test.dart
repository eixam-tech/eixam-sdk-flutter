import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_payload_classifier.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/sdk/relay_ingest_context.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_origin_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SOS origin classifier decision table', () {
    test('strong own node identity is local and actionable', () {
      final decision = classifySosOrigin(
        source: 'ble_device_runtime_status',
        originatorNodeId: 0x1234,
        boundNodeId: 0x1234,
      );

      expect(decision.actionability, SosActionability.localActionable);
      expect(decision.originKind, SosOriginKind.ownDevice);
      expect(decision.displaySurface, SosDisplaySurface.activeAndHistory);
      expect(decision.localStateMutation, isTrue);
      expect(decision.publicIncident, isTrue);
      expect(decision.reason, 'own_device_identity_match');
    });

    test('strong different originator node with relay evidence is external',
        () {
      final decision = classifySosOrigin(
        source: 'remote_relay',
        originatorNodeId: 0x01020304,
        relayNodeId: 0x0A0B0C0D,
        boundNodeId: 0x0A0B0C0D,
      );

      expect(decision.actionability, SosActionability.externalOnly);
      expect(decision.originKind, SosOriginKind.remoteRelay);
      expect(decision.displaySurface, SosDisplaySurface.historyOnly);
      expect(decision.localStateMutation, isFalse);
      expect(decision.publicIncident, isFalse);
    });

    test('hardware id match disambiguates own device', () {
      final decision = classifySosOrigin(
        source: 'ble_device_runtime_confirm',
        hardwareId: 'CF:82:59:4B:1A:A8',
        boundHardwareId: 'cf:82:59:4b:1a:a8',
      );

      expect(decision.actionability, SosActionability.localActionable);
      expect(decision.originKind, SosOriginKind.ownDevice);
      expect(decision.reason, 'own_device_identity_match');
    });

    test('relay ingest context keeps remote device separate from gateway', () {
      const context = RelayIngestContext(
        kind: RelayIngestKind.sos,
        remoteDeviceId: '16909060',
        gatewayRuntimeDeviceId: 'relay-tag',
        gatewayCanonicalHardwareId: 'relay-node',
        payloadSignature: 'remote-relay:16909060',
        relayCount: 1,
      );

      final decision = classifySosOrigin(
        source: 'remote_lora_relay',
        relaySource: 'remote_lora_relay',
        deviceId: context.remoteDeviceId,
        hardwareId: 'remote-node',
        boundDeviceId: context.gatewayRuntimeDeviceId,
        boundHardwareId: context.gatewayCanonicalHardwareId,
        relayNodeId: 0x0A0B0C0D,
      );

      expect(context.remoteDeviceId, isNot(context.gatewayRuntimeDeviceId));
      expect(decision.actionability, SosActionability.externalOnly);
      expect(decision.originKind, SosOriginKind.remoteRelay);
      expect(decision.localStateMutation, isFalse);
      expect(decision.reason, 'explicit_lora_relay_source');
    });

    test('unknown non-SOS packet remains unknown and ignored', () {
      final decision = classifySosOrigin(source: 'unparsed_payload');
      final classification =
          const BleIncomingPayloadClassifier().classifySosPayload(
        payload: const <int>[0x01, 0x02, 0x03],
        payloadHex: '010203',
        receivedAt: DateTime.utc(2026, 6, 29, 12),
        source: DeviceSosTransitionSource.device,
        channel: EixamBleChannel.sos,
        connectedBleTagNodeId: null,
        fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
          kind: BleIncomingPayloadKind.remoteRelaySos,
        ),
      );

      expect(decision.actionability, SosActionability.unknown);
      expect(decision.originKind, SosOriginKind.unknown);
      expect(decision.publicIncident, isFalse);
      expect(classification.kind, BleIncomingPayloadKind.unknown);
      expect(classification.remoteRelaySosSnapshot, isNull);
    });

    test(
        'fallbackOnUnknownConnectedNode conservatively treats unresolved active SOS as remote relay',
        () {
      final payload = _sosPayloadForNode(0x12345678);
      final classification =
          const BleIncomingPayloadClassifier().classifySosPayload(
        payload: payload,
        payloadHex: EixamBleProtocol.hex(payload),
        receivedAt: DateTime.utc(2026, 6, 29, 12),
        source: DeviceSosTransitionSource.device,
        channel: EixamBleChannel.sos,
        connectedBleTagNodeId: null,
        fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
          kind: BleIncomingPayloadKind.remoteRelaySos,
        ),
      );

      expect(classification.kind, BleIncomingPayloadKind.remoteRelaySos);
      expect(
          classification.remoteRelaySosSnapshot?.originatorNodeId, 0x12345678);
      expect(classification.remoteRelaySosSnapshot?.relayNodeId, isNull);
    });
  });
}

List<int> _sosPayloadForNode(int nodeId) {
  return <int>[
    nodeId & 0xFF,
    (nodeId >> 8) & 0xFF,
    (nodeId >> 16) & 0xFF,
    (nodeId >> 24) & 0xFF,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x80,
  ];
}
