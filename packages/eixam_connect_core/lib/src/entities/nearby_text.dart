import '../enums/nearby_text_tx_status.dart';

/// UTF-8 received over LoRa port 262 via the connected TAG.
class NearbyIncomingText {
  const NearbyIncomingText({
    required this.fromNodeId,
    required this.packetId,
    required this.text,
    required this.receivedAt,
    this.destNodeId = 0xFFFFFFFF,
    this.groupId = 0,
    this.pkiEncrypted = false,
  });

  final int fromNodeId;
  final int destNodeId;
  final int packetId;
  final int groupId;
  final bool pkiEncrypted;
  final String text;
  final DateTime receivedAt;

  bool get isBroadcast =>
      destNodeId.toUnsigned(32) == 0xFFFFFFFF && groupId == 0;

  bool get isDirect => groupId == 0 && !isBroadcast;

  bool get isGroup => groupId != 0;

  /// GAP-style label: `EIXAM_` + 8 hex of [fromNodeId].
  String get senderLabel {
    final hex = fromNodeId.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    return 'EIXAM_${hex.toUpperCase()}';
  }
}

/// Display name currently advertised by a TAG (`owner.long_name` / BLE `0xDB`).
class NearbyNodeName {
  const NearbyNodeName({
    required this.nodeId,
    required this.name,
    required this.receivedAt,
  });

  final int nodeId;
  final String name;
  final DateTime receivedAt;

  static String hardwareLabel(int nodeId) {
    final hex = nodeId.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    return 'EIXAM_${hex.toUpperCase()}';
  }

  bool get isHardwareFallback {
    return name.trim().toUpperCase() == hardwareLabel(nodeId);
  }
}

class NearbyTextTxResult {
  const NearbyTextTxResult({required this.packetId, required this.status});

  final int packetId;
  final NearbyTextTxStatus status;

  bool get accepted => status.accepted;
}

class NearbyGroupCommandResult {
  const NearbyGroupCommandResult({
    required this.accepted,
    required this.detail,
  });

  final bool accepted;
  final int detail;

  /// Firmware REJECT: SOS countdown/active — no LittleFS / channel flash.
  static const int rejectDetailSos = 0x01;

  /// Firmware REJECT: groups.bin or channel-file persist failed.
  static const int rejectDetailPersist = 0xFD;

  /// Firmware REJECT: zero key, equals PRIMARY, or duplicates another slot.
  static const int rejectDetailBadKey = 0xFE;

  /// Firmware REJECT: all SECONDARY group slots are used (SET without replace).
  static const int rejectDetailSlotsFull = 0xFF;

  /// Meshtastic ChannelFile has 8 entries; index 0 is PRIMARY.
  static const int maxSecondarySlots = 7;

  /// Legacy SDK-local reject (outside the u8 wire range). Current native
  /// protection forwards group ACKs, so this is unused.
  static const int rejectDetailBleOwnedByProtection = 0x100;

  /// SDK-local: no ready BLE command channel (host should map to disconnected).
  static const int rejectDetailCommandChannel = 0x101;

  bool get sosBlocked => !accepted && detail == rejectDetailSos;

  bool get bleOwnedByProtection =>
      !accepted && detail == rejectDetailBleOwnedByProtection;

  bool get commandChannelUnavailable =>
      !accepted && detail == rejectDetailCommandChannel;

  bool get persistFailed => !accepted && detail == rejectDetailPersist;

  bool get badKey => !accepted && detail == rejectDetailBadKey;

  /// Firmware REJECT detail `0xFF`: all SECONDARY group slots are used.
  bool get slotsFull => !accepted && detail == rejectDetailSlotsFull;
}
