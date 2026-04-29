import 'tracking_position.dart';

enum RemoteRelaySosKind { sos, clear, cancel }

enum RemoteRelaySosSource {
  bleRelay,
  telRelay,
  sosNotify,
  d2Relay,
}

class RemoteRelaySosSnapshot {
  const RemoteRelaySosSnapshot({
    required this.kind,
    required this.originatorNodeId,
    required this.source,
    required this.sosType,
    required this.receivedAt,
    required this.rawPayload,
    this.relayNodeId,
    this.location,
    this.payloadHex,
    this.relayCount,
    this.eventOpcode,
    this.eventSubcode,
  });

  final RemoteRelaySosKind kind;
  final int originatorNodeId;
  final int? relayNodeId;
  final RemoteRelaySosSource source;
  final int sosType;
  final TrackingPosition? location;
  final DateTime receivedAt;
  final List<int> rawPayload;
  final String? payloadHex;
  final int? relayCount;
  final int? eventOpcode;
  final int? eventSubcode;
}
