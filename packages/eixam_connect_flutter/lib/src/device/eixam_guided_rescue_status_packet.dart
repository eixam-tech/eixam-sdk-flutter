import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_ble_protocol.dart';

class EixamGuidedRescueStatusPacket {
  const EixamGuidedRescueStatusPacket({
    required this.rawBytes,
    required this.rawHex,
    required this.rescueNodeId,
    required this.victimNodeId,
    required this.targetState,
    required this.retryCount,
    required this.receivedAt,
    this.batteryLevel,
    this.gpsQuality,
    this.relayPendingAck = false,
    this.internetAvailable = false,
  });

  static const int statusResponseOpcode = 0x85;
  static const int payloadLength = 10;

  final List<int> rawBytes;
  final String rawHex;
  final int rescueNodeId;
  final int victimNodeId;
  final GuidedRescueTargetState targetState;
  final DeviceBatteryLevel? batteryLevel;
  final int? gpsQuality;
  final int retryCount;
  final bool relayPendingAck;
  final bool internetAvailable;
  final DateTime receivedAt;

  static EixamGuidedRescueStatusPacket? tryParse(
    List<int> bytes, {
    DateTime? receivedAt,
  }) {
    if (bytes.length != payloadLength || bytes[4] != statusResponseOpcode) {
      return null;
    }

    final batteryProtocolValue = bytes[6];
    final gpsQuality = bytes[7];
    if (batteryProtocolValue > 3 || gpsQuality > 3) {
      return null;
    }

    return EixamGuidedRescueStatusPacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      rescueNodeId: bytes[0] | (bytes[1] << 8),
      victimNodeId: bytes[2] | (bytes[3] << 8),
      targetState: _mapState(bytes[5]),
      batteryLevel: DeviceBatteryLevel.fromProtocolValue(batteryProtocolValue),
      gpsQuality: gpsQuality,
      retryCount: bytes[8],
      relayPendingAck: (bytes[9] & 0x01) != 0,
      internetAvailable: (bytes[9] & 0x02) != 0,
      receivedAt: receivedAt ?? DateTime.now(),
    );
  }

  GuidedRescueStatusSnapshot toSnapshot() {
    return GuidedRescueStatusSnapshot(
      targetNodeId: victimNodeId,
      rescueNodeId: rescueNodeId,
      targetState: targetState,
      batteryLevel: batteryLevel,
      gpsQuality: gpsQuality,
      retryCount: retryCount,
      relayPendingAck: relayPendingAck,
      internetAvailable: internetAvailable,
      receivedAt: receivedAt,
    );
  }

  static GuidedRescueTargetState _mapState(int rawState) {
    switch (rawState) {
      case 0:
        return GuidedRescueTargetState.inactive;
      case 1:
        return GuidedRescueTargetState.countdown;
      case 2:
        return GuidedRescueTargetState.active;
      case 3:
        return GuidedRescueTargetState.acknowledged;
      case 4:
        return GuidedRescueTargetState.resolved;
      default:
        return GuidedRescueTargetState.unknown;
    }
  }
}
