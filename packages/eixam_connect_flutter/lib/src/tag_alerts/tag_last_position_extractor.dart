import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_incoming_event.dart';

/// Extracts the last position reported by the connected TAG itself, for the
/// content of a disconnect alert. Only the TAG's own fixes qualify: a live
/// `0xD3` batch (newest sample with a plausible device timestamp) or an own
/// classic TEL packet, from the device the current status describes and with
/// the connected TAG's node id. Phone, cached, relayed and recovered
/// positions never qualify, and invalid or `0,0` fixes are dropped.
abstract final class TagLastPositionExtractor {
  static TagAlertPosition? fromEvent(
    BleIncomingEvent event, {
    required DeviceStatus? status,
  }) {
    if (status == null ||
        !status.connected ||
        !status.paired ||
        status.nodeId == null ||
        event.deviceId != status.deviceId) {
      return null;
    }
    try {
      switch (event.type) {
        case BleIncomingEventType.telLivePositionBatch:
          return _fromLiveBatch(event, status);
        case BleIncomingEventType.telPosition:
          final packet = event.telPacket;
          if (packet == null || packet.nodeId != status.nodeId) return null;
          return TagAlertPosition(
            latitude: packet.position.latitude,
            longitude: packet.position.longitude,
            timestamp: event.receivedAt.toUtc(),
            source: SdkLocationSource.connectedDevice,
          );
        default:
          return null;
      }
    } on ArgumentError {
      return null;
    }
  }

  static TagAlertPosition? _fromLiveBatch(
    BleIncomingEvent event,
    DeviceStatus status,
  ) {
    final live = event.telLiveBatchPacket;
    if (live == null ||
        live.batch.delivery != EixamDevicePositionDelivery.live ||
        live.telPackets.any((packet) => packet.nodeId != status.nodeId)) {
      return null;
    }
    EixamDevicePositionSample? newest;
    for (final sample in live.batch.samples) {
      final at = sample.sampledAt;
      if (at == null || sample.source != SdkLocationSource.connectedDevice) {
        continue;
      }
      if (newest == null || at.isAfter(newest.sampledAt!)) newest = sample;
    }
    if (newest == null) return null;
    return TagAlertPosition(
      latitude: newest.latitude,
      longitude: newest.longitude,
      timestamp: newest.sampledAt!.toUtc(),
      source: newest.source,
    );
  }
}
