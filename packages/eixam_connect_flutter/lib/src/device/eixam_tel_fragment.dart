import 'eixam_ble_protocol.dart';

class EixamTelFragment {
  const EixamTelFragment({
    required this.rawBytes,
    required this.rawHex,
    required this.totalLength,
    required this.offset,
    required this.fragmentPayload,
  });

  final List<int> rawBytes;
  final String rawHex;
  final int totalLength;
  final int offset;
  final List<int> fragmentPayload;

  int get fragmentLength => fragmentPayload.length;

  static EixamTelFragment? tryParse(List<int> bytes) {
    if (bytes.length < EixamBleProtocol.telAggregateFragmentHeaderLength + 1) {
      return null;
    }
    if (bytes.first != EixamBleProtocol.telAggregateFragmentOpcode) {
      return null;
    }

    final totalLength = bytes[1] | (bytes[2] << 8);
    final offset = bytes[3] | (bytes[4] << 8);
    final payload = bytes.sublist(
      EixamBleProtocol.telAggregateFragmentHeaderLength,
    );
    if (totalLength <= 0 || payload.isEmpty) {
      return null;
    }
    if (payload.length >
        EixamBleProtocol.telAggregateFragmentMaxPayloadLength) {
      return null;
    }

    return EixamTelFragment(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      totalLength: totalLength,
      offset: offset,
      fragmentPayload: List<int>.unmodifiable(payload),
    );
  }
}
