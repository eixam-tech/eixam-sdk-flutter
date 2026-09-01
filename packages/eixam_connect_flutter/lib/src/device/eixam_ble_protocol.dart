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
  static const int inetMaxPayloadLength = 4;

  static String hex(List<int> data) {
    return data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}
