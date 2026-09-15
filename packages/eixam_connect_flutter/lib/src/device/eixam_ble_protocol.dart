enum EixamBleChannel { tel, sos }

class EixamBleProtocol {
  static const String serviceUuid = '6ba1b218-15a8-461f-9fa8-5dcae273ea00';
  static const String telNotifyCharacteristicUuid =
      '6ba1b218-15a8-461f-9fa8-5dcae273ea01';
  static const String sosNotifyCharacteristicUuid =
      '6ba1b218-15a8-461f-9fa8-5dcae273ea02';
  static const String inetWriteCharacteristicUuid =
      '6ba1b218-15a8-461f-9fa8-5dcae273ea03';
  static const String cmdWriteCharacteristicUuid =
      '6ba1b218-15a8-461f-9fa8-5dcae273ea04';

  static const int telPacketLength = 12;
  static const int telMeshPort = 258;
  static const int sosMeshPort = 259;
  static const int clusterMeshPort = 260;
  static const int rescueMeshPort = 261;
  static const int nearbyTextMeshPort = 262;
  static const int telAggregateFragmentOpcode = 0xD0;
  static const int telAggregateFragmentHeaderLength = 5;
  static const int telAggregateFragmentMaxPayloadLength = 15;
  static const int clusterHeartbeatPacketLength = 12;
  static const int sosPacketLengthWithPosition = 12;
  static const int sosPacketLengthDelta = 10;
  static const int sosPacketLengthMinimal = 7;
  static const int sosEventUserDeactivatedOpcode = 0xE1;
  static const int sosEventAppCancelAckOpcode = 0xE2;
  static const int sosEventBackendResolvedOpcode = 0xE3;
  static const int rescueHeaderLength = 9;
  static const int rescueStatusRespLength = 14;
  static const int rescueCmdRequestPos = 0x01;
  static const int rescueCmdAckSos = 0x02;
  static const int rescueCmdBuzzerOn = 0x03;
  static const int rescueCmdBuzzerOff = 0x04;
  static const int rescueCmdStatusReq = 0x05;
  static const int rescueCmdStatusResp = 0x85;
  static const int telLiveBatchOpcode = 0xD3;
  static const int telBacklogOpcode = 0xD1;

  /// Reserved dense-track twins. Not on the wire until a versioned CMD opt-in.
  static const int telDenseLiveBatchOpcode = 0xD4;
  static const int telDenseBacklogOpcode = 0xD5;
  static const int nearbyTextRxOpcode = 0xD8;
  static const int nearbyTextTxStatusOpcode = 0xDA;
  static const int nearbyTextTxOpcode = 0x40;
  static const int nearbyTextGroupOpcode = 0x41;
  static const int nearbyOwnerNameOpcode = 0x42;
  static const int nearbyTextRxHeaderLength = 22;
  static const int nearbyTextTxHeaderLength = 16;
  static const int nearbyTextTxStatusLength = 6;
  static const int nearbyOwnerNameRxOpcode = 0xDB;
  static const int nearbyOwnerNameRxHeaderLength = 5;
  static const int nearbyOwnerNameMaxBytes = 39;

  /// TX cap for plaza / group text. The firmware router adds `has_bitfield`
  /// to its own packets, so the mesh `Data` protobuf is portnum(3) +
  /// payload tag/len(3) + bitfield(2) + text; with the 16 B LoRa header only
  /// 231 B of text fit in 255. 232–233 B come back `TOO_LARGE` (0xDA PSA).
  static const int nearbyTextPayloadMaxBytes = 231;

  /// RX accepts the full Meshtastic `DATA_PAYLOAD_LEN`: non-Eixam nodes may
  /// still put up to 233 B on port 262.
  static const int nearbyTextRxPayloadMaxBytes = 233;
  static const int nearbyTextDirectPayloadMaxBytes = 200;
  static const int nearbyTextLengthPad = 0xFF;
  static const int nearbyTextBroadcastDest = 0xFFFFFFFF;
  static const int nearbyTextRxFlagPki = 0x01;
  static const int nearbyTextGroupBlobLength = 41;
  static const int nearbyTextGroupSet = 1;
  static const int nearbyTextGroupSetReplace = 2;
  static const int nearbyTextGroupClear = 0;
  static const int nearbyTextGroupSlots = 7;

  /// BLE TEL also carries SOS (7/10/12) and wrapped SOS (+6). A `0xD8` blob is
  /// 22 B header + text so it never has these sizes; kept as a guard. Firmware
  /// ≤ 2.7.56 padded with [nearbyTextLengthPad], which the parser still strips.
  static bool isReservedSosOrTelNotifyLength(int length) {
    return length == 6 ||
        length == sosPacketLengthMinimal ||
        length == sosPacketLengthDelta ||
        length == telPacketLength ||
        length == sosPacketLengthMinimal + 6 ||
        length == sosPacketLengthDelta + 6 ||
        length == sosPacketLengthWithPosition + 6;
  }

  static const int inetMaxPayloadLength = 4;

  static String hex(List<int> data) {
    return data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}
