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
  static const int sosPacketLengthMinimal = 7;
  static const int sosEventUserDeactivatedOpcode = 0xE1;
  static const int sosEventAppCancelAckOpcode = 0xE2;
  static const int inetMaxPayloadLength = 4;

  static String hex(List<int> data) {
    return data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}
