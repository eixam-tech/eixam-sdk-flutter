import 'eixam_ble_protocol.dart';
import 'eixam_sos_packet.dart';

int? inferMeshPortForLiveNotification({
  required EixamBleChannel channel,
  required List<int> payload,
  int? explicitMeshPort,
}) {
  if (explicitMeshPort != null) {
    return explicitMeshPort;
  }
  if (channel != EixamBleChannel.tel || payload.isEmpty) {
    return null;
  }

  if (payload.length == 3 && payload.first == 0xC0) {
    return EixamBleProtocol.clusterMeshPort;
  }
  if (payload.length == 15 && payload.first == 0xC1) {
    return EixamBleProtocol.clusterMeshPort;
  }

  if (payload.first == EixamBleProtocol.telAggregateFragmentOpcode ||
      payload.first == 0xC2 ||
      payload.first == 0xD2) {
    return EixamBleProtocol.telMeshPort;
  }

  if (payload.length == 7 || payload.length == 12) {
    final sosPacket = EixamSosPacket.tryParse(payload);
    if (sosPacket != null && sosPacket.sosType != 0) {
      return EixamBleProtocol.telMeshPort;
    }
  }

  // A raw 12-byte TEL notify is ambiguous in v2: it can be a TEL wire or a
  // cluster heartbeat wire. The live BLE source does not expose the original
  // Meshtastic port, so guessing 258 vs 260 here would cause false positives.
  return null;
}
