import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_incoming_event.dart';
import '../device/eixam_position_sample_identity.dart';

/// One live battery reading of the connected TAG.
final class TagBatteryReading {
  const TagBatteryReading({required this.band, required this.sourceKey});

  final TagBatteryBand band;

  /// Identifies the physical sample, so the same sample delivered twice is
  /// not counted as two readings.
  final String sourceKey;
}

/// Decides which BLE traffic is a **live** battery reading of the connected
/// TAG. Everything it cannot prove live and own is rejected:
///
/// - `0xD3` live batches: the newest sample must have a plausible device
///   timestamp within [`-maxFutureSkew`, `maxLiveAge`] of receipt, so a batch
///   flushed late after a reconnect is never treated as current. No timestamp
///   means no reading (fail closed). Every packet must be the connected TAG's.
/// - Classic 12-byte TEL notifications of the connected TAG.
/// - `0x23 GET_DEVICE_STATUS` replies (percentage mapped to the same bands;
///   `0` and `0xFF` carry no information and are ignored).
///
/// Backlog (`0xD1`), neighbor relays (`0xD2`), SOS packets, cluster traffic and
/// anything restored from storage are never readings. The tolerance values are
/// provisional and need physical tuning with a real TAG.
abstract final class TagBatteryReadingExtractor {
  static const Duration maxLiveAge = Duration(minutes: 3);
  static const Duration maxFutureSkew = Duration(minutes: 2);

  static TagBatteryReading? fromEvent(
    BleIncomingEvent event, {
    required DeviceStatus? status,
  }) {
    if (status == null) return null;
    switch (event.type) {
      case BleIncomingEventType.telLivePositionBatch:
        return _fromLiveBatch(event, status);
      case BleIncomingEventType.telPosition:
        return _fromClassicTel(event, status);
      case BleIncomingEventType.deviceRuntimeStatus:
        final packet = event.deviceRuntimeStatusPacket;
        return packet == null
            ? null
            : fromRuntimeStatus(packet.status, status: status);
      case BleIncomingEventType.provisioningCommandResult:
      case BleIncomingEventType.telAggregateFragment:
      case BleIncomingEventType.telAggregateComplete:
      case BleIncomingEventType.telPositionBacklog:
      case BleIncomingEventType.telRelayRx:
      case BleIncomingEventType.clusterHeartbeat:
      case BleIncomingEventType.sosMeshPacket:
      case BleIncomingEventType.sosDeviceEvent:
      case BleIncomingEventType.nearbyTextRx:
      case BleIncomingEventType.nearbyTextTxStatus:
      case BleIncomingEventType.nearbyOwnerName:
      case BleIncomingEventType.unknownProtocolPacket:
        return null;
    }
  }

  /// A `0x23` reply comes from the connected TAG over its own command channel,
  /// so it does not need `connected` (the connect-time hydrate runs before the
  /// public status flips). A known, different `nodeId` is still rejected.
  static TagBatteryReading? fromRuntimeStatus(
    DeviceRuntimeStatus runtime, {
    required DeviceStatus? status,
  }) {
    if (status == null || !status.paired) return null;
    final known = status.nodeId;
    if (known != null && known != runtime.nodeId) return null;
    final percent = runtime.batteryPercent;
    // 0 is what the firmware reports without a battery; 0xFF is decoded to
    // null. The 2-bit TEL path still reports a genuinely empty battery.
    if (percent == null || percent <= 0) return null;
    final band = TagBatteryBand.fromPercent(percent);
    if (band == null) return null;
    final at = runtime.receivedAt?.microsecondsSinceEpoch ?? -1;
    if (at < 0) return null;
    return TagBatteryReading(band: band, sourceKey: 'rt:${runtime.nodeId}:$at');
  }

  static bool _isOwnLiveLink(DeviceStatus status) =>
      status.connected && status.paired && status.nodeId != null;

  static TagBatteryReading? _fromLiveBatch(
    BleIncomingEvent event,
    DeviceStatus status,
  ) {
    final live = event.telLiveBatchPacket;
    if (live == null || !_isOwnLiveLink(status)) return null;
    if (live.batch.delivery != EixamDevicePositionDelivery.live) return null;
    if (live.telPackets.any((packet) => packet.nodeId != status.nodeId)) {
      return null;
    }
    final samples = live.batch.samples;
    if (samples.length != live.telPackets.length) return null;
    int? newest;
    for (var i = 0; i < samples.length; i++) {
      final at = samples[i].sampledAt;
      if (at == null) continue;
      final best = newest == null ? null : samples[newest].sampledAt;
      if (best == null || at.isAfter(best)) newest = i;
    }
    if (newest == null) return null;
    final age = event.receivedAt.toUtc().difference(
      samples[newest].sampledAt!.toUtc(),
    );
    if (age > maxLiveAge || age < -maxFutureSkew) return null;
    final band = TagBatteryBand.fromLevel(
      DeviceBatteryLevel.fromProtocolValue(
        live.telPackets[newest].batteryLevel,
      ),
    );
    if (band == null) return null;
    return TagBatteryReading(
      band: band,
      sourceKey: samples[newest].stableSampleKey,
    );
  }

  static TagBatteryReading? _fromClassicTel(
    BleIncomingEvent event,
    DeviceStatus status,
  ) {
    final packet = event.telPacket;
    if (packet == null || !_isOwnLiveLink(status)) return null;
    if (packet.nodeId != status.nodeId) return null;
    final band = TagBatteryBand.fromLevel(
      DeviceBatteryLevel.fromProtocolValue(packet.batteryLevel),
    );
    if (band == null) return null;
    return TagBatteryReading(
      band: band,
      sourceKey: EixamPositionSampleIdentity.classicTel(packet.rawBytes),
    );
  }
}
