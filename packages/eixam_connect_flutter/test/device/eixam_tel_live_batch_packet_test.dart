import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_fragment.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_live_batch_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_reassembler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final receivedAt = DateTime.utc(2026, 8, 7, 12);

  group('EixamTelLiveBatchPacket parsing', () {
    test('parses one record through the authoritative TEL decoder', () {
      final wire = _wire(packetId: 7);
      final packet = EixamTelLiveBatchPacket.tryParse(
        _batch(<List<int>>[_record(1786103940, wire)]),
        receivedAt: receivedAt,
      );
      final authoritative = EixamTelPacket.tryParse(wire)!;

      expect(packet, isNotNull);
      expect(packet!.batch.samples, hasLength(1));
      expect(packet.batch.samples.single.latitude,
          authoritative.position.latitude);
      expect(packet.batch.samples.single.longitude,
          authoritative.position.longitude);
      expect(packet.batch.samples.single.altitudeMeters,
          authoritative.position.altitudeMeters.toDouble());
      expect(packet.batch.samples.single.packetId, 7);
      expect(packet.batch.source, SdkLocationSource.connectedDevice);
    });

    test('preserves all records oldest to newest', () {
      final packet = EixamTelLiveBatchPacket.tryParse(
        _batch(<List<int>>[
          _record(1786103800, _wire(packetId: 1)),
          _record(1786103860, _wire(packetId: 2)),
          _record(1786103920, _wire(packetId: 3)),
        ]),
        receivedAt: receivedAt,
      )!;

      expect(packet.batch.samples.map((sample) => sample.packetId),
          <int>[1, 2, 3]);
      expect(packet.batch.receivedAt, receivedAt);
      expect(
        () => packet.batch.samples.add(packet.batch.samples.first),
        throwsUnsupportedError,
      );
    });

    test('parses the maximum 24 records', () {
      final records = List<List<int>>.generate(
        24,
        (index) => _record(1786102500 + index, _wire(packetId: index % 16)),
      );
      final payload = _batch(records);
      final packet = EixamTelLiveBatchPacket.tryParse(
        payload,
        receivedAt: receivedAt,
      );

      expect(payload, hasLength(386));
      expect(packet!.batch.samples, hasLength(24));
    });

    test('rejects truncated header, zero count, and count above 24', () {
      expect(EixamTelLiveBatchPacket.tryParse(<int>[], receivedAt: receivedAt),
          isNull);
      expect(
          EixamTelLiveBatchPacket.tryParse(<int>[0xD3], receivedAt: receivedAt),
          isNull);
      expect(
          EixamTelLiveBatchPacket.tryParse(<int>[0xD3, 0],
              receivedAt: receivedAt),
          isNull);
      expect(
          EixamTelLiveBatchPacket.tryParse(<int>[0xD3, 25],
              receivedAt: receivedAt),
          isNull);
    });

    test('rejects truncated first and later records atomically', () {
      final one = _batch(<List<int>>[_record(1786103940, _wire())]);
      final two = _batch(<List<int>>[
        _record(1786103880, _wire(packetId: 1)),
        _record(1786103940, _wire(packetId: 2)),
      ]);

      expect(
          EixamTelLiveBatchPacket.tryParse(one.sublist(0, one.length - 1),
              receivedAt: receivedAt),
          isNull);
      expect(
          EixamTelLiveBatchPacket.tryParse(two.sublist(0, two.length - 1),
              receivedAt: receivedAt),
          isNull);
    });

    test('rejects declared count mismatch and trailing bytes', () {
      final payload = _batch(<List<int>>[_record(1786103940, _wire())]);
      expect(
          EixamTelLiveBatchPacket.tryParse(<int>[...payload]..[1] = 2,
              receivedAt: receivedAt),
          isNull);
      expect(
          EixamTelLiveBatchPacket.tryParse(<int>[...payload, 0x00],
              receivedAt: receivedAt),
          isNull);
    });

    test('rejects a malformed TEL record without returning partial samples',
        () {
      final malformed = _record(1786103940, _wire())..[6] = 0x100;
      expect(
        EixamTelLiveBatchPacket.tryParse(
          _batch(<List<int>>[
            _record(1786103880, _wire(packetId: 1)),
            malformed,
          ]),
          receivedAt: receivedAt,
        ),
        isNull,
      );
    });
  });

  group('live batch timestamps', () {
    test('accepts plausible UTC and keeps it distinct from reception', () {
      final packet = EixamTelLiveBatchPacket.tryParse(
        _batch(<List<int>>[_record(1786103940, _wire())]),
        receivedAt: receivedAt,
      )!;
      final sample = packet.batch.samples.single;

      expect(sample.timestampValid, isTrue);
      expect(sample.sampledAt, DateTime.utc(2026, 8, 7, 11, 59));
      expect(sample.sampledAt, isNot(packet.batch.receivedAt));
    });

    test('rejects zero and obvious boot-relative timestamps', () {
      for (final timestamp in <int>[0, 86400]) {
        final sample = EixamTelLiveBatchPacket.tryParse(
          _batch(<List<int>>[_record(timestamp, _wire())]),
          receivedAt: receivedAt,
        )!
            .batch
            .samples
            .single;
        expect(sample.timestampValid, isFalse);
        expect(sample.sampledAt, isNull);
      }
    });

    test('rejects implausible future timestamps without using receivedAt', () {
      final future =
          receivedAt.add(const Duration(minutes: 11)).millisecondsSinceEpoch ~/
              Duration.millisecondsPerSecond;
      final sample = EixamTelLiveBatchPacket.tryParse(
        _batch(<List<int>>[_record(future, _wire())]),
        receivedAt: receivedAt,
      )!
          .batch
          .samples
          .single;

      expect(sample.timestampValid, isFalse);
      expect(sample.sampledAt, isNull);
    });
  });

  group('stable sample identity', () {
    test('is stable across repeated delivery and opaque', () {
      final payload = _batch(<List<int>>[_record(1786103940, _wire())]);
      final first =
          EixamTelLiveBatchPacket.tryParse(payload, receivedAt: receivedAt)!
              .batch
              .samples
              .single;
      final repeated =
          EixamTelLiveBatchPacket.tryParse(payload, receivedAt: receivedAt)!
              .batch
              .samples
              .single;

      expect(first.stableSampleKey, repeated.stableSampleKey);
      expect(first.stableSampleKey, startsWith('tlb1:'));
      expect(first.stableSampleKey, isNot(contains('305419896')));
      expect(first.stableSampleKey, isNot(contains(first.latitude.toString())));
      expect(
          first.stableSampleKey, isNot(contains(first.longitude.toString())));
    });

    test('distinguishes timestamps, packet-id wrap, and stationary samples',
        () {
      EixamDevicePositionSample sample(int timestamp, int packetId) {
        return EixamTelLiveBatchPacket.tryParse(
          _batch(<List<int>>[_record(timestamp, _wire(packetId: packetId))]),
          receivedAt: receivedAt,
        )!
            .batch
            .samples
            .single;
      }

      final first = sample(1786103880, 1);
      final samePacketLater = sample(1786103940, 1);
      final wrappedLater = sample(1786103950, 1);
      expect(first.stableSampleKey, isNot(samePacketLater.stableSampleKey));
      expect(
          samePacketLater.stableSampleKey, isNot(wrappedLater.stableSampleKey));
    });
  });

  test('real 0xD0 reassembler reconstructs and resets after 386 bytes', () {
    final payload = _batch(
      List<List<int>>.generate(
        24,
        (index) => _record(1786102500 + index, _wire(packetId: index % 16)),
      ),
    );
    final reassembler = EixamTelReassembler();
    List<int>? completed;
    for (var offset = 0; offset < payload.length; offset += 15) {
      final end = offset + 15 < payload.length ? offset + 15 : payload.length;
      completed = reassembler.addFragment(
        EixamTelFragment.tryParse(<int>[
          0xD0,
          payload.length & 0xFF,
          payload.length >> 8,
          offset & 0xFF,
          offset >> 8,
          ...payload.sublist(offset, end),
        ])!,
      );
    }

    expect(completed, payload);
    expect(
      EixamTelLiveBatchPacket.tryParse(completed!, receivedAt: receivedAt)!
          .batch
          .samples,
      hasLength(24),
    );
    expect(
        reassembler.addFragment(EixamTelFragment.tryParse(<int>[
          0xD0,
          1,
          0,
          0,
          0,
          0xAA,
        ])!),
        <int>[0xAA]);
  });
}

List<int> _batch(List<List<int>> records) => <int>[
      0xD3,
      records.length,
      for (final record in records) ...record,
    ];

List<int> _record(int timeUnix, List<int> wire) => <int>[
      timeUnix & 0xFF,
      (timeUnix >> 8) & 0xFF,
      (timeUnix >> 16) & 0xFF,
      (timeUnix >> 24) & 0xFF,
      ...wire,
    ];

List<int> _wire({int packetId = 0}) => <int>[
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
