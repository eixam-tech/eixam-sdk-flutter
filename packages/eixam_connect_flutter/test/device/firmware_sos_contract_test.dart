import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_payload_classifier.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_last_known_position_store.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_data.dart';
import 'package:eixam_connect_flutter/src/device/eixam_rescue_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_rescue_status_resp_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _node(int nodeId) => <int>[
      nodeId & 0xFF,
      (nodeId >> 8) & 0xFF,
      (nodeId >> 16) & 0xFF,
      (nodeId >> 24) & 0xFF,
    ];

List<int> _fullSos({
  required int sosType,
  required double latitude,
  required double longitude,
  int gpsQuality = 0,
  int speedEstimate = 0,
}) {
  final flags = EixamSosPacket.packFlags(
    sosType: sosType,
    gpsQuality: gpsQuality,
    speedEstimate: speedEstimate,
  );
  return <int>[
    ..._node(0x1234),
    ...EixamPositionData.encode(latitude: latitude, longitude: longitude),
    flags & 0xFF,
    (flags >> 8) & 0xFF,
  ];
}

void main() {
  group('firmware 2.7.50 SOS contract', () {
    const classifier = BleIncomingPayloadClassifier();
    final receivedAt = DateTime.utc(2026, 9, 1, 10);

    BleIncomingPayloadClassification classify(List<int> payload) {
      return classifier.classifySosPayload(
        payload: payload,
        payloadHex: EixamBleProtocol.hex(payload),
        receivedAt: receivedAt,
        source: DeviceSosTransitionSource.device,
        channel: EixamBleChannel.tel,
        connectedBleTagNodeId: 0x1234,
        fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
          kind: BleIncomingPayloadKind.unknownOriginSos,
        ),
      );
    }

    test('TEL at speed stays TEL despite sosType nibble', () {
      final classification = classify(
        _fullSos(
          sosType: 1,
          latitude: 42.5,
          longitude: 1.5,
          speedEstimate: 2,
        ),
      );
      expect(classification.kind, BleIncomingPayloadKind.telPosition);
      expect(classification.sosPacket, isNull);
    });

    test('7 B sosType 3 is open SOS, not a clear', () {
      final flags = EixamSosPacket.packFlags(sosType: 3);
      final classification = classify(<int>[
        ..._node(0x1234),
        flags & 0xFF,
        (flags >> 8) & 0xFF,
        0x01,
      ]);
      expect(classification.kind, BleIncomingPayloadKind.ownDeviceSos);
      expect(classification.sosPacket?.isClear, isFalse);
    });

    test('7 B sosType 0 is a clear', () {
      final classification = classify(<int>[
        ..._node(0x1234),
        0x00,
        0x00,
        0x01,
      ]);
      expect(classification.kind, BleIncomingPayloadKind.sosClear);
    });

    test('12 B Null Island with gpsQuality 2 is still SOS', () {
      final classification = classify(
        _fullSos(
          sosType: 2,
          latitude: 0,
          longitude: 0,
          gpsQuality: 2,
        ),
      );
      expect(classification.kind, BleIncomingPayloadKind.ownDeviceSos);
      expect(classification.sosPacket?.formatBitIsTelPosition, isFalse);
      expect(classification.sosPacket?.hasValidPosition, isFalse);
    });

    test('0xE3 is not a user cancel', () {
      final classification =
          classify(<int>[0xE3, 0x00, 0x34, 0x12, 0x00, 0x00]);
      expect(classification.kind, BleIncomingPayloadKind.unknown);
    });

    test('SOS GATT 12 B with bit 5 set stays SOS', () {
      final classification = classifier.classifySosPayload(
        payload: _fullSos(
          sosType: 1,
          latitude: 42.5,
          longitude: 1.5,
          speedEstimate: 2,
        ),
        payloadHex: 'sos-gatt-bit5',
        receivedAt: receivedAt,
        source: DeviceSosTransitionSource.device,
        channel: EixamBleChannel.sos,
        connectedBleTagNodeId: 0x1234,
        fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
          kind: BleIncomingPayloadKind.unknownOriginSos,
        ),
      );
      expect(classification.kind, BleIncomingPayloadKind.ownDeviceSos);
      expect(classification.sosPacket?.isActiveOnChannel(EixamBleChannel.sos),
          isTrue);
    });

    test('last-known store keeps the previous fix and its age', () {
      final store = EixamLastKnownPositionStore();
      final first = classify(
        _fullSos(sosType: 2, latitude: 42.5, longitude: 1.5),
      );
      store.bind(first, receivedAt: receivedAt);
      final later = receivedAt.add(const Duration(minutes: 8));
      final bound = store.bind(
        BleIncomingPayloadClassification(
          kind: BleIncomingPayloadKind.remoteRelaySos,
          sosPacket: EixamSosPacket.tryParse(
            _fullSos(sosType: 2, latitude: 0, longitude: 0),
          ),
          remoteRelaySosSnapshot: RemoteRelaySosSnapshot(
            kind: RemoteRelaySosKind.sos,
            originatorNodeId: 0x1234,
            source: RemoteRelaySosSource.telRelay,
            sosType: 2,
            receivedAt: later,
            rawPayload: const <int>[],
            payloadHex: '',
          ),
        ),
        receivedAt: later,
      );
      expect(bound.remoteRelaySosSnapshot?.location?.latitude,
          closeTo(42.5, 0.01));
      expect(bound.remoteRelaySosSnapshot?.location?.timestamp, receivedAt);
    });
  });

  group('Rescue wire', () {
    test('parses 9 B header and rejects the obsolete 6 B layout', () {
      final bytes = EixamRescuePacket.encode(
        targetNodeId: 0x12345678,
        fromNodeId: 0x90ABCDEF,
        command: EixamBleProtocol.rescueCmdAckSos,
      );
      expect(bytes.length, 9);
      final packet = EixamRescuePacket.tryParse(bytes);
      expect(packet, isNotNull);
      expect(packet!.isAckSos, isTrue);
      expect(
          EixamRescuePacket.tryParse(<int>[0x78, 0x56, 0x34, 0x12, 0x02, 0x00]),
          isNull);
    });

    test('parses 14 B STATUS_RESP and rejects 10 B', () {
      final bytes = <int>[
        0x78,
        0x56,
        0x34,
        0x12,
        0xEF,
        0xCD,
        0xAB,
        0x90,
        0x85,
        0x02,
        0x03,
        0x01,
        0x00,
        0x03,
      ];
      final packet = EixamRescueStatusRespPacket.tryParse(bytes);
      expect(packet, isNotNull);
      expect(packet!.inetAvailable, isTrue);
      expect(
        EixamRescueStatusRespPacket.tryParse(
          <int>[0x78, 0x56, 0x34, 0x12, 0x85, 0x02, 0x03, 0x01, 0x00, 0x03],
        ),
        isNull,
      );
    });
  });
}
