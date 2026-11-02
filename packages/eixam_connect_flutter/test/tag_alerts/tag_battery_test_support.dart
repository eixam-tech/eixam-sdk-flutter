import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_device_runtime_status_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_live_batch_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_packet.dart';

import '../support/builders/device_status_builder.dart';

const int tagNodeId = 0x12345678;

/// Protocol battery values: 0 critical (<10), 1 low (<30), 2 medium, 3 ok.
List<int> telWire({
  int nodeId = tagNodeId,
  required int level,
  int packetId = 1,
}) => <int>[
  nodeId & 0xFF,
  (nodeId >> 8) & 0xFF,
  (nodeId >> 16) & 0xFF,
  (nodeId >> 24) & 0xFF,
  0x01,
  0x02,
  0x03,
  0x04,
  0x05,
  0x06,
  (level & 0x03) << 6 | (packetId & 0x0F),
  0x25,
];

typedef LiveRecord = ({int timestamp, List<int> wire});

int unixOf(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

BleIncomingEvent liveBatchEvent(
  DateTime receivedAt,
  List<LiveRecord> records, {
  String deviceId = 'ble-id',
}) {
  final payload = <int>[0xD3, records.length];
  for (final record in records) {
    payload.addAll(<int>[
      record.timestamp & 0xFF,
      (record.timestamp >> 8) & 0xFF,
      (record.timestamp >> 16) & 0xFF,
      (record.timestamp >> 24) & 0xFF,
      ...record.wire,
    ]);
  }
  final parsed = EixamTelLiveBatchPacket.tryParse(
    payload,
    receivedAt: receivedAt,
  )!;
  return BleIncomingEvent(
    deviceId: deviceId,
    type: BleIncomingEventType.telLivePositionBatch,
    channel: EixamBleChannel.tel,
    payload: payload,
    payloadHex: EixamBleProtocol.hex(payload),
    source: DeviceSosTransitionSource.device,
    receivedAt: receivedAt,
    telLiveBatchPacket: parsed,
  );
}

BleIncomingEvent classicTelEvent(
  DateTime receivedAt,
  List<int> wire, {
  String deviceId = 'ble-id',
}) => BleIncomingEvent(
  deviceId: deviceId,
  type: BleIncomingEventType.telPosition,
  channel: EixamBleChannel.tel,
  payload: wire,
  payloadHex: EixamBleProtocol.hex(wire),
  source: DeviceSosTransitionSource.device,
  receivedAt: receivedAt,
  telPacket: EixamTelPacket.tryParse(wire),
);

DeviceRuntimeStatus runtimeStatus({
  int nodeId = tagNodeId,
  int? percent = 50,
  DateTime? receivedAt,
  bool omitReceivedAt = false,
  int telIntervalSeconds = 120,
}) => DeviceRuntimeStatus(
  region: 1,
  modemPreset: 1,
  meshSpreadingFactor: 11,
  isProvisioned: true,
  usePreset: true,
  txEnabled: true,
  inetOk: false,
  positionConfirmed: true,
  nodeId: nodeId,
  batteryPercent: percent,
  telIntervalSeconds: telIntervalSeconds,
  receivedAt: omitReceivedAt
      ? null
      : (receivedAt ?? DateTime.utc(2026, 11, 2, 12)),
);

BleIncomingEvent runtimeStatusEvent(
  DateTime receivedAt, {
  int nodeId = tagNodeId,
  int? percent = 50,
  int telIntervalSeconds = 120,
  String deviceId = 'ble-id',
}) => BleIncomingEvent(
  deviceId: deviceId,
  type: BleIncomingEventType.deviceRuntimeStatus,
  channel: EixamBleChannel.tel,
  payload: const <int>[],
  payloadHex: '',
  source: DeviceSosTransitionSource.device,
  receivedAt: receivedAt,
  deviceRuntimeStatusPacket: EixamDeviceRuntimeStatusPacket(
    status: runtimeStatus(
      nodeId: nodeId,
      percent: percent,
      receivedAt: receivedAt,
      telIntervalSeconds: telIntervalSeconds,
    ),
  ),
);

BleIncomingEvent eventOfType(BleIncomingEventType type, DateTime at) =>
    BleIncomingEvent(
      deviceId: 'ble-id',
      type: type,
      channel: EixamBleChannel.tel,
      payload: const <int>[],
      payloadHex: '',
      source: DeviceSosTransitionSource.device,
      receivedAt: at,
    );

DeviceStatus connectedTag({
  int? nodeId = tagNodeId,
  bool connected = true,
  bool paired = true,
  String hardware = 'AA:BB:CC:DD:EE:01',
}) => buildDeviceStatus(
  deviceId: 'ble-id',
  nodeId: nodeId,
  canonicalHardwareId: hardware,
  connected: connected,
  paired: paired,
);
