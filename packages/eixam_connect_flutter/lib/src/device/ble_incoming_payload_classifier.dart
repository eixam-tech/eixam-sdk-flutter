import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'ble_incoming_event.dart';
import 'eixam_ble_protocol.dart';
import 'eixam_sos_event_packet.dart';
import 'eixam_sos_packet.dart';
import 'eixam_tel_packet.dart';

class BleIncomingPayloadClassifier {
  const BleIncomingPayloadClassifier();

  BleIncomingPayloadClassification classifySosPayload({
    required List<int> payload,
    required String payloadHex,
    required DateTime receivedAt,
    required DeviceSosTransitionSource source,
    required EixamBleChannel channel,
    required int? connectedBleTagNodeId,
    required BleIncomingPayloadClassification fallbackOnUnknownConnectedNode,
  }) {
    final eventPacket =
        payload.length == 6 ? EixamSosEventPacket.tryParse(payload) : null;
    if (eventPacket != null) {
      final classification = _classifySosEvent(
        packet: eventPacket,
        connectedBleTagNodeId: connectedBleTagNodeId,
        source: source,
        fallbackOnUnknownConnectedNode: fallbackOnUnknownConnectedNode,
      );
      return BleIncomingPayloadClassification(
        kind: classification,
        sosEventPacket: eventPacket,
        remoteRelaySosSnapshot:
            _isRemoteTerminalEvent(classification, eventPacket, connectedBleTagNodeId)
                ? RemoteRelaySosSnapshot(
                    kind: classification == BleIncomingPayloadKind.sosClear
                        ? RemoteRelaySosKind.clear
                        : RemoteRelaySosKind.cancel,
                    originatorNodeId: eventPacket.nodeId,
                    relayNodeId: connectedBleTagNodeId,
                    source: _remoteSourceFor(channel),
                    sosType: 0,
                    receivedAt: receivedAt,
                    rawPayload: List<int>.unmodifiable(payload),
                    payloadHex: payloadHex,
                    eventOpcode: eventPacket.opcode,
                    eventSubcode: eventPacket.subcode,
                  )
                : null,
      );
    }

    final sosPacket = EixamSosPacket.tryParse(payload);
    if (sosPacket != null && sosPacket.sosType != 0) {
      // Safety-critical rule: decoding a valid BLE SOS payload is not enough to
      // claim that the connected tag itself is in SOS. The originator nodeId in
      // bytes 0..3 must match the connected BLE tag nodeId.
      final classification = _classifySosPacket(
        packet: sosPacket,
        connectedBleTagNodeId: connectedBleTagNodeId,
        source: source,
        fallbackOnUnknownConnectedNode: fallbackOnUnknownConnectedNode,
      );
      return BleIncomingPayloadClassification(
        kind: classification,
        sosPacket: sosPacket,
        remoteRelaySosSnapshot: classification == BleIncomingPayloadKind.remoteRelaySos
            ? RemoteRelaySosSnapshot(
                kind: RemoteRelaySosKind.sos,
                originatorNodeId: sosPacket.nodeId,
                relayNodeId: connectedBleTagNodeId,
                source: _remoteSourceFor(channel),
                sosType: sosPacket.sosType,
                location: sosPacket.position == null
                    ? null
                    : TrackingPosition(
                        latitude: sosPacket.position!.latitude,
                        longitude: sosPacket.position!.longitude,
                        altitude: sosPacket.position!.altitudeMeters.toDouble(),
                        timestamp: receivedAt,
                        source: DeliveryMode.mesh,
                      ),
                receivedAt: receivedAt,
                rawPayload: List<int>.unmodifiable(payload),
                payloadHex: payloadHex,
                relayCount: sosPacket.relayCount,
              )
            : null,
      );
    }

    final telPacket = payload.length == EixamBleProtocol.telPacketLength
        ? EixamTelPacket.tryParse(payload)
        : null;
    if (telPacket != null) {
      return BleIncomingPayloadClassification(
        kind: BleIncomingPayloadKind.telPosition,
        telPacket: telPacket,
      );
    }

    return const BleIncomingPayloadClassification(
      kind: BleIncomingPayloadKind.unknown,
    );
  }

  BleIncomingPayloadKind _classifySosPacket({
    required EixamSosPacket packet,
    required int? connectedBleTagNodeId,
    required DeviceSosTransitionSource source,
    required BleIncomingPayloadClassification fallbackOnUnknownConnectedNode,
  }) {
    if (connectedBleTagNodeId != null) {
      return packet.nodeId == connectedBleTagNodeId
          ? BleIncomingPayloadKind.ownDeviceSos
          : BleIncomingPayloadKind.remoteRelaySos;
    }
    if (source == DeviceSosTransitionSource.app) {
      return BleIncomingPayloadKind.ownDeviceSos;
    }
    return fallbackOnUnknownConnectedNode.kind;
  }

  BleIncomingPayloadKind _classifySosEvent({
    required EixamSosEventPacket packet,
    required int? connectedBleTagNodeId,
    required DeviceSosTransitionSource source,
    required BleIncomingPayloadClassification fallbackOnUnknownConnectedNode,
  }) {
    final terminalKind = packet.subcode == 0x02 || packet.subcode == 0x03
        ? BleIncomingPayloadKind.sosClear
        : BleIncomingPayloadKind.sosCancel;
    if (connectedBleTagNodeId != null) {
      return packet.nodeId == connectedBleTagNodeId
          ? terminalKind
          : terminalKind;
    }
    if (source == DeviceSosTransitionSource.app) {
      return terminalKind;
    }
    return fallbackOnUnknownConnectedNode.kind == BleIncomingPayloadKind.ownDeviceSos
        ? terminalKind
        : terminalKind;
  }

  bool _isRemoteTerminalEvent(
    BleIncomingPayloadKind classification,
    EixamSosEventPacket packet,
    int? connectedBleTagNodeId,
  ) {
    if (classification != BleIncomingPayloadKind.sosClear &&
        classification != BleIncomingPayloadKind.sosCancel) {
      return false;
    }
    return connectedBleTagNodeId == null || packet.nodeId != connectedBleTagNodeId;
  }

  RemoteRelaySosSource _remoteSourceFor(EixamBleChannel channel) {
    switch (channel) {
      case EixamBleChannel.tel:
        return RemoteRelaySosSource.telRelay;
      case EixamBleChannel.sos:
        return RemoteRelaySosSource.sosNotify;
    }
  }
}
