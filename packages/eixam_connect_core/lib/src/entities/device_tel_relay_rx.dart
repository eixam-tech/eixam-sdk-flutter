import 'tracking_position.dart';

/// Typed relay telemetry sample decoded by the SDK from a BLE relay payload.
///
/// Host apps should treat this as diagnostics/support context. The SDK uses
/// `remoteDeviceId` internally when routing relay-origin backend ingest.
class DeviceTelRelayRx {
  const DeviceTelRelayRx({
    required this.peerPayload,
    required this.peerPosition,
    required this.rxSnr,
    required this.rxRssi,
    required this.selfPayload,
    required this.selfPosition,
    this.remoteDeviceId,
    this.receivedAt,
  });

  final List<int> peerPayload;
  final TrackingPosition peerPosition;
  final int rxSnr;
  final int rxRssi;
  final List<int> selfPayload;
  final TrackingPosition selfPosition;

  /// Backend-safe identity for the relayed remote device when present.
  final String? remoteDeviceId;

  /// Local decode timestamp recorded by the SDK.
  final DateTime? receivedAt;
}
