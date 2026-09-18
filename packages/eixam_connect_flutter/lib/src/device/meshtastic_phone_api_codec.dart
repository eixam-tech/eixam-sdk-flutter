import 'dart:convert';

/// The minimal, read-only subset of Meshtastic PhoneAPI used for hardware
/// identification. Field numbers are pinned to the generated Meshtastic
/// `mesh.pb.h` bundled by the firmware workspace.
final class MeshtasticPhoneApiCodec {
  const MeshtasticPhoneApiCodec();

  static const int configRequestId = 69420;

  List<int> encodeConfigRequest() => <int>[
    0x18, // ToRadio.want_config_id, field 3 / varint.
    ..._encodeVarint(configRequestId),
  ];

  MeshtasticFromRadioFrame decodeFromRadio(List<int> bytes) {
    final root = _WireReader(bytes);
    int? nodeNumber;
    int? nodeInfoNumber;
    List<int>? nodeInfoMac;
    int? hardwareModel;
    String? firmwareVersion;
    int? configCompleteId;

    while (!root.isDone) {
      final field = root.readField();
      switch (field.number) {
        case 3 when field.wireType == 2:
          final nested = _WireReader(field.bytesValue!);
          while (!nested.isDone) {
            final item = nested.readField();
            if (item.number == 1 && item.wireType == 0) {
              nodeNumber = item.intValue;
            }
          }
        case 4 when field.wireType == 2:
          final nested = _WireReader(field.bytesValue!);
          while (!nested.isDone) {
            final item = nested.readField();
            if (item.number == 1 && item.wireType == 0) {
              nodeInfoNumber = item.intValue;
            } else if (item.number == 2 && item.wireType == 2) {
              final user = _WireReader(item.bytesValue!);
              while (!user.isDone) {
                final userField = user.readField();
                if (userField.number == 4 && userField.wireType == 2) {
                  final mac = userField.bytesValue!;
                  if (mac.length == 6) nodeInfoMac = mac;
                }
              }
            }
          }
        case 7 when field.wireType == 0:
          configCompleteId = field.intValue;
        case 13 when field.wireType == 2:
          final metadata = _WireReader(field.bytesValue!);
          while (!metadata.isDone) {
            final item = metadata.readField();
            if (item.number == 1 && item.wireType == 2) {
              firmwareVersion = utf8.decode(
                item.bytesValue!,
                allowMalformed: false,
              );
            } else if (item.number == 9 && item.wireType == 0) {
              hardwareModel = item.intValue;
            }
          }
      }
    }

    return MeshtasticFromRadioFrame(
      nodeNumber: nodeNumber,
      nodeInfoNumber: nodeInfoNumber,
      nodeInfoMac: nodeInfoMac,
      hardwareModel: hardwareModel,
      firmwareVersion: firmwareVersion,
      configCompleteId: configCompleteId,
    );
  }

  static List<int> _encodeVarint(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value');
    final result = <int>[];
    var remaining = value;
    do {
      var byte = remaining & 0x7f;
      remaining >>= 7;
      if (remaining != 0) byte |= 0x80;
      result.add(byte);
    } while (remaining != 0);
    return result;
  }
}

final class MeshtasticFromRadioFrame {
  const MeshtasticFromRadioFrame({
    this.nodeNumber,
    this.nodeInfoNumber,
    this.nodeInfoMac,
    this.hardwareModel,
    this.firmwareVersion,
    this.configCompleteId,
  });

  final int? nodeNumber;
  final int? nodeInfoNumber;
  final List<int>? nodeInfoMac;
  final int? hardwareModel;
  final String? firmwareVersion;
  final int? configCompleteId;
}

final class _WireField {
  const _WireField({
    required this.number,
    required this.wireType,
    this.intValue,
    this.bytesValue,
  });

  final int number;
  final int wireType;
  final int? intValue;
  final List<int>? bytesValue;
}

final class _WireReader {
  _WireReader(this._bytes);

  final List<int> _bytes;
  int _offset = 0;

  bool get isDone => _offset == _bytes.length;

  _WireField readField() {
    final key = _readVarint();
    final number = key >> 3;
    final wireType = key & 7;
    if (number == 0) throw const FormatException('Invalid protobuf field 0.');
    switch (wireType) {
      case 0:
        return _WireField(
          number: number,
          wireType: wireType,
          intValue: _readVarint(),
        );
      case 1:
        _skip(8);
        return _WireField(number: number, wireType: wireType);
      case 2:
        final length = _readVarint();
        if (length < 0 || length > _bytes.length - _offset) {
          throw const FormatException('Truncated protobuf field.');
        }
        final value = _bytes.sublist(_offset, _offset + length);
        _offset += length;
        return _WireField(
          number: number,
          wireType: wireType,
          bytesValue: value,
        );
      case 5:
        _skip(4);
        return _WireField(number: number, wireType: wireType);
      default:
        throw FormatException('Unsupported protobuf wire type $wireType.');
    }
  }

  int _readVarint() {
    var result = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (_offset >= _bytes.length) {
        throw const FormatException('Truncated protobuf varint.');
      }
      final byte = _bytes[_offset++];
      if (byte < 0 || byte > 255) {
        throw const FormatException('Invalid protobuf byte.');
      }
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
    }
    throw const FormatException('Protobuf varint exceeds 64 bits.');
  }

  void _skip(int count) {
    if (count > _bytes.length - _offset) {
      throw const FormatException('Truncated protobuf fixed field.');
    }
    _offset += count;
  }
}
