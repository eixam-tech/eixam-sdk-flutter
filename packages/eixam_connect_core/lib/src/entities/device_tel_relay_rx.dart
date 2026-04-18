import 'tracking_position.dart';

class DeviceTelRelayRx {
  const DeviceTelRelayRx({
    required this.peerPayload,
    required this.peerPosition,
    required this.rxSnr,
    required this.rxRssi,
    required this.selfPayload,
    required this.selfPosition,
    this.receivedAt,
  });

  final List<int> peerPayload;
  final TrackingPosition peerPosition;
  final int rxSnr;
  final int rxRssi;
  final List<int> selfPayload;
  final TrackingPosition selfPosition;
  final DateTime? receivedAt;
}
