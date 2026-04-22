import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_ble_protocol.dart';
import 'eixam_backlog_sync_frame.dart';
import 'eixam_cluster_heartbeat_packet.dart';
import 'eixam_device_runtime_status_packet.dart';
import 'eixam_guided_rescue_status_packet.dart';
import 'eixam_sos_event_packet.dart';
import 'eixam_sos_packet.dart';
import 'eixam_tel_fragment.dart';
import 'eixam_tel_packet.dart';
import 'eixam_tel_relay_rx_packet.dart';

enum BleIncomingEventType {
  deviceRuntimeStatus,
  telPosition,
  telAggregateFragment,
  telAggregateComplete,
  telRelayRx,
  clusterHeartbeat,
  backlogSyncFrame,
  guidedRescueStatus,
  sosMeshPacket,
  sosDeviceEvent,
  unknownProtocolPacket,
}

class BleIncomingEvent {
  const BleIncomingEvent({
    required this.deviceId,
    this.canonicalHardwareId,
    required this.type,
    required this.channel,
    required this.payload,
    required this.payloadHex,
    required this.source,
    required this.receivedAt,
    this.meshPort,
    this.deviceAlias,
    this.telPacket,
    this.telFragment,
    this.aggregatePayload,
    this.clusterHeartbeatPacket,
    this.guidedRescueStatusPacket,
    this.deviceRuntimeStatusPacket,
    this.telRelayRxPacket,
    this.backlogSyncFrame,
    this.sosPacket,
    this.sosEventPacket,
  });

  final String deviceId;
  final String? canonicalHardwareId;
  final String? deviceAlias;
  final BleIncomingEventType type;
  final EixamBleChannel channel;
  final List<int> payload;
  final String payloadHex;
  final DeviceSosTransitionSource source;
  final DateTime receivedAt;
  final int? meshPort;
  final EixamTelPacket? telPacket;
  final EixamTelFragment? telFragment;
  final List<int>? aggregatePayload;
  final EixamClusterHeartbeatPacket? clusterHeartbeatPacket;
  final EixamGuidedRescueStatusPacket? guidedRescueStatusPacket;
  final EixamDeviceRuntimeStatusPacket? deviceRuntimeStatusPacket;
  final EixamTelRelayRxPacket? telRelayRxPacket;
  final EixamBacklogSyncFrame? backlogSyncFrame;
  final EixamSosPacket? sosPacket;
  final EixamSosEventPacket? sosEventPacket;

  String get eventType => type.name;
}
