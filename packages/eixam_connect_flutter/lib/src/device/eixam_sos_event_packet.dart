import 'eixam_ble_protocol.dart';

class EixamSosEventPacket {
  const EixamSosEventPacket({
    required this.rawBytes,
    required this.rawHex,
    required this.opcode,
    required this.subcode,
    required this.nodeId,
  });

  final List<int> rawBytes;
  final String rawHex;
  final int opcode;
  final int subcode;
  final int nodeId;

  bool get isUserDeactivated =>
      opcode == EixamBleProtocol.sosEventUserDeactivatedOpcode;

  bool get isAppCancelAck =>
      opcode == EixamBleProtocol.sosEventAppCancelAckOpcode;

  /// `ACK_SOS` closed the tag episode (services on the way). Not a user cancel.
  bool get isBackendResolved =>
      opcode == EixamBleProtocol.sosEventBackendResolvedOpcode;

  static EixamSosEventPacket? tryParse(List<int> bytes) {
    if (bytes.length != 6) {
      return null;
    }

    final opcode = bytes[0];
    if (opcode != EixamBleProtocol.sosEventUserDeactivatedOpcode &&
        opcode != EixamBleProtocol.sosEventAppCancelAckOpcode &&
        opcode != EixamBleProtocol.sosEventBackendResolvedOpcode) {
      return null;
    }

    return EixamSosEventPacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      opcode: opcode,
      subcode: bytes[1],
      nodeId: bytes[2] | (bytes[3] << 8) | (bytes[4] << 16) | (bytes[5] << 24),
    );
  }
}
