import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'ble_debug_registry.dart';
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
    _logRawSosLikePayload(
      source: 'ble_payload_classifier',
      payload: payload,
      payloadHex: payloadHex,
      connectedBleTagNodeId: connectedBleTagNodeId,
      classificationBefore: 'pre_parse',
    );
    final eventPacket =
        payload.length == 6 ? EixamSosEventPacket.tryParse(payload) : null;
    if (eventPacket != null) {
      _logSosEventRaw(
        payloadHex: payloadHex,
        eventPacket: eventPacket,
        connectedBleTagNodeId: connectedBleTagNodeId,
      );
      final classification = _classifySosEvent(eventPacket);
      final isExternalBackendCancel = _isExternalBackendCancelEvent(
        classification,
        eventPacket,
        connectedBleTagNodeId,
      );
      BleDebugRegistry.instance.recordEvent(
        'REMOTE_RELAY_CANCEL_DETECT source=ble_payload_classifier '
        'rawType=sos_event nodeId=${eventPacket.nodeId} '
        'originatorNodeId=${eventPacket.nodeId} '
        'relayNodeId=${connectedBleTagNodeId?.toString() ?? "none"} '
        'relayHardwareId=none '
        'classifiedAs=${isExternalBackendCancel ? "remoteRelay" : "ownDevice"} '
        'action=${isExternalBackendCancel ? "emit_remote_cancel_snapshot" : "local_terminal"}',
      );
      if (isExternalBackendCancel) {
        BleDebugRegistry.instance.recordEvent(
          'REMOTE_RELAY_CANCEL_DETECT source=ble_sos_event_e1_02 '
          'classifiedAs=remoteRelay '
          'originatorNodeId=${eventPacket.nodeId} '
          'relayNodeId=${connectedBleTagNodeId?.toString() ?? "none"}',
        );
      }
      _logClassifyDecision(
        raw: payloadHex,
        packetType: 'sos_event',
        classification:
            isExternalBackendCancel ? 'remoteRelayCancel' : classification.name,
        reason: isExternalBackendCancel
            ? 'e1_02_backend_cancel_originator_differs_from_connected_node'
            : 'local_or_non_backend_sos_event',
        nodeId: eventPacket.nodeId,
        relayNodeId: connectedBleTagNodeId,
        statusByte: _hexByte(eventPacket.subcode),
        terminalFlag: true,
        cancelFlag: classification == BleIncomingPayloadKind.sosCancel,
      );
      return BleIncomingPayloadClassification(
        kind: classification,
        sosEventPacket: eventPacket,
        remoteRelaySosSnapshot: isExternalBackendCancel
            ? RemoteRelaySosSnapshot(
                kind: RemoteRelaySosKind.cancel,
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
      _logClassifyDecision(
        raw: payloadHex,
        packetType: 'sos',
        classification: classification.name,
        reason: _sosPacketClassificationReason(
          packet: sosPacket,
          connectedBleTagNodeId: connectedBleTagNodeId,
          classification: classification,
        ),
        nodeId: sosPacket.nodeId,
        relayNodeId: connectedBleTagNodeId,
        statusByte: _statusByte(payload),
        terminalFlag: false,
        cancelFlag: false,
      );
      return BleIncomingPayloadClassification(
        kind: classification,
        sosPacket: sosPacket,
        remoteRelaySosSnapshot: classification ==
                BleIncomingPayloadKind.remoteRelaySos
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
      _logClassifyDecision(
        raw: payloadHex,
        packetType: 'tel',
        classification: BleIncomingPayloadKind.telPosition.name,
        reason: 'tel_packet_length_match',
        nodeId: telPacket.nodeId,
        relayNodeId: connectedBleTagNodeId,
        statusByte: _statusByte(payload),
        terminalFlag: false,
        cancelFlag: false,
      );
      return BleIncomingPayloadClassification(
        kind: BleIncomingPayloadKind.telPosition,
        telPacket: telPacket,
      );
    }

    if (_isSosLikePayload(payload)) {
      _logClassifyDecision(
        raw: payloadHex,
        packetType: _packetTypeByte(payload),
        classification: BleIncomingPayloadKind.unknown.name,
        reason: 'sos_like_payload_parse_failed',
        nodeId: null,
        relayNodeId: connectedBleTagNodeId,
        statusByte: _statusByte(payload),
        terminalFlag: _looksLikeTerminalOpcode(payload),
        cancelFlag: false,
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
    return BleIncomingPayloadKind.unknownOriginSos;
  }

  BleIncomingPayloadKind _classifySosEvent(EixamSosEventPacket packet) {
    if (packet.opcode == EixamBleProtocol.sosEventAppCancelAckOpcode) {
      return BleIncomingPayloadKind.unknown;
    }
    return BleIncomingPayloadKind.sosCancel;
  }

  bool _isExternalBackendCancelEvent(
    BleIncomingPayloadKind classification,
    EixamSosEventPacket packet,
    int? connectedBleTagNodeId,
  ) {
    if (classification != BleIncomingPayloadKind.sosCancel ||
        packet.opcode != EixamBleProtocol.sosEventUserDeactivatedOpcode ||
        packet.subcode != 0x02) {
      return false;
    }
    return connectedBleTagNodeId != null &&
        packet.nodeId != connectedBleTagNodeId;
  }

  RemoteRelaySosSource _remoteSourceFor(EixamBleChannel channel) {
    switch (channel) {
      case EixamBleChannel.tel:
        return RemoteRelaySosSource.telRelay;
      case EixamBleChannel.sos:
        return RemoteRelaySosSource.sosNotify;
    }
  }

  void _logRawSosLikePayload({
    required String source,
    required List<int> payload,
    required String payloadHex,
    required int? connectedBleTagNodeId,
    required String classificationBefore,
  }) {
    if (!_isSosLikePayload(payload)) {
      return;
    }
    final sosPacket = EixamSosPacket.tryParse(payload);
    final eventPacket =
        payload.length == 6 ? EixamSosEventPacket.tryParse(payload) : null;
    final decodedNodeId = sosPacket?.nodeId ?? eventPacket?.nodeId;
    BleDebugRegistry.instance.recordEvent(
      'BLE_SOS_PACKET_RAW source=$source raw=$payloadHex '
      'length=${payload.length} '
      'connectedNodeId=${connectedBleTagNodeId?.toString() ?? "none"} '
      'decodedNodeId=${decodedNodeId?.toString() ?? "none"} '
      'relayNodeId=${connectedBleTagNodeId?.toString() ?? "none"} '
      'classificationBefore=$classificationBefore '
      'packetTypeByte=${_packetTypeByte(payload)} '
      'statusByte=${_statusByte(payload)} '
      'lastByte=${_lastByte(payload)} '
      'sequenceByte=${_sequenceByte(payload)} '
      'flagsWord=${sosPacket == null ? "none" : _hexWord(sosPacket.flagsWord)} '
      'sosType=${sosPacket?.sosType.toString() ?? "none"} '
      'retryCount=${sosPacket?.retryCount.toString() ?? "none"} '
      'relayCount=${sosPacket?.relayCount.toString() ?? "none"} '
      'packetId=${sosPacket?.packetId.toString() ?? "none"} '
      'eventOpcode=${eventPacket == null ? "none" : _hexByte(eventPacket.opcode)} '
      'eventSubcode=${eventPacket == null ? "none" : _hexByte(eventPacket.subcode)}',
    );
  }

  void _logClassifyDecision({
    required String raw,
    required String packetType,
    required String classification,
    required String reason,
    required int? nodeId,
    required int? relayNodeId,
    required String statusByte,
    required bool terminalFlag,
    required bool cancelFlag,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'BLE_SOS_CLASSIFY_DECISION raw=$raw packetType=$packetType '
      'classification=$classification reason=$reason '
      'nodeId=${nodeId?.toString() ?? "none"} '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'statusByte=$statusByte terminalFlag=$terminalFlag '
      'cancelFlag=$cancelFlag',
    );
  }

  void _logSosEventRaw({
    required String payloadHex,
    required EixamSosEventPacket eventPacket,
    required int? connectedBleTagNodeId,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'BLE_SOS_EVENT_RAW raw=$payloadHex '
      'event=${_hexByte(eventPacket.opcode)} '
      'subcode=${_hexByte(eventPacket.subcode)} '
      'nodeId=${eventPacket.nodeId} '
      'connectedNodeId=${connectedBleTagNodeId?.toString() ?? "none"}',
    );
  }

  String _sosPacketClassificationReason({
    required EixamSosPacket packet,
    required int? connectedBleTagNodeId,
    required BleIncomingPayloadKind classification,
  }) {
    if (classification == BleIncomingPayloadKind.ownDeviceSos) {
      return 'originator_matches_connected_ble_node';
    }
    if (classification == BleIncomingPayloadKind.remoteRelaySos) {
      return connectedBleTagNodeId == null
          ? 'fallback_remote_relay_connected_node_unknown'
          : 'originator_differs_from_connected_ble_node';
    }
    if (classification == BleIncomingPayloadKind.unknownOriginSos) {
      return 'connected_ble_node_unknown';
    }
    return 'classification=${classification.name}';
  }

  bool _isSosLikePayload(List<int> payload) {
    return payload.length == 6 ||
        payload.length == EixamBleProtocol.sosPacketLengthMinimal ||
        payload.length == EixamBleProtocol.sosPacketLengthWithPosition ||
        payload.length == EixamBleProtocol.sosPacketLengthMinimal + 6 ||
        payload.length == EixamBleProtocol.sosPacketLengthWithPosition + 6 ||
        _looksLikeTerminalOpcode(payload);
  }

  bool _looksLikeTerminalOpcode(List<int> payload) {
    if (payload.isEmpty) {
      return false;
    }
    return payload.first == EixamBleProtocol.sosEventUserDeactivatedOpcode ||
        payload.first == EixamBleProtocol.sosEventAppCancelAckOpcode;
  }

  String _packetTypeByte(List<int> payload) {
    if (payload.isEmpty) {
      return 'none';
    }
    return _hexByte(payload.first);
  }

  String _statusByte(List<int> payload) {
    if (payload.length == 6) {
      return _hexByte(payload[1]);
    }
    if (payload.length >= EixamBleProtocol.sosPacketLengthWithPosition) {
      return _hexByte(payload[11]);
    }
    if (payload.length >= EixamBleProtocol.sosPacketLengthMinimal) {
      return _hexByte(payload[5]);
    }
    return 'none';
  }

  String _lastByte(List<int> payload) {
    if (payload.isEmpty) {
      return 'none';
    }
    return _hexByte(payload.last);
  }

  String _sequenceByte(List<int> payload) {
    if (payload.length == EixamBleProtocol.sosPacketLengthMinimal) {
      return _hexByte(payload[6]);
    }
    final packet = EixamSosPacket.tryParse(payload);
    return packet == null ? 'none' : packet.packetId.toString();
  }

  String _hexByte(int value) {
    return '0x${(value & 0xFF).toRadixString(16).padLeft(2, '0')}';
  }

  String _hexWord(int value) {
    return '0x${(value & 0xFFFF).toRadixString(16).padLeft(4, '0')}';
  }
}
