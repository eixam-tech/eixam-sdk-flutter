import 'package:eixam_connect_core/eixam_connect_core.dart';

class EixamDeviceRuntimeStatusPacket {
  const EixamDeviceRuntimeStatusPacket({
    required this.status,
  });

  final DeviceRuntimeStatus status;

  static const int packetLength = 14;
  static const List<int> header = <int>[0xE9, 0x78, 0x02];

  static EixamDeviceRuntimeStatusPacket? tryParse(
    List<int> bytes, {
    DateTime? receivedAt,
  }) {
    if (bytes.length != packetLength) {
      return null;
    }
    for (var i = 0; i < header.length; i++) {
      if (bytes[i] != header[i]) {
        return null;
      }
    }

    final flags = bytes[6];
    return EixamDeviceRuntimeStatusPacket(
      status: DeviceRuntimeStatus(
        region: bytes[3],
        modemPreset: bytes[4],
        meshSpreadingFactor: bytes[5],
        isProvisioned: (flags & 0x01) != 0,
        usePreset: (flags & 0x02) != 0,
        txEnabled: (flags & 0x04) != 0,
        inetOk: (flags & 0x08) != 0,
        positionConfirmed: (flags & 0x10) != 0,
        nodeId: _readU32(bytes, 7),
        batteryPercent: bytes[11],
        telIntervalSeconds: bytes[12] | (bytes[13] << 8),
        receivedAt: receivedAt,
        rawBytes: List<int>.unmodifiable(bytes),
      ),
    );
  }

  static int _readU32(List<int> bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}
