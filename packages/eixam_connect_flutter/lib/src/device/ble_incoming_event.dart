import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_ble_protocol.dart';
import 'eixam_cluster_heartbeat_packet.dart';
import 'eixam_device_runtime_status_packet.dart';
import 'eixam_sos_event_packet.dart';
import 'eixam_sos_packet.dart';
import 'eixam_tel_fragment.dart';
import 'eixam_tel_live_batch_packet.dart';
import 'eixam_position_backlog_packet.dart';
import 'eixam_tel_packet.dart';
import 'eixam_tel_relay_rx_packet.dart';
import '../provisioning/provisioning_command_result.dart';

enum BleIncomingPayloadKind {
  ownDeviceSos,
  remoteRelaySos,
  unknownOriginSos,
  sosClear,
  sosCancel,
  telPosition,
  telRelayRx,
  unknown,
}

class BleIncomingPayloadClassification {
  const BleIncomingPayloadClassification({
    required this.kind,
    this.sosPacket,
    this.sosEventPacket,
    this.telPacket,
    this.remoteRelaySosSnapshot,
  });

  final BleIncomingPayloadKind kind;
  final EixamSosPacket? sosPacket;
  final EixamSosEventPacket? sosEventPacket;
  final EixamTelPacket? telPacket;
  final RemoteRelaySosSnapshot? remoteRelaySosSnapshot;
}

enum BleIncomingEventType {
  deviceRuntimeStatus,
  provisioningCommandResult,
  telPosition,
  telAggregateFragment,
  telAggregateComplete,
  telLivePositionBatch,
  telPositionBacklog,
  telRelayRx,
  clusterHeartbeat,
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
    this.telLiveBatchPacket,
    this.positionBacklogPacket,
    this.clusterHeartbeatPacket,
    this.deviceRuntimeStatusPacket,
    this.provisioningCommandResult,
    this.telRelayRxPacket,
    this.sosPacket,
    this.sosEventPacket,
    this.classification = const BleIncomingPayloadClassification(
      kind: BleIncomingPayloadKind.unknown,
    ),
    this.remoteRelaySosSnapshot,
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
  final EixamTelLiveBatchPacket? telLiveBatchPacket;
  final EixamPositionBacklogPacket? positionBacklogPacket;
  final EixamClusterHeartbeatPacket? clusterHeartbeatPacket;
  final EixamDeviceRuntimeStatusPacket? deviceRuntimeStatusPacket;
  final ProvisioningCommandResult? provisioningCommandResult;
  final EixamTelRelayRxPacket? telRelayRxPacket;
  final EixamSosPacket? sosPacket;
  final EixamSosEventPacket? sosEventPacket;
  final BleIncomingPayloadClassification classification;
  final RemoteRelaySosSnapshot? remoteRelaySosSnapshot;

  String get eventType => type.name;
}
