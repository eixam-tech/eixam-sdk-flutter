import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_live_batch_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_packet.dart';
import 'package:eixam_connect_flutter/src/sdk/device_position_batch_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final receivedAt = DateTime.utc(2026, 8, 7, 12);

  test('first batch publishes every sample and exact replay publishes nothing',
      () {
    final normalizer = DevicePositionBatchNormalizer();
    final event = _liveEvent(
      receivedAt,
      <({int timestamp, List<int> wire})>[
        (timestamp: 1786103800, wire: _wire(packetId: 1)),
        (timestamp: 1786103860, wire: _wire(packetId: 2)),
        (timestamp: 1786103920, wire: _wire(packetId: 3)),
      ],
    );

    expect(
      normalizer.normalize(event)!.samples.map((sample) => sample.packetId),
      <int>[1, 2, 3],
    );
    expect(normalizer.normalize(event), isNull);
  });

  test('overlap publishes only novel samples in incoming firmware order', () {
    final normalizer = DevicePositionBatchNormalizer();
    final b = (timestamp: 1786103860, wire: _wire(packetId: 2));
    final c = (timestamp: 1786103920, wire: _wire(packetId: 3));
    normalizer.normalize(
      _liveEvent(receivedAt, <({int timestamp, List<int> wire})>[
        (timestamp: 1786103800, wire: _wire(packetId: 1)),
        b,
        c,
      ]),
    );

    final novel = normalizer.normalize(
      _liveEvent(receivedAt.add(const Duration(seconds: 1)), [
        b,
        c,
        (timestamp: 1786103980, wire: _wire(packetId: 4)),
        (timestamp: 1786104040, wire: _wire(packetId: 5)),
      ]),
    );

    expect(novel!.samples.map((sample) => sample.packetId), <int>[4, 5]);
  });

  test('same timestamp with different wire remains distinct', () {
    final normalizer = DevicePositionBatchNormalizer();
    final first = _wire(packetId: 1);
    final moved = _wire(packetId: 1)..[4] = 0x02;

    final output = normalizer.normalize(
      _liveEvent(receivedAt, [
        (timestamp: 1786103800, wire: first),
        (timestamp: 1786103800, wire: moved),
      ]),
    );

    expect(output!.samples, hasLength(2));
    expect(
      output.samples.first.stableSampleKey,
      isNot(output.samples.last.stableSampleKey),
    );
  });

  test('packet id wrap does not deduplicate different full records', () {
    final normalizer = DevicePositionBatchNormalizer();
    final output = normalizer.normalize(
      _liveEvent(receivedAt, [
        (timestamp: 1786103800, wire: _wire(packetId: 1)),
        (timestamp: 1786103900, wire: _wire(packetId: 1)),
      ]),
    );

    expect(output!.samples, hasLength(2));
  });

  test('classic TEL becomes one semantic batch and immediate replay is removed',
      () {
    final normalizer = DevicePositionBatchNormalizer();
    final event = _classicEvent(receivedAt, _wire(packetId: 6));

    final output = normalizer.normalize(event);

    expect(output!.samples, hasLength(1));
    expect(output.receivedAt, receivedAt);
    expect(output.samples.single.sampledAt, isNull);
    expect(output.samples.single.source, SdkLocationSource.connectedDevice);
    expect(normalizer.normalize(event), isNull);
  });

  test('equivalent classic TEL and live record publish once', () {
    final normalizer = DevicePositionBatchNormalizer();
    final wire = _wire(packetId: 7);

    expect(normalizer.normalize(_classicEvent(receivedAt, wire)), isNotNull);
    expect(
      normalizer.normalize(
        _liveEvent(receivedAt, [
          (timestamp: 1786103800, wire: wire),
        ]),
      ),
      isNull,
    );
  });

  test('non-TEL events never enter the device position stream', () {
    final normalizer = DevicePositionBatchNormalizer();
    final event = BleIncomingEvent(
      deviceId: 'device-a',
      type: BleIncomingEventType.unknownProtocolPacket,
      channel: EixamBleChannel.tel,
      payload: const <int>[],
      payloadHex: '',
      source: DeviceSosTransitionSource.device,
      receivedAt: receivedAt,
    );

    expect(normalizer.normalize(event), isNull);
  });

  test('timestamp discontinuity does not reorder firmware delivery', () {
    final normalizer = DevicePositionBatchNormalizer();
    final output = normalizer.normalize(
      _liveEvent(receivedAt, [
        (timestamp: 1786103900, wire: _wire(packetId: 1)),
        (timestamp: 1786103800, wire: _wire(packetId: 2)),
      ]),
    );

    expect(output!.samples.map((sample) => sample.packetId), <int>[1, 2]);
  });

  test('dedup caches remain bounded per device and across devices', () {
    final normalizer = DevicePositionBatchNormalizer(
      maximumDevices: 2,
      maximumRecordIdentitiesPerDevice: 3,
      maximumRecentWireIdentitiesPerDevice: 2,
    );
    for (var device = 0; device < 3; device++) {
      for (var sample = 0; sample < 5; sample++) {
        normalizer.normalize(
          _liveEvent(
            receivedAt.add(Duration(seconds: sample)),
            [
              (
                timestamp: 1786103800 + sample,
                wire: _wire(packetId: sample),
              ),
            ],
            deviceId: 'device-$device',
          ),
        );
      }
    }

    expect(normalizer.cachedDeviceCount, 2);
    expect(normalizer.largestRecordIdentityCount, lessThanOrEqualTo(3));
  });
}

BleIncomingEvent _liveEvent(
  DateTime receivedAt,
  List<({int timestamp, List<int> wire})> records, {
  String deviceId = 'device-a',
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

BleIncomingEvent _classicEvent(
  DateTime receivedAt,
  List<int> wire,
) {
  final packet = EixamTelPacket.tryParse(wire)!;
  return BleIncomingEvent(
    deviceId: 'device-a',
    type: BleIncomingEventType.telPosition,
    channel: EixamBleChannel.tel,
    payload: wire,
    payloadHex: EixamBleProtocol.hex(wire),
    source: DeviceSosTransitionSource.device,
    receivedAt: receivedAt,
    telPacket: packet,
    classification: BleIncomingPayloadClassification(
      kind: BleIncomingPayloadKind.telPosition,
      telPacket: packet,
    ),
  );
}

List<int> _wire({required int packetId}) => <int>[
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
      0x80 | (packetId & 0x0F),
      0x25,
    ];
