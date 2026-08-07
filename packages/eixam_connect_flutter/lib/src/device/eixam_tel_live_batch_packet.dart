import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_tel_packet.dart';

/// Decoded firmware `EIXAM_BLE_TEL_LIVE_BATCH` (`0xD3`) payload.
class EixamTelLiveBatchPacket {
  EixamTelLiveBatchPacket._({
    required this.batch,
    required this.telPackets,
  });

  static const int opcode = 0xD3;
  static const int maximumSamples = 24;
  static const int headerLength = 2;
  static const int recordLength = 16;

  /// Live batches should arrive promptly. Seven days of past skew tolerates
  /// transport delays and moderately wrong phone clocks while rejecting boot-
  /// relative counters. Ten minutes of future skew tolerates clock drift.
  static const Duration maximumPastAge = Duration(days: 7);
  static const Duration maximumFutureSkew = Duration(minutes: 10);

  final EixamDevicePositionBatch batch;
  final List<EixamTelPacket> telPackets;

  static EixamTelLiveBatchPacket? tryParse(
    List<int> bytes, {
    required DateTime receivedAt,
  }) {
    if (bytes.length < headerLength || bytes.first != opcode) {
      return null;
    }
    final count = bytes[1];
    if (count < 1 || count > maximumSamples) {
      return null;
    }
    if (bytes.length != headerLength + count * recordLength) {
      return null;
    }

    final samples = <EixamDevicePositionSample>[];
    final packets = <EixamTelPacket>[];
    for (var index = 0; index < count; index++) {
      final offset = headerLength + index * recordLength;
      final record = bytes.sublist(offset, offset + recordLength);
      final telPacket = EixamTelPacket.tryParse(record.sublist(4));
      if (telPacket == null) {
        return null;
      }
      final timeUnix = _readU32(record, 0);
      final sampledAt = _plausibleSampledAt(
        timeUnix,
        receivedAt: receivedAt,
      );
      packets.add(telPacket);
      samples.add(
        EixamDevicePositionSample(
          latitude: telPacket.position.latitude,
          longitude: telPacket.position.longitude,
          altitudeMeters: telPacket.position.altitudeMeters.toDouble(),
          sampledAt: sampledAt,
          packetId: telPacket.packetId,
          source: SdkLocationSource.connectedDevice,
          stableSampleKey: 'tlb1:${sha256.convert(record)}',
        ),
      );
    }

    return EixamTelLiveBatchPacket._(
      batch: EixamDevicePositionBatch(
        samples: samples,
        receivedAt: receivedAt.toUtc(),
        source: SdkLocationSource.connectedDevice,
      ),
      telPackets: List<EixamTelPacket>.unmodifiable(packets),
    );
  }

  static DateTime? _plausibleSampledAt(
    int timeUnix, {
    required DateTime receivedAt,
  }) {
    if (timeUnix == 0) {
      return null;
    }
    final candidate = DateTime.fromMillisecondsSinceEpoch(
      timeUnix * Duration.millisecondsPerSecond,
      isUtc: true,
    );
    final receivedUtc = receivedAt.toUtc();
    if (candidate.isBefore(receivedUtc.subtract(maximumPastAge)) ||
        candidate.isAfter(receivedUtc.add(maximumFutureSkew))) {
      return null;
    }
    return candidate;
  }

  static int _readU32(List<int> bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}
