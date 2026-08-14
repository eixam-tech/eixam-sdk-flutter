import 'dart:typed_data';

final class SoftSimMaterial {
  SoftSimMaterial._(this._bytes);

  Uint8List _bytes;
  bool _disposed = false;

  Uint8List get bytes {
    if (_disposed) {
      throw StateError('SoftSIM material has been disposed.');
    }
    return _bytes;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _bytes.fillRange(0, _bytes.length, 0);
    _bytes = Uint8List(0);
    _disposed = true;
  }

  @override
  String toString() => 'SoftSimMaterial(bytes: <redacted>)';
}

SoftSimMaterial buildSoftSim({
  required Uint8List psk,
  required int nodeId,
  required String backendUrl,
  required int telSpreadingFactor,
  required int sosPowerDbm,
  int telIntervalMs = 120000,
}) {
  if (psk.length != 32 || nodeId < 0 || nodeId > 0xffffffff) {
    throw ArgumentError('Invalid provisioning material.');
  }
  final token = _nulTerminatedAscii(nodeId.toString(), 64);
  Uint8List? url;
  try {
    url = _nulTerminatedUtf8AsciiCompatible(backendUrl, 128);
    if (telSpreadingFactor < 0 ||
        telSpreadingFactor > 255 ||
        sosPowerDbm < -128 ||
        sosPowerDbm > 127 ||
        telIntervalMs < 0 ||
        telIntervalMs > 0xffffffff) {
      throw ArgumentError('Invalid provisioning policy.');
    }
    final bytes = Uint8List(230);
    bytes.setRange(0, 32, psk);
    bytes.setRange(32, 96, token);
    bytes.setRange(96, 224, url);
    final data = ByteData.sublistView(bytes);
    data.setUint32(224, telIntervalMs, Endian.little);
    bytes[228] = telSpreadingFactor;
    data.setInt8(229, sosPowerDbm);
    return SoftSimMaterial._(bytes);
  } finally {
    token.fillRange(0, token.length, 0);
    url?.fillRange(0, url.length, 0);
  }
}

Uint8List _nulTerminatedAscii(String value, int width) {
  final codeUnits = value.codeUnits;
  if (codeUnits.length >= width || codeUnits.any((unit) => unit > 0x7f)) {
    throw ArgumentError('Invalid provisioning text field.');
  }
  final result = Uint8List(width);
  result.setRange(0, codeUnits.length, codeUnits);
  return result;
}

Uint8List _nulTerminatedUtf8AsciiCompatible(String value, int width) {
  // The current firmware parser consumes byte-compatible C strings. Requiring
  // ASCII avoids accepting UTF-8 sequences whose firmware interpretation is
  // not part of the certified contract.
  return _nulTerminatedAscii(value, width);
}

int provisioningCrc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

Uint8List encodeSoftSimBegin(List<int> softSim) {
  if (softSim.length != 230) {
    throw ArgumentError('Invalid SoftSIM length.');
  }
  final bytes = Uint8List(8);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 0x24;
  bytes[1] = 0x01;
  data.setUint16(2, softSim.length, Endian.little);
  data.setUint32(4, provisioningCrc32(softSim), Endian.little);
  return bytes;
}

Uint8List encodeSoftSimChunk(List<int> softSim, int offset) {
  if (softSim.length != 230 || offset < 0 || offset >= softSim.length) {
    throw ArgumentError('Invalid SoftSIM chunk.');
  }
  final dataLength = (softSim.length - offset).clamp(0, 12);
  final chunk = Uint8List(4 + dataLength);
  final view = ByteData.sublistView(chunk);
  chunk[0] = 0x24;
  chunk[1] = 0x02;
  view.setUint16(2, offset, Endian.little);
  chunk.setRange(4, chunk.length, softSim, offset);
  return chunk;
}

Uint8List encodeSoftSimCommit() => Uint8List.fromList(<int>[0x24, 0x03]);

Uint8List encodeSoftSimAbort() => Uint8List.fromList(<int>[0x24, 0x04]);
