import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_backlog_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_data.dart';
import 'package:eixam_connect_flutter/src/sdk/device_position_backlog_coordinator.dart';
import 'package:eixam_connect_flutter/src/sdk/device_position_batch_normalizer.dart';

import 'recording_test_support.dart';

/// Decoded real-format D1 evidence at the existing coordinator boundary.
final class RecordingHistoryHarness {
  RecordingHistoryHarness() {
    coordinator = DevicePositionBacklogCoordinator(
      writeCommand: (command) async {
        commands.add(command.opcode);
        if (command.opcode == 0x30) {
          requests.add(command.encode());
          await onStart?.call();
        }
      },
      normalizer: normalizer,
      emitBatch: batches.add,
    );
  }
  final normalizer = DevicePositionBatchNormalizer();
  final commands = <int>[];
  final requests = <List<int>>[];
  final batches = <EixamDevicePositionBatch>[];
  Future<void> Function()? onStart;
  late final DevicePositionBacklogCoordinator coordinator;
  late RecordingFixture f;
  Future<void> create() async =>
      f = await RecordingFixture.create(backlog: coordinator);
  Future<void> delete() => f.delete();
  Future<void> ready({bool notify = false}) async {
    f.connected = true;
    f.historyReady = true;
    if (notify) await f.controller.inputDisconnected(tagA, true);
  }

  Future<void> send(List<int> bytes, {String device = tagA}) =>
      coordinator.handleEvent(event(bytes, device: device));
  BleIncomingEvent event(List<int> bytes, {String device = tagA}) =>
      BleIncomingEvent(
        type: BleIncomingEventType.telPositionBacklog,
        channel: EixamBleChannel.tel,
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        deviceId: 'transport',
        canonicalHardwareId: device,
        receivedAt: f.now,
        payload: const [],
        positionBacklogPacket: EixamPositionBacklogPacket.tryParse(
          bytes,
          receivedAt: f.now,
        ),
      );
  EixamDevicePositionSample sample(
    int seconds,
    int packet, {
    double? latitude,
  }) =>
      (EixamPositionBacklogPacket.tryParse(
                chunk(seconds, packet: packet, latitude: latitude),
                receivedAt: f.now,
              )
              as EixamPositionBacklogChunk)
          .batch
          .samples
          .single;
  List<int> chunk(
    int seconds, {
    int index = 0,
    int packet = 1,
    int session = 7,
    bool invalid = false,
    double? latitude,
  }) => [
    0xD1,
    2,
    session,
    ...u32(index),
    1,
    ...u32(seconds),
    if (invalid) ...[
      42,
      0,
      0,
      0,
      ...EixamPositionData.encode(latitude: 0, longitude: 0),
      0x81,
      0x25,
    ] else ...[
      0x78,
      0x56,
      0x34,
      0x12,
      ...(latitude == null
          ? [1, 2, 3, 4, 5, 6]
          : EixamPositionData.encode(
              latitude: latitude,
              longitude: 2,
              altitudeMeters: 40,
            )),
      0x80 | packet,
      0x25,
    ],
  ];
  List<int> meta(int count, {int start = 0, int session = 7}) => [
    0xD1,
    1,
    session,
    1,
    ...u16(count),
    ...u32(count == 0 ? 0 : start),
    ...u32(count == 0 ? 0 : start + count - 1),
  ];
  List<int> end(int count, {int session = 7}) => [
    0xD1,
    3,
    session,
    ...u16(count),
    ...u32(count == 0 ? 0 : count - 1),
    0,
  ];
  List<int> u16(int n) => [n & 255, (n >> 8) & 255];
  List<int> u32(int n) => [...u16(n), ...u16(n >> 16)];
}
